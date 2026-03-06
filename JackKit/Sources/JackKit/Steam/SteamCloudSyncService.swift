//
//  SteamCloudSyncService.swift
//  JackKit
//
//  Syncs save files between macOS Steam installation and Goldberg local saves.
//  Uses the same userdata/<accountID>/<appID>/remote/ structure both use.
//
//  Flow (before launch):  Steam Mac userdata → Goldberg local saves
//  Flow (after game exit): Goldberg local saves → Steam Mac userdata
//

import Foundation

public struct SteamCloudSyncResult {
    public let fileCount: Int
    public let direction: Direction
    public let date: Date

    public enum Direction {
        case toLocal   // Steam → Goldberg
        case toCloud   // Goldberg → Steam
    }
}

public final class SteamCloudSyncService: @unchecked Sendable {
    public static let shared = SteamCloudSyncService()
    private init() {}

    // MARK: - Steam Mac Detection

    /// Root of macOS Steam userdata directory
    public var steamMacUserDataRoot: URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library")
                .appending(path: "Application Support")
                .appending(path: "Steam")
                .appending(path: "userdata"),
            // Alternate: if installed via Steam flatpak-like on older Macs
            URL(fileURLWithPath: "/Applications/Steam.app")
                .appending(path: "Contents/MacOS/steam/userdata")
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    public var isSteamMacInstalled: Bool { steamMacUserDataRoot != nil }

    /// Path to cloud saves for a specific game in macOS Steam
    public func cloudSavePath(appID: Int, steamID: String) -> URL? {
        guard let root = steamMacUserDataRoot,
              let accountID = accountID(from: steamID) else { return nil }
        let path = root
            .appending(path: "\(accountID)")
            .appending(path: "\(appID)")
            .appending(path: "remote")
        return FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) ? path : nil
    }

    /// Path where Goldberg stores saves for a game
    public func goldbergSavePath(appID: Int, steamID: String, exeDir: URL) -> URL? {
        guard let accountID = accountID(from: steamID) else { return nil }
        return exeDir
            .appending(path: "steam_settings")
            .appending(path: "USERDATA")
            .appending(path: "\(accountID)")
            .appending(path: "\(appID)")
            .appending(path: "remote")
    }

    // MARK: - Sync

    /// Copy saves from macOS Steam → Goldberg (before game launch)
    @discardableResult
    public func syncToLocal(appID: Int, steamID: String, exeDir: URL) throws -> SteamCloudSyncResult {
        guard let src = cloudSavePath(appID: appID, steamID: steamID) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }
        guard let dest = goldbergSavePath(appID: appID, steamID: steamID, exeDir: exeDir) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }
        let count = try copyDirectory(from: src, to: dest)
        return SteamCloudSyncResult(fileCount: count, direction: .toLocal, date: Date())
    }

    /// Copy saves from Goldberg → macOS Steam (after game exit)
    @discardableResult
    public func syncToCloud(appID: Int, steamID: String, exeDir: URL) throws -> SteamCloudSyncResult {
        guard let src = goldbergSavePath(appID: appID, steamID: steamID, exeDir: exeDir),
              FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toCloud, date: Date())
        }
        guard steamMacUserDataRoot != nil,
              let accountID = accountID(from: steamID) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toCloud, date: Date())
        }
        let dest = steamMacUserDataRoot!
            .appending(path: "\(accountID)")
            .appending(path: "\(appID)")
            .appending(path: "remote")
        let count = try copyDirectory(from: src, to: dest)
        return SteamCloudSyncResult(fileCount: count, direction: .toCloud, date: Date())
    }

    /// Count save files available in Steam Mac for a game
    public func cloudSaveFileCount(appID: Int, steamID: String) -> Int {
        guard let path = cloudSavePath(appID: appID, steamID: steamID) else { return 0 }
        return (try? FileManager.default.contentsOfDirectory(atPath: path.path(percentEncoded: false)))?.count ?? 0
    }

    // MARK: - Private

    private func accountID(from steamID64: String) -> Int64? {
        guard let id64 = Int64(steamID64) else { return nil }
        return id64 - 76561197960265728
    }

    private func copyDirectory(from src: URL, to dest: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        for file in files {
            let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard attrs?.isRegularFile == true else { continue }
            let destFile = dest.appending(path: file.lastPathComponent)
            if fm.fileExists(atPath: destFile.path(percentEncoded: false)) {
                try fm.removeItem(at: destFile)
            }
            try fm.copyItem(at: file, to: destFile)
            count += 1
        }
        return count
    }
}
