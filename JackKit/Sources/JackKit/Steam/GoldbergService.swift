//
//  GoldbergService.swift
//  JackKit
//
//  Replaces steam_api.dll / steam_api64.dll with the Goldberg Steam Emulator
//  so games can run without a Steam client (Steamworks DRM bypass for owned games).
//  Project: https://github.com/Detanup01/gbe_fork
//

import Foundation

public enum GoldbergError: LocalizedError {
    case releaseNotFound
    case downloadFailed
    case extractionFailed
    case dllNotFound

    public var errorDescription: String? {
        switch self {
        case .releaseNotFound:  return "No Goldberg release found on GitHub."
        case .downloadFailed:   return "Goldberg download failed."
        case .extractionFailed: return "Goldberg extraction failed."
        case .dllNotFound:      return "steam_api.dll not found in the release."
        }
    }
}

public final class GoldbergService: @unchecked Sendable {
    public static let shared = GoldbergService()

    private let goldbergDir = BottleData.steamCMDDir.appending(path: "Goldberg")
    // gbe_fork (maintained Goldberg fork) — experimental build for maximum API coverage
    private static let downloadURL = "https://github.com/Detanup01/gbe_fork/releases/download/release-2026_02_19/emu-win-release.7z"

    private var dll32: URL { goldbergDir.appending(path: "steam_api.dll") }
    private var dll64: URL { goldbergDir.appending(path: "steam_api64.dll") }

    /// Version marker — bump when changing download URL to force re-download.
    private static let currentVersion = "gbe_fork_2026_02_19"
    private var versionFile: URL { goldbergDir.appending(path: ".gbe_version") }

    public var isInstalled: Bool {
        let fm = FileManager.default
        let hasDLL = fm.fileExists(atPath: dll32.path(percentEncoded: false))
            || fm.fileExists(atPath: dll64.path(percentEncoded: false))
        guard hasDLL else { return false }
        // Check version marker to detect stale installs
        let version = (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return version == Self.currentVersion
    }

    private init() {}

    // MARK: - Install

    public func ensureInstalled() async throws {
        if isInstalled { return }

        let fm = FileManager.default
        // Clean old install (version mismatch or missing)
        try? fm.removeItem(at: goldbergDir)
        try fm.createDirectory(at: goldbergDir, withIntermediateDirectories: true)

        guard let url = URL(string: Self.downloadURL) else { throw GoldbergError.downloadFailed }

        let (tempFile, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoldbergError.downloadFailed
        }

        // Extract with bsdtar (supports 7z natively on macOS)
        let extractDir = goldbergDir.appending(path: "tmp_extract")
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        extract.arguments = ["-xf", tempFile.path(percentEncoded: false),
                             "-C", extractDir.path(percentEncoded: false)]
        try extract.run()
        extract.waitUntilExit()
        try? fm.removeItem(at: tempFile)

        guard extract.terminationStatus == 0 else { throw GoldbergError.extractionFailed }

        // gbe_fork structure: release/experimental/x64/ and release/experimental/x32/
        // Also copy steamclient from release/steamclient_experimental/
        let found = Self.copyDLLs(from: extractDir, to: goldbergDir)
        try? fm.removeItem(at: extractDir)
        guard found else { throw GoldbergError.dllNotFound }

        // Write version marker
        try Self.currentVersion.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Private helpers

    /// Copy DLLs from gbe_fork extracted archive.
    /// Uses experimental build for maximum API coverage.
    /// Structure: release/experimental/x64/steam_api64.dll, release/experimental/x32/steam_api.dll
    /// steamclient: release/steamclient_experimental/steamclient*.dll
    private static func copyDLLs(from extractDir: URL, to destDir: URL) -> Bool {
        let fm = FileManager.default
        var found = false

        // Map: source relative path prefix -> DLL files to copy
        let sources: [(dir: String, files: [String])] = [
            ("release/experimental/x64", ["steam_api64.dll", "steamclient64.dll"]),
            ("release/experimental/x32", ["steam_api.dll", "steamclient.dll"]),
            ("release/steamclient_experimental", ["steamclient.dll", "steamclient64.dll"]),
        ]

        for source in sources {
            let sourceDir = extractDir.appending(path: source.dir)
            for file in source.files {
                let src = sourceDir.appending(path: file)
                guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
                let dest = destDir.appending(path: file)
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
                if file.hasPrefix("steam_api") { found = true }
            }
        }
        return found
    }

    // MARK: - Apply / Remove

    /// Replace steam_api*.dll in the game directory with Goldberg DLLs.
    /// Searches the entire game directory tree (UE4 games often place DLLs
    /// in subdirectories like Engine/Binaries/ThirdParty/).
    /// Creates `steam_settings/` with minimal config next to each replaced DLL.
    public func apply(to exeDir: URL, gameDir: URL? = nil, appID: Int, username: String, steamID: String) throws {
        let fm = FileManager.default
        let searchRoot = gameDir ?? exeDir

        // Find all steam_api*.dll locations in the game directory tree
        var dllLocations = Set<URL>() // directories containing steam_api DLLs
        if let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent.lowercased()
                if name == "steam_api.dll" || name == "steam_api64.dll" {
                    dllLocations.insert(fileURL.deletingLastPathComponent())
                }
            }
        }
        // Always include the exe directory itself
        dllLocations.insert(exeDir)

        for dir in dllLocations {
            // steam_settings folder next to the DLLs (gbe_fork ini format)
            let settingsDir = dir.appending(path: "steam_settings")
            try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)

            // App ID (still plain text in gbe_fork)
            try "\(appID)\n".write(to: settingsDir.appending(path: "steam_appid.txt"),
                                   atomically: true, encoding: .utf8)

            // User config (gbe_fork ini format)
            var userIni = "[user::general]\n"
            userIni += "account_name=\(username)\n"
            if !steamID.isEmpty {
                userIni += "account_steamid=\(steamID)\n"
            }
            userIni += "language=english\n"
            try userIni.write(to: settingsDir.appending(path: "configs.user.ini"),
                              atomically: true, encoding: .utf8)

            // Main config: disable overlay (crashes under Wine)
            var mainIni = "[main::general]\n"
            mainIni += "new_app_ticket=1\n"
            mainIni += "gc_token=1\n"
            try mainIni.write(to: settingsDir.appending(path: "configs.main.ini"),
                              atomically: true, encoding: .utf8)

            // Overlay config: disable it
            let overlayIni = "[overlay::general]\nenable_experimental_overlay=0\n"
            try overlayIni.write(to: settingsDir.appending(path: "configs.overlay.ini"),
                                 atomically: true, encoding: .utf8)

            // Unlock all DLCs by default
            let appIni = "[app::dlcs]\nunlock_all=1\n"
            try appIni.write(to: settingsDir.appending(path: "configs.app.ini"),
                             atomically: true, encoding: .utf8)

            // Replace steam_api DLLs (backup originals)
            for dllName in ["steam_api.dll", "steam_api64.dll"] {
                let goldbergDLL = goldbergDir.appending(path: dllName)
                guard fm.fileExists(atPath: goldbergDLL.path(percentEncoded: false)) else { continue }

                let target = dir.appending(path: dllName)
                guard fm.fileExists(atPath: target.path(percentEncoded: false)) else { continue }

                let backup = dir.appending(path: dllName + ".original_jack")
                if !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
                    try fm.copyItem(at: target, to: backup)
                }
                try fm.removeItem(at: target)
                try fm.copyItem(at: goldbergDLL, to: target)
            }

