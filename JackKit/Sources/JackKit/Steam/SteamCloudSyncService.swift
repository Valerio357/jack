//
//  SteamCloudSyncService.swift
//  JackKit
//
//  Real Steam Cloud sync using the Steam client running in Wine.
//
//  Before launch: start Steam in Wine → wait for cloud sync → copy saves
//                 from Wine's userdata/ to gbe_fork's GSE Saves/ → kill Steam
//
//  After game exit: copy saves from GSE Saves/ back to Wine's userdata/
//                   → start Steam briefly to upload → kill Steam
//
//  Key paths:
//    Wine Steam:  <bottle>/drive_c/Program Files (x86)/Steam/userdata/<steam3ID>/<appID>/remote/
//    gbe_fork:    <bottle>/drive_c/users/crossover/AppData/Roaming/GSE Saves/<appID>/remote/
//

import Foundation

public struct SteamCloudSyncResult: Sendable {
    public let fileCount: Int
    public let direction: Direction
    public let date: Date

    public enum Direction: Sendable {
        case toLocal   // Cloud → gbe_fork
        case toCloud   // gbe_fork → Cloud
    }
}

public final class SteamCloudSyncService: @unchecked Sendable {
    public static let shared = SteamCloudSyncService()
    private init() {}

    // MARK: - Steam in Wine Detection

