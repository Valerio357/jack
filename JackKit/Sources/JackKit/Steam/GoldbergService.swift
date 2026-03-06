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
        case .releaseNotFound:  return "Nessuna release Goldberg trovata su GitHub."
        case .downloadFailed:   return "Download Goldberg fallito."
        case .extractionFailed: return "Estrazione Goldberg fallita."
        case .dllNotFound:      return "steam_api.dll non trovata nella release."
        }
    }
}

public final class GoldbergService: @unchecked Sendable {
    public static let shared = GoldbergService()

    private let goldbergDir = BottleData.steamCMDDir.appending(path: "Goldberg")
    private static let githubAPI = "https://api.github.com/repos/otavepto/gbe_fork/releases/latest"

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

        // Fetch latest release metadata from GitHub
        guard let apiURL = URL(string: Self.githubAPI) else { throw GoldbergError.downloadFailed }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (apiData, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: apiData)

        // Find the Windows release zip (look for "win" in name)
        guard let asset = release.assets.first(where: {
            let n = $0.name.lowercased()
            return n.contains("win") && n.hasSuffix(".zip")
        }) ?? release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw GoldbergError.releaseNotFound
        }

        guard let downloadURL = URL(string: asset.browser_download_url) else {
            throw GoldbergError.downloadFailed
        }

        // Download zip
        let (tempZip, response) = try await URLSession.shared.download(from: downloadURL)
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

        // Find and copy steam_api*.dll — done synchronously to avoid Sendable issues
        let found = Self.copyDLLs(from: extractDir, to: goldbergDir)
        try? fm.removeItem(at: extractDir)
        guard found else { throw GoldbergError.dllNotFound }
    }

    // MARK: - Private helpers

    private static func copyDLLs(from extractDir: URL, to destDir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: nil) else {
            return false
        }
        var found = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard name == "steam_api.dll" || name == "steam_api64.dll" else { continue }
            let dest = destDir.appending(path: url.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: url, to: dest)
            found = true
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

        // Replace DLLs — also search one level deep for dlls next to sub-exes
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

// MARK: - GitHub API models

private struct GitHubRelease: Decodable {
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
}