            // Copy steamclient*.dll so Goldberg uses its own emulated client
            for dllName in ["steamclient.dll", "steamclient64.dll"] {
                let goldbergDLL = goldbergDir.appending(path: dllName)
                guard fm.fileExists(atPath: goldbergDLL.path(percentEncoded: false)) else { continue }
                let target = dir.appending(path: dllName)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: goldbergDLL, to: target)
            }
        }
    }

    /// Restore original steam_api*.dll and remove steam_settings/ from the entire game tree.
    public func remove(from exeDir: URL, gameDir: URL? = nil) {
        let fm = FileManager.default
        let searchRoot = gameDir ?? exeDir

        // Find all directories with .original_jack backups
        var dirs = Set<URL>()
        dirs.insert(exeDir)
        if let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.hasSuffix(".original_jack") {
                    dirs.insert(fileURL.deletingLastPathComponent())
                }
            }
        }

        for dir in dirs {
            for dllName in ["steam_api.dll", "steam_api64.dll"] {
                let target = dir.appending(path: dllName)
                let backup = dir.appending(path: dllName + ".original_jack")
                guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else { continue }
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: backup, to: target)
                try? fm.removeItem(at: backup)
            }
            for dllName in ["steamclient.dll", "steamclient64.dll"] {
                try? fm.removeItem(at: dir.appending(path: dllName))
            }
            try? fm.removeItem(at: dir.appending(path: "steam_settings"))
        }
    }

    /// Returns true if Goldberg DLLs are currently active in this directory tree.
    public func isActive(in exeDir: URL, gameDir: URL? = nil) -> Bool {
        let fm = FileManager.default
        let searchRoot = gameDir ?? exeDir
        if let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.hasSuffix(".original_jack") {
                    return true
                }
            }
        }
        return false
    }
}