    /// Path to steam.exe inside a Wine bottle
    public func steamExe(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "steam.exe")
    }

    /// Whether Steam is installed in the given Wine bottle
    public func isSteamInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: steamExe(in: bottle).path(percentEncoded: false))
    }

    /// Wine Steam's userdata directory for a specific game
    public func wineUserDataRemote(bottle: Bottle, appID: Int, steamID: String) -> URL? {
        guard let steam3ID = steam3ID(from: steamID) else { return nil }
        return bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "userdata")
            .appending(path: "\(steam3ID)")
            .appending(path: "\(appID)")
            .appending(path: "remote")
    }

    /// gbe_fork's save directory for a specific game
    public func gbeSavePath(bottle: Bottle, appID: Int) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "users")
            .appending(path: "crossover")
            .appending(path: "AppData")
            .appending(path: "Roaming")
            .appending(path: "GSE Saves")
            .appending(path: "\(appID)")
            .appending(path: "remote")
    }

    // MARK: - Cloud Sync (Real Steam Cloud via Wine)

    /// Download saves from Steam Cloud before game launch.
    /// Starts Steam in Wine silently, waits for cloud sync, copies saves to gbe_fork.
    @discardableResult
    public func syncFromCloud(
        appID: Int,
        steamID: String,
        bottle: Bottle,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> SteamCloudSyncResult {
        guard isSteamInstalled(in: bottle) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }
        guard let remoteDir = wineUserDataRemote(bottle: bottle, appID: appID, steamID: steamID) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }

        onStatus?("Starting Steam for cloud sync...")

        // Start Steam silently — it will auto-sync cloud saves on login
        let steamPid = try startSteamSilent(bottle: bottle)
        defer { killSteam(bottle: bottle, pid: steamPid) }

        // Wait for Steam to sync cloud saves (monitor the userdata directory)
        let synced = await waitForCloudSync(remoteDir: remoteDir, timeout: 45)
        if !synced {
            onStatus?("Cloud sync timed out — using local saves")
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }

        onStatus?("Copying cloud saves...")

        // Copy from Wine Steam userdata → gbe_fork GSE Saves
        let dest = gbeSavePath(bottle: bottle, appID: appID)
        let count = try copyDirectoryRecursive(from: remoteDir, to: dest)

        return SteamCloudSyncResult(fileCount: count, direction: .toLocal, date: Date())
    }

    /// Upload saves to Steam Cloud after game exit.
    /// Copies gbe_fork saves to Wine's userdata, then starts Steam to upload.
    @discardableResult
    public func syncToCloud(
        appID: Int,
        steamID: String,
        bottle: Bottle,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> SteamCloudSyncResult {
        let fm = FileManager.default
        guard isSteamInstalled(in: bottle) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toCloud, date: Date())
        }
        guard let remoteDir = wineUserDataRemote(bottle: bottle, appID: appID, steamID: steamID) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toCloud, date: Date())
        }

        let src = gbeSavePath(bottle: bottle, appID: appID)
        guard fm.fileExists(atPath: src.path(percentEncoded: false)) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toCloud, date: Date())
        }

        onStatus?("Copying saves for upload...")

        // Copy from gbe_fork GSE Saves → Wine Steam userdata
        let count = try copyDirectoryRecursive(from: src, to: remoteDir)
        guard count > 0 else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toCloud, date: Date())
        }

        onStatus?("Uploading to Steam Cloud...")

        // Start Steam briefly so it detects the changed files and uploads them
        let steamPid = try startSteamSilent(bottle: bottle)

        // Give Steam time to detect changes and start uploading
        try? await Task.sleep(for: .seconds(20))

        killSteam(bottle: bottle, pid: steamPid)

        return SteamCloudSyncResult(fileCount: count, direction: .toCloud, date: Date())
    }

    /// Count save files in gbe_fork's local save directory for a game.
    public func localSaveFileCount(appID: Int, bottle: Bottle) -> Int {
        let path = gbeSavePath(bottle: bottle, appID: appID)
        return fileCount(in: path)
    }

    /// Count save files in Wine Steam's cloud-synced directory for a game.
    public func cloudSaveFileCount(appID: Int, steamID: String, bottle: Bottle) -> Int {
        guard let path = wineUserDataRemote(bottle: bottle, appID: appID, steamID: steamID) else { return 0 }
        return fileCount(in: path)
    }

    // MARK: - Fast Path (no Steam startup, just file copy)

    /// Copy already-synced cloud saves to gbe_fork (instant, no Steam startup).
    /// Use this during game launch to avoid blocking.
    @discardableResult
    public func copyCloudToLocal(appID: Int, steamID: String, bottle: Bottle) -> Int {
        guard let src = wineUserDataRemote(bottle: bottle, appID: appID, steamID: steamID),
              FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else { return 0 }
        let dest = gbeSavePath(bottle: bottle, appID: appID)
        return (try? copyDirectoryRecursive(from: src, to: dest)) ?? 0
    }

    /// Copy gbe_fork saves back to Wine Steam's userdata (instant, no Steam startup).
    @discardableResult
    public func copyLocalToCloud(appID: Int, steamID: String, bottle: Bottle) -> Int {
        let src = gbeSavePath(bottle: bottle, appID: appID)
        guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else { return 0 }
        guard let dest = wineUserDataRemote(bottle: bottle, appID: appID, steamID: steamID) else { return 0 }
        return (try? copyDirectoryRecursive(from: src, to: dest)) ?? 0
    }

    /// Start Steam briefly to trigger cloud upload, then kill it.
    public func uploadToCloud(bottle: Bottle) async throws {
        let steamPid = try startSteamSilent(bottle: bottle)
        try? await Task.sleep(for: .seconds(20))
        killSteam(bottle: bottle, pid: steamPid)
    }

    // MARK: - Fallback: macOS Steam userdata (no Wine needed)

    /// Root of macOS Steam userdata directory (native Mac Steam app)
    public var steamMacUserDataRoot: URL? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Application Support")
            .appending(path: "Steam")
            .appending(path: "userdata")
        return FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) ? path : nil
    }

    public var isSteamMacInstalled: Bool { steamMacUserDataRoot != nil }

    /// Sync from native macOS Steam userdata (offline fallback when Wine Steam isn't logged in).
    @discardableResult
    public func syncFromMacSteam(
        appID: Int, steamID: String, bottle: Bottle
    ) throws -> SteamCloudSyncResult {
        guard let root = steamMacUserDataRoot,
              let steam3 = steam3ID(from: steamID) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }
        let src = root.appending(path: "\(steam3)").appending(path: "\(appID)").appending(path: "remote")
        guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
            return SteamCloudSyncResult(fileCount: 0, direction: .toLocal, date: Date())
        }
        let dest = gbeSavePath(bottle: bottle, appID: appID)
        let count = try copyDirectoryRecursive(from: src, to: dest)
        return SteamCloudSyncResult(fileCount: count, direction: .toLocal, date: Date())
    }

    // MARK: - Private: Steam Process Management

    /// Start Steam in Wine silently (minimized to tray, no main window).
    private func startSteamSilent(bottle: Bottle) throws -> Int32 {
        let process = Process()
        process.executableURL = Wine.wineBinary
        process.arguments = [steamExe(in: bottle).path(percentEncoded: false), "-silent", "-noverifyfiles"]
        process.currentDirectoryURL = Wine.wineBinary.deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.url.path(percentEncoded: false)
        process.environment = env

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        return process.processIdentifier
    }

    /// Wait for cloud sync by monitoring the userdata/remote directory.
    /// Returns true if files appeared or were modified, false on timeout.
    private func waitForCloudSync(remoteDir: URL, timeout: Int) async -> Bool {
        let fm = FileManager.default
        let checkInterval: Duration = .seconds(2)

        // Get initial state
        let initialMod = Self.latestModification(in: remoteDir)

        for _ in 0..<(timeout / 2) {
            try? await Task.sleep(for: checkInterval)

            // Check if the directory now exists with files
            if fm.fileExists(atPath: remoteDir.path(percentEncoded: false)) {
                let currentMod = Self.latestModification(in: remoteDir)
                let count = fileCount(in: remoteDir)

                if count > 0 {
                    // If files existed before, check if they were updated
                    if let initial = initialMod, let current = currentMod {
                        if current > initial { return true }
                        // Files exist but unchanged — Steam may have confirmed they're up to date
                        // Wait a bit more then accept
                        try? await Task.sleep(for: .seconds(3))
                        return true
                    }
                    // New files appeared
                    return true
                }
            }
        }

        // Timeout — check one last time
        return fm.fileExists(atPath: remoteDir.path(percentEncoded: false))
            && fileCount(in: remoteDir) > 0
    }

    /// Kill Steam processes in the Wine prefix.
    private func killSteam(bottle: Bottle, pid: Int32) {
        // Kill the Wine process we started
        kill(pid, SIGTERM)

        // Also kill any steam processes in Wine
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "steam\\.exe|steamwebhelper"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    // MARK: - Private: Helpers

    private func steam3ID(from steamID64: String) -> Int64? {
        guard let id64 = Int64(steamID64) else { return nil }
        let id = id64 - 76561197960265728
        return id > 0 ? id : nil
    }

    /// Recursively copy a directory, preserving subdirectory structure.
    private func copyDirectoryRecursive(from src: URL, to dest: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else { return 0 }

        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])

            // Compute relative path
            let relative = fileURL.path(percentEncoded: false)
                .replacingOccurrences(of: src.path(percentEncoded: false) + "/", with: "")
            let destURL = dest.appending(path: relative)

            if attrs?.isDirectory == true {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else if attrs?.isRegularFile == true {
                try? fm.removeItem(at: destURL)
                try fm.copyItem(at: fileURL, to: destURL)
                count += 1
            }
        }
        return count
    }

    private func fileCount(in dir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if attrs?.isRegularFile == true { count += 1 }
        }
        return count
    }

    /// Get the latest file modification date in a directory.
    private static func latestModification(in dir: URL) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var latest: Date?
        while let url = enumerator.nextObject() as? URL {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let m = mod, latest == nil || m > latest! { latest = m }
        }
        return latest
    }
}
