//
//  GoldbergService.swift
//  JackKit
//
//  Replaces steam_api.dll / steam_api64.dll with the Goldberg Steam Emulator
//  so games can run without a Steam client (Steamworks DRM bypass for owned games).
//  Uses Mr_Goldberg's original emulator (graceful handling of missing interfaces).
//  Project: https://gitlab.com/Mr_Goldberg/goldberg_emulator
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
    // Original Mr_Goldberg emulator — handles missing interfaces gracefully (no popups)
    private static let downloadURL = "https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/jobs/4247811310/artifacts/download"

    private var dll32: URL { goldbergDir.appending(path: "steam_api.dll") }
    private var dll64: URL { goldbergDir.appending(path: "steam_api64.dll") }

    /// Version marker — bump when changing download URL to force re-download.
    private static let currentVersion = "goldberg_og_0.2.5"
    private var versionFile: URL { goldbergDir.appending(path: ".gbe_version") }

    public var isInstalled: Bool {
        let fm = FileManager.default
        let hasDLL = fm.fileExists(atPath: dll32.path(percentEncoded: false))
            || fm.fileExists(atPath: dll64.path(percentEncoded: false))
        guard hasDLL else { return false }
        let version = (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return version == Self.currentVersion
    }

    private init() {}

    // MARK: - Install

    public func ensureInstalled() async throws {
        if isInstalled { return }

        let fm = FileManager.default
        try? fm.removeItem(at: goldbergDir)
        try fm.createDirectory(at: goldbergDir, withIntermediateDirectories: true)

        guard let url = URL(string: Self.downloadURL) else { throw GoldbergError.downloadFailed }

        let (tempFile, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoldbergError.downloadFailed
        }

        // Extract zip (original Goldberg uses zip, not 7z)
        let extractDir = goldbergDir.appending(path: "tmp_extract")
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-qo", tempFile.path(percentEncoded: false),
                             "-d", extractDir.path(percentEncoded: false)]
        try extract.run()
        extract.waitUntilExit()
        try? fm.removeItem(at: tempFile)

        guard extract.terminationStatus == 0 else { throw GoldbergError.extractionFailed }

        // Original Goldberg structure: root has steam_api.dll + steam_api64.dll
        // experimental/ has steamclient.dll + steamclient64.dll
        let found = Self.copyDLLs(from: extractDir, to: goldbergDir)
        try? fm.removeItem(at: extractDir)
        guard found else { throw GoldbergError.dllNotFound }

        try Self.currentVersion.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Private helpers

    /// Copy DLLs from original Goldberg extracted archive.
    private static func copyDLLs(from extractDir: URL, to destDir: URL) -> Bool {
        let fm = FileManager.default
        var found = false

        // Original Goldberg: steam_api*.dll in root, steamclient*.dll in experimental/
        let sources: [(dir: String, files: [String])] = [
            (".", ["steam_api.dll", "steam_api64.dll"]),
            ("experimental", ["steamclient.dll", "steamclient64.dll",
                              "steam_api.dll", "steam_api64.dll"]),
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
    /// Creates `steam_settings/` with config next to each replaced DLL.
    public func apply(to exeDir: URL, gameDir: URL? = nil, appID: Int, username: String, steamID: String) throws {
        let fm = FileManager.default
        let searchRoot = gameDir ?? exeDir

        // Find all steam_api*.dll locations in the game directory tree
        var dllLocations = Set<URL>()
        if let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent.lowercased()
                if name == "steam_api.dll" || name == "steam_api64.dll" {
                    dllLocations.insert(fileURL.deletingLastPathComponent())
                }
            }
        }
        dllLocations.insert(exeDir)

        for dir in dllLocations {
            // steam_settings folder (original Goldberg format: plain text files)
            let settingsDir = dir.appending(path: "steam_settings")
            try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)

            // steam_appid.txt (also in steam_settings and beside the DLL)
            try "\(appID)".write(to: settingsDir.appending(path: "steam_appid.txt"),
                                 atomically: true, encoding: .utf8)

            // force_account_name.txt
            if !username.isEmpty {
                try username.write(to: settingsDir.appending(path: "force_account_name.txt"),
                                   atomically: true, encoding: .utf8)
            }

            // force_steamid.txt
            if !steamID.isEmpty {
                try steamID.write(to: settingsDir.appending(path: "force_steamid.txt"),
                                  atomically: true, encoding: .utf8)
            }

            // force_language.txt
            try "english".write(to: settingsDir.appending(path: "force_language.txt"),
                                atomically: true, encoding: .utf8)

            // disable_overlay.txt — overlay crashes under Wine
            try "".write(to: settingsDir.appending(path: "disable_overlay.txt"),
                         atomically: true, encoding: .utf8)

            // Replace steam_api DLLs (backup originals if they exist, or place new ones)
            for dllName in ["steam_api.dll", "steam_api64.dll"] {
                let goldbergDLL = goldbergDir.appending(path: dllName)
                guard fm.fileExists(atPath: goldbergDLL.path(percentEncoded: false)) else { continue }

                let target = dir.appending(path: dllName)
                if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                    let backup = dir.appending(path: dllName + ".original_jack")
                    if !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
                        try fm.copyItem(at: target, to: backup)
                    }
                    try fm.removeItem(at: target)
                }
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

            // Clean up gbe_fork artifacts if switching from gbe_fork
            for file in ["configs.main.ini", "configs.user.ini", "configs.app.ini",
                         "configs.overlay.ini", "steam_interfaces.txt"] {
                try? fm.removeItem(at: settingsDir.appending(path: file))
            }
            try? fm.removeItem(at: dir.appending(path: "EMU_MISSING_INTERFACE.txt"))
        }
    }

    /// Restore original steam_api*.dll and remove steam_settings/ from the entire game tree.
    public func remove(from exeDir: URL, gameDir: URL? = nil) {
        let fm = FileManager.default
        let searchRoot = gameDir ?? exeDir

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
            try? fm.removeItem(at: dir.appending(path: "EMU_MISSING_INTERFACE.txt"))
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
