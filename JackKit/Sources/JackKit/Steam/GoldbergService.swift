//
//  GoldbergService.swift
//  JackKit
//
//  Replaces steam_api.dll / steam_api64.dll with the Goldberg Steam Emulator
//  so games can run without a Steam client (Steamworks DRM bypass for owned games).
//  Project: https://github.com/otavepto/gbe_fork
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
    // Direct download URL for Goldberg Steam Emulator v0.2.5 (stable, .zip, no 7z dependency)
    private static let downloadURL = "https://gitlab.com/Mr_Goldberg/goldberg_emulator/uploads/2524331e488ec6399c396cf48bbe9903/Goldberg_Lan_Steam_Emu_v0.2.5.zip"

    private var dll32: URL { goldbergDir.appending(path: "steam_api.dll") }
    private var dll64: URL { goldbergDir.appending(path: "steam_api64.dll") }

    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dll32.path(percentEncoded: false))
            || fm.fileExists(atPath: dll64.path(percentEncoded: false))
    }

    private init() {}

    // MARK: - Install

    public func ensureInstalled() async throws {
        if isInstalled { return }

        let fm = FileManager.default
        try fm.createDirectory(at: goldbergDir, withIntermediateDirectories: true)

        guard let url = URL(string: Self.downloadURL) else { throw GoldbergError.downloadFailed }

        let (tempZip, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoldbergError.downloadFailed
        }

        // Extract with unzip
        let extractDir = goldbergDir.appending(path: "tmp_extract")
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", tempZip.path(percentEncoded: false),
                           "-d", extractDir.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        try? fm.removeItem(at: tempZip)

        guard unzip.terminationStatus == 0 else { throw GoldbergError.extractionFailed }

        // Find and copy steam_api*.dll
        let found = Self.copyDLLs(from: extractDir, to: goldbergDir)
        try? fm.removeItem(at: extractDir)
        guard found else { throw GoldbergError.dllNotFound }
    }

    // MARK: - Private helpers

    /// DLL names to extract from the Goldberg zip.
    /// steamclient*.dll are in experimental/ and needed to prevent loading the real Steam client.
    private static let goldbergDLLNames: Set<String> = [
        "steam_api.dll", "steam_api64.dll",
        "steamclient.dll", "steamclient64.dll"
    ]

    private static func copyDLLs(from extractDir: URL, to destDir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: nil) else {
            return false
        }
        var found = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard goldbergDLLNames.contains(name) else { continue }
            let dest = destDir.appending(path: url.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: url, to: dest)
            if name.hasPrefix("steam_api") { found = true }
        }
        return found
    }

    // MARK: - Apply / Remove

    /// Replace steam_api*.dll in the exe's directory with Goldberg DLLs.
    /// Creates `steam_settings/` with minimal config.
    public func apply(to exeDir: URL, appID: Int, username: String, steamID: String) throws {
        let fm = FileManager.default

        // steam_settings folder next to the exe
        let settingsDir = exeDir.appending(path: "steam_settings")
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        try "\(appID)\n".write(to: settingsDir.appending(path: "steam_appid.txt"),
                               atomically: true, encoding: .utf8)
        try username.write(to: settingsDir.appending(path: "account_name.txt"),
                           atomically: true, encoding: .utf8)
        if !steamID.isEmpty {
            try steamID.write(to: settingsDir.appending(path: "user_steam_id.txt"),
                              atomically: true, encoding: .utf8)
        }
        // Disable Steam overlay (can cause crashes under Wine)
        try "".write(to: settingsDir.appending(path: "disable_overlay.txt"),
                     atomically: true, encoding: .utf8)

        // Replace steam_api DLLs (backup originals)
        for dllName in ["steam_api.dll", "steam_api64.dll"] {
            let goldbergDLL = goldbergDir.appending(path: dllName)
            guard fm.fileExists(atPath: goldbergDLL.path(percentEncoded: false)) else { continue }

            let target = exeDir.appending(path: dllName)
            guard fm.fileExists(atPath: target.path(percentEncoded: false)) else { continue }

            let backup = exeDir.appending(path: dllName + ".original_jack")
            if !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
                try fm.copyItem(at: target, to: backup)
            }
            try fm.removeItem(at: target)
            try fm.copyItem(at: goldbergDLL, to: target)
        }

        // Copy steamclient*.dll to game dir so Goldberg uses its own emulated client
        // instead of the real Steam one from C:\Program Files (x86)\Steam\
        for dllName in ["steamclient.dll", "steamclient64.dll"] {
            let goldbergDLL = goldbergDir.appending(path: dllName)
            guard fm.fileExists(atPath: goldbergDLL.path(percentEncoded: false)) else { continue }
            let target = exeDir.appending(path: dllName)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: goldbergDLL, to: target)
        }
    }

    /// Restore original steam_api*.dll and remove steam_settings/.
    public func remove(from exeDir: URL) {
        let fm = FileManager.default
        for dllName in ["steam_api.dll", "steam_api64.dll"] {
            let target = exeDir.appending(path: dllName)
            let backup = exeDir.appending(path: dllName + ".original_jack")
            guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else { continue }
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: backup, to: target)
            try? fm.removeItem(at: backup)
        }
        // Remove steamclient DLLs added by Goldberg (these don't have backups)
        for dllName in ["steamclient.dll", "steamclient64.dll"] {
            try? fm.removeItem(at: exeDir.appending(path: dllName))
        }
        try? fm.removeItem(at: exeDir.appending(path: "steam_settings"))
    }

    /// Returns true if Goldberg DLLs are currently active in this directory.
    public func isActive(in exeDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: exeDir.appending(path: "steam_api.dll.original_jack").path(percentEncoded: false)
        ) || FileManager.default.fileExists(
            atPath: exeDir.appending(path: "steam_api64.dll.original_jack").path(percentEncoded: false)
        )
    }
}

