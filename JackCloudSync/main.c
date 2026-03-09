/*
 * JackCloudSync — Upload/download save files via Steam's ISteamRemoteStorage.
 * Requires the real Steam client running on macOS.
 *
 * Usage:
 *   JackCloudSync upload <appid> <local_file> <cloud_filename>
 *   JackCloudSync download <appid> <cloud_filename> <local_file>
 *   JackCloudSync list <appid>
 *   JackCloudSync sync-up <appid> <local_dir>     (upload all files in dir)
 *   JackCloudSync sync-down <appid> <local_dir>    (download all cloud files)
 *
 * Communicates with the running Steam client via libsteam_api.dylib.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <dirent.h>
#include <sys/stat.h>
#include <libgen.h>
#include <unistd.h>

// ─── Steamworks C API function pointers ─────────────────────────────

// steam_api.h flat API equivalents (C linkage)
typedef int  (*SteamAPI_Init_t)(void);
typedef void (*SteamAPI_Shutdown_t)(void);
typedef void* (*SteamInternal_FindOrCreateUserInterface_t)(int hSteamUser, const char *pszVersion);
typedef int  (*SteamAPI_GetHSteamUser_t)(void);
typedef int  (*SteamAPI_ISteamRemoteStorage_FileWrite_t)(void *self, const char *pchFile, const void *pvData, int cubData);
typedef int  (*SteamAPI_ISteamRemoteStorage_FileRead_t)(void *self, const char *pchFile, void *pvData, int cubDataToRead);
typedef int  (*SteamAPI_ISteamRemoteStorage_FileExists_t)(void *self, const char *pchFile);
typedef int  (*SteamAPI_ISteamRemoteStorage_GetFileSize_t)(void *self, const char *pchFile);
typedef int  (*SteamAPI_ISteamRemoteStorage_GetFileCount_t)(void *self);
typedef const char* (*SteamAPI_ISteamRemoteStorage_GetFileNameAndSize_t)(void *self, int iFile, int *pnFileSizeInBytes);
typedef int  (*SteamAPI_ISteamRemoteStorage_FileDelete_t)(void *self, const char *pchFile);

// ISteamUser
typedef unsigned long long (*SteamAPI_ISteamUser_GetSteamID_t)(void *self);
typedef const char* (*SteamAPI_ISteamFriends_GetPersonaName_t)(void *self);

// Flat API init
typedef int (*SteamAPI_InitFlat_t)(void *pOutErrMsg);
typedef void* (*SteamAPI_SteamRemoteStorage_t)(void);
typedef void* (*SteamAPI_SteamUser_t)(void);
typedef void* (*SteamAPI_SteamFriends_t)(void);

static void *g_steamLib = NULL;

// Function pointers
static SteamAPI_Shutdown_t fn_Shutdown;
static void *g_remoteStorage = NULL;

static SteamAPI_ISteamRemoteStorage_FileWrite_t fn_FileWrite;
static SteamAPI_ISteamRemoteStorage_FileRead_t fn_FileRead;
static SteamAPI_ISteamRemoteStorage_FileExists_t fn_FileExists;
static SteamAPI_ISteamRemoteStorage_GetFileSize_t fn_GetFileSize;
static SteamAPI_ISteamRemoteStorage_GetFileCount_t fn_GetFileCount;
static SteamAPI_ISteamRemoteStorage_GetFileNameAndSize_t fn_GetFileNameAndSize;

static void *g_steamUser = NULL;
static void *g_steamFriends = NULL;
static SteamAPI_ISteamUser_GetSteamID_t fn_GetSteamID;
static SteamAPI_ISteamFriends_GetPersonaName_t fn_GetPersonaName;

// ─── Helpers ────────────────────────────────────────────────────────

static void *load_sym(const char *name) {
    void *sym = dlsym(g_steamLib, name);
    if (!sym) {
        fprintf(stderr, "Warning: symbol '%s' not found\n", name);
    }
    return sym;
}

static int init_steam(int appid) {
    // Write steam_appid.txt so Steamworks knows which app we are
    char appid_str[32];
    snprintf(appid_str, sizeof(appid_str), "%d", appid);

    FILE *f = fopen("steam_appid.txt", "w");
    if (f) {
        fprintf(f, "%s\n", appid_str);
        fclose(f);
    }

    // Also set environment variable
    setenv("SteamAppId", appid_str, 1);

    // Find libsteam_api.dylib
    // Try to find libsteam_api.dylib
    const char *lib_paths[] = {
        "libsteam_api.dylib",
        NULL
    };

    // First try: Steam Helper bundle (most reliable)
    // Construct path from HOME
    char steam_lib_path[2048];
    const char *home = getenv("HOME");
    if (home) {
        snprintf(steam_lib_path, sizeof(steam_lib_path),
            "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Frameworks/"
            "Steam Helper.app/Contents/MacOS/libsteam_api.dylib", home);
        g_steamLib = dlopen(steam_lib_path, RTLD_NOW);
        if (g_steamLib) {
            fprintf(stderr, "Loaded: %s\n", steam_lib_path);
        }
    }

    // Fallback: try other paths
    if (!g_steamLib) {
        for (int i = 0; lib_paths[i] != NULL; i++) {
            g_steamLib = dlopen(lib_paths[i], RTLD_NOW);
            if (g_steamLib) {
                fprintf(stderr, "Loaded: %s\n", lib_paths[i]);
                break;
            }
        }
    }

    if (!g_steamLib) {
        fprintf(stderr, "Error: could not load libsteam_api.dylib\n");
        return 0;
    }

    // Try flat API init first (newer SDK)
    SteamAPI_InitFlat_t fn_InitFlat = (SteamAPI_InitFlat_t)dlsym(g_steamLib, "SteamAPI_InitFlat");
    if (fn_InitFlat) {
        char errMsg[1024] = {0};
        int ok = fn_InitFlat(errMsg);
        if (ok != 0) {  // ESteamAPIInitResult_OK = 0
            fprintf(stderr, "SteamAPI_InitFlat failed (%d): %s\n", ok, errMsg);
            // Try legacy init
            goto try_legacy;
        }
        fprintf(stderr, "SteamAPI_InitFlat OK\n");
        goto get_interface;
    }

try_legacy:;
    SteamAPI_Init_t fn_Init = (SteamAPI_Init_t)dlsym(g_steamLib, "SteamAPI_Init");
    if (!fn_Init) {
        fprintf(stderr, "Error: SteamAPI_Init not found\n");
        return 0;
    }

    if (!fn_Init()) {
        fprintf(stderr, "SteamAPI_Init failed. Is Steam running?\n");
        return 0;
    }
    fprintf(stderr, "SteamAPI_Init OK\n");

get_interface:
    fn_Shutdown = (SteamAPI_Shutdown_t)load_sym("SteamAPI_Shutdown");

    // Get ISteamRemoteStorage via flat API
    SteamAPI_SteamRemoteStorage_t fn_GetRemoteStorage =
        (SteamAPI_SteamRemoteStorage_t)dlsym(g_steamLib, "SteamAPI_SteamRemoteStorage_v016");
    if (!fn_GetRemoteStorage)
        fn_GetRemoteStorage = (SteamAPI_SteamRemoteStorage_t)dlsym(g_steamLib, "SteamAPI_SteamRemoteStorage_v014");
    if (!fn_GetRemoteStorage)
        fn_GetRemoteStorage = (SteamAPI_SteamRemoteStorage_t)dlsym(g_steamLib, "SteamAPI_SteamRemoteStorage");

    if (fn_GetRemoteStorage) {
        g_remoteStorage = fn_GetRemoteStorage();
        if (g_remoteStorage) {
            fprintf(stderr, "Got ISteamRemoteStorage: %p\n", g_remoteStorage);
        }
    }

    if (!g_remoteStorage) {
        // Try via SteamInternal
        SteamInternal_FindOrCreateUserInterface_t fn_FindInterface =
            (SteamInternal_FindOrCreateUserInterface_t)dlsym(g_steamLib, "SteamInternal_FindOrCreateUserInterface");
        SteamAPI_GetHSteamUser_t fn_GetUser =
            (SteamAPI_GetHSteamUser_t)dlsym(g_steamLib, "SteamAPI_GetHSteamUser");

        if (fn_FindInterface && fn_GetUser) {
            int hUser = fn_GetUser();
            // Try multiple versions
            const char *versions[] = {
                "STEAMREMOTESTORAGE_INTERFACE_VERSION016",
                "STEAMREMOTESTORAGE_INTERFACE_VERSION014",
                "STEAMREMOTESTORAGE_INTERFACE_VERSION013",
                NULL
            };
            for (int i = 0; versions[i]; i++) {
                g_remoteStorage = fn_FindInterface(hUser, versions[i]);
                if (g_remoteStorage) {
                    fprintf(stderr, "Got ISteamRemoteStorage via %s: %p\n", versions[i], g_remoteStorage);
                    break;
                }
            }
        }
    }

    if (!g_remoteStorage) {
        fprintf(stderr, "Error: could not get ISteamRemoteStorage interface\n");
        return 0;
    }

    // Load flat API functions for ISteamRemoteStorage
    fn_FileWrite = (SteamAPI_ISteamRemoteStorage_FileWrite_t)load_sym("SteamAPI_ISteamRemoteStorage_FileWrite");
    fn_FileRead = (SteamAPI_ISteamRemoteStorage_FileRead_t)load_sym("SteamAPI_ISteamRemoteStorage_FileRead");
    fn_FileExists = (SteamAPI_ISteamRemoteStorage_FileExists_t)load_sym("SteamAPI_ISteamRemoteStorage_FileExists");
    fn_GetFileSize = (SteamAPI_ISteamRemoteStorage_GetFileSize_t)load_sym("SteamAPI_ISteamRemoteStorage_GetFileSize");
    fn_GetFileCount = (SteamAPI_ISteamRemoteStorage_GetFileCount_t)load_sym("SteamAPI_ISteamRemoteStorage_GetFileCount");
    fn_GetFileNameAndSize = (SteamAPI_ISteamRemoteStorage_GetFileNameAndSize_t)load_sym("SteamAPI_ISteamRemoteStorage_GetFileNameAndSize");

    // Load ISteamUser + ISteamFriends for whoami
    SteamAPI_SteamUser_t fn_GetUser2 = (SteamAPI_SteamUser_t)dlsym(g_steamLib, "SteamAPI_SteamUser_v023");
    if (!fn_GetUser2) fn_GetUser2 = (SteamAPI_SteamUser_t)dlsym(g_steamLib, "SteamAPI_SteamUser_v021");
    if (!fn_GetUser2) fn_GetUser2 = (SteamAPI_SteamUser_t)dlsym(g_steamLib, "SteamAPI_SteamUser");
    if (fn_GetUser2) g_steamUser = fn_GetUser2();

    SteamAPI_SteamFriends_t fn_GetFriends = (SteamAPI_SteamFriends_t)dlsym(g_steamLib, "SteamAPI_SteamFriends_v017");
    if (!fn_GetFriends) fn_GetFriends = (SteamAPI_SteamFriends_t)dlsym(g_steamLib, "SteamAPI_SteamFriends");
    if (fn_GetFriends) g_steamFriends = fn_GetFriends();

    fn_GetSteamID = (SteamAPI_ISteamUser_GetSteamID_t)load_sym("SteamAPI_ISteamUser_GetSteamID");
    fn_GetPersonaName = (SteamAPI_ISteamFriends_GetPersonaName_t)load_sym("SteamAPI_ISteamFriends_GetPersonaName");

    return 1;
}

static void shutdown_steam(void) {
    // Clean up steam_appid.txt
    unlink("steam_appid.txt");
    if (fn_Shutdown) fn_Shutdown();
    if (g_steamLib) dlclose(g_steamLib);
}

// ─── Commands ───────────────────────────────────────────────────────

static int cmd_list(void) {
    if (!fn_GetFileCount || !fn_GetFileNameAndSize) {
        fprintf(stderr, "Error: GetFileCount/GetFileNameAndSize not available\n");
        return 1;
    }

    int count = fn_GetFileCount(g_remoteStorage);
    printf("{\"files\":[");
    for (int i = 0; i < count; i++) {
        int size = 0;
        const char *name = fn_GetFileNameAndSize(g_remoteStorage, i, &size);
        if (i > 0) printf(",");
        printf("{\"filename\":\"%s\",\"size\":%d}", name ? name : "", size);
    }
    printf("],\"count\":%d}\n", count);
    return 0;
}

static int cmd_upload(const char *local_path, const char *cloud_name) {
    if (!fn_FileWrite) {
        fprintf(stderr, "Error: FileWrite not available\n");
        return 1;
    }

    FILE *f = fopen(local_path, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open '%s'\n", local_path);
        return 1;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (size > 100 * 1024 * 1024) {
        fprintf(stderr, "Error: file too large (%ld bytes, max 100MB)\n", size);
        fclose(f);
        return 1;
    }

    void *data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);

    fprintf(stderr, "Uploading '%s' as '%s' (%ld bytes)...\n", local_path, cloud_name, size);
    int ok = fn_FileWrite(g_remoteStorage, cloud_name, data, (int)size);
    free(data);

    if (ok) {
        printf("{\"success\":true,\"filename\":\"%s\",\"size\":%ld}\n", cloud_name, size);
        fprintf(stderr, "Upload OK\n");
        return 0;
    } else {
        printf("{\"success\":false,\"error\":\"FileWrite failed\"}\n");
        fprintf(stderr, "Upload FAILED\n");
        return 1;
    }
}

static int cmd_download(const char *cloud_name, const char *local_path) {
    if (!fn_FileExists || !fn_GetFileSize || !fn_FileRead) {
        fprintf(stderr, "Error: File read functions not available\n");
        return 1;
    }

    if (!fn_FileExists(g_remoteStorage, cloud_name)) {
        fprintf(stderr, "Error: '%s' not found in cloud\n", cloud_name);
        printf("{\"success\":false,\"error\":\"file not found\"}\n");
        return 1;
    }

    int size = fn_GetFileSize(g_remoteStorage, cloud_name);
    void *data = malloc(size);

    int bytesRead = fn_FileRead(g_remoteStorage, cloud_name, data, size);
    if (bytesRead <= 0) {
        fprintf(stderr, "Error: FileRead returned %d\n", bytesRead);
        free(data);
        printf("{\"success\":false,\"error\":\"FileRead failed\"}\n");
        return 1;
    }

    // Create parent directories
    char *dir = strdup(local_path);
    char *parent = dirname(dir);
    char mkdir_cmd[4096];
    snprintf(mkdir_cmd, sizeof(mkdir_cmd), "mkdir -p '%s'", parent);
    system(mkdir_cmd);
    free(dir);

    FILE *f = fopen(local_path, "wb");
    if (!f) {
        fprintf(stderr, "Error: cannot write '%s'\n", local_path);
        free(data);
        return 1;
    }

    fwrite(data, 1, bytesRead, f);
    fclose(f);
    free(data);

    printf("{\"success\":true,\"filename\":\"%s\",\"size\":%d}\n", cloud_name, bytesRead);
    fprintf(stderr, "Downloaded '%s' → '%s' (%d bytes)\n", cloud_name, local_path, bytesRead);
    return 0;
}

static int cmd_sync_up(const char *local_dir) {
    if (!fn_FileWrite) {
        fprintf(stderr, "Error: FileWrite not available\n");
        return 1;
    }

    DIR *d = opendir(local_dir);
    if (!d) {
        fprintf(stderr, "Error: cannot open directory '%s'\n", local_dir);
        return 1;
    }

    int uploaded = 0;
    struct dirent *entry;

    while ((entry = readdir(d)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char full_path[4096];
        snprintf(full_path, sizeof(full_path), "%s/%s", local_dir, entry->d_name);

        struct stat st;
        if (stat(full_path, &st) != 0 || !S_ISREG(st.st_mode)) continue;

        FILE *f = fopen(full_path, "rb");
        if (!f) continue;

        void *data = malloc(st.st_size);
        fread(data, 1, st.st_size, f);
        fclose(f);

        fprintf(stderr, "Uploading '%s' (%lld bytes)...\n", entry->d_name, (long long)st.st_size);
        int ok = fn_FileWrite(g_remoteStorage, entry->d_name, data, (int)st.st_size);
        free(data);

        if (ok) {
            uploaded++;
            fprintf(stderr, "  OK\n");
        } else {
            fprintf(stderr, "  FAILED\n");
        }
    }
    closedir(d);

    printf("{\"uploaded\":%d}\n", uploaded);
    return 0;
}

static int cmd_sync_down(const char *local_dir) {
    if (!fn_GetFileCount || !fn_GetFileNameAndSize || !fn_FileRead) {
        fprintf(stderr, "Error: required functions not available\n");
        return 1;
    }

    // Create target dir
    char mkdir_cmd[4096];
    snprintf(mkdir_cmd, sizeof(mkdir_cmd), "mkdir -p '%s'", local_dir);
    system(mkdir_cmd);

    int count = fn_GetFileCount(g_remoteStorage);
    int downloaded = 0;

    for (int i = 0; i < count; i++) {
        int size = 0;
        const char *name = fn_GetFileNameAndSize(g_remoteStorage, i, &size);
        if (!name || size <= 0) continue;

        void *data = malloc(size);
        int bytesRead = fn_FileRead(g_remoteStorage, name, data, size);

        if (bytesRead > 0) {
            char full_path[4096];
            snprintf(full_path, sizeof(full_path), "%s/%s", local_dir, name);

            // Create parent dirs for nested filenames
            char *dir_copy = strdup(full_path);
            char *parent = dirname(dir_copy);
            char mkdir_sub[4096];
            snprintf(mkdir_sub, sizeof(mkdir_sub), "mkdir -p '%s'", parent);
            system(mkdir_sub);
            free(dir_copy);

            FILE *f = fopen(full_path, "wb");
            if (f) {
                fwrite(data, 1, bytesRead, f);
                fclose(f);
                downloaded++;
                fprintf(stderr, "Downloaded '%s' (%d bytes)\n", name, bytesRead);
            }
        }
        free(data);
    }

    printf("{\"downloaded\":%d}\n", downloaded);
    return 0;
}

static int cmd_whoami(void) {
    unsigned long long steamID = 0;
    const char *name = "";

    if (g_steamUser && fn_GetSteamID) {
        steamID = fn_GetSteamID(g_steamUser);
    }
    if (g_steamFriends && fn_GetPersonaName) {
        name = fn_GetPersonaName(g_steamFriends);
    }

    printf("{\"steamID64\":\"%llu\",\"personaName\":\"%s\"}\n", steamID, name ? name : "");
    return steamID > 0 ? 0 : 1;
}

// ─── Main ───────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage:\n");
        fprintf(stderr, "  %s whoami                                  — Get logged-in user info\n", argv[0]);
        fprintf(stderr, "  %s check                                   — Check if Steam is running\n", argv[0]);
        fprintf(stderr, "  %s list <appid>                            — List cloud files\n", argv[0]);
        fprintf(stderr, "  %s upload <appid> <local_file> <cloud_name> — Upload file\n", argv[0]);
        fprintf(stderr, "  %s download <appid> <cloud_name> <local_file> — Download file\n", argv[0]);
        fprintf(stderr, "  %s sync-up <appid> <local_dir>             — Upload all files in dir\n", argv[0]);
        fprintf(stderr, "  %s sync-down <appid> <local_dir>           — Download all cloud files\n", argv[0]);
        return 1;
    }

    const char *cmd = argv[1];

    // "check" just verifies Steam is reachable (use a dummy appid)
    if (strcmp(cmd, "check") == 0) {
        if (init_steam(480)) {  // 480 = Spacewar (Valve's test app)
            printf("{\"running\":true}\n");
            shutdown_steam();
            return 0;
        }
        printf("{\"running\":false}\n");
        return 1;
    }

    // "whoami" uses Spacewar appid to connect, then queries user info
    if (strcmp(cmd, "whoami") == 0) {
        if (!init_steam(480)) {
            fprintf(stderr, "Failed to initialize Steam API. Is Steam running?\n");
            printf("{\"error\":\"Steam not running\"}\n");
            return 1;
        }
        int result = cmd_whoami();
        shutdown_steam();
        return result;
    }

    // All other commands require <appid>
    if (argc < 3) {
        fprintf(stderr, "Error: command '%s' requires <appid>\n", cmd);
        return 1;
    }

    int appid = atoi(argv[2]);
    if (appid <= 0) {
        fprintf(stderr, "Error: invalid appid '%s'\n", argv[2]);
        return 1;
    }

    if (!init_steam(appid)) {
        fprintf(stderr, "Failed to initialize Steam API\n");
        return 1;
    }

    int result = 1;

    if (strcmp(cmd, "list") == 0) {
        result = cmd_list();
    } else if (strcmp(cmd, "upload") == 0 && argc >= 5) {
        result = cmd_upload(argv[3], argv[4]);
    } else if (strcmp(cmd, "download") == 0 && argc >= 5) {
        result = cmd_download(argv[3], argv[4]);
    } else if (strcmp(cmd, "sync-up") == 0 && argc >= 4) {
        result = cmd_sync_up(argv[3]);
    } else if (strcmp(cmd, "sync-down") == 0 && argc >= 4) {
        result = cmd_sync_down(argv[3]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
    }

    shutdown_steam();
    return result;
}
