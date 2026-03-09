//
//  SteamCloudWebAPI.swift
//  JackKit
//
//  Steam Cloud sync using jacksteam.py Python CLI.
//  Connects directly to Steam network — no Steam.app needed.
//
//  Supports both ISteamRemoteStorage and Auto-Cloud files.
//  Auto-Cloud files are downloaded with their path prefixes
//  (e.g. %WinAppDataLocal%) and placed in the correct Wine prefix dir.
//
//  Flow:
//    Before launch: Steam Cloud → Wine prefix (restore saves)
//    After exit:    Wine prefix → Steam Cloud (upload saves)
//

import Foundation
import os.log

public final class SteamCloudWebAPI: @unchecked Sendable {
    public static let shared = SteamCloudWebAPI()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamCloud")

    private init() {}

    // MARK: - Public types

    public struct CloudFile: Sendable {
        public let filename: String
        public let size: Int
    }

    public struct SyncResult: Sendable {
        public let filesDownloaded: Int
        public let filesUploaded: Int
        public let filesDeleted: Int
    }

    // MARK: - Enumerate files

    /// List all Cloud files for a game.
    public func enumerateFiles(appID: Int) async throws -> [CloudFile] {
        let native = SteamNativeService.shared
        let files = try await native.cloudList(appID: appID)
        return files.map { CloudFile(filename: $0.filename, size: $0.size) }
    }

    // MARK: - Sync Before Launch (Cloud → Wine Prefix)

    /// Sync cloud saves before game launch.
    /// Downloads from Steam Cloud directly and places in Wine prefix.
    public func syncBeforeLaunch(
        appID: Int,
        saveDir: URL,
        bottle: Bottle? = nil,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> SyncResult {
        guard SteamSessionManager.shared.isLoggedIn else {
            return SyncResult(filesDownloaded: 0, filesUploaded: 0, filesDeleted: 0)
        }

        onStatus?("Syncing saves from Steam Cloud...")

        var totalCount = 0

        if let bottle {
            do {
                let native = SteamNativeService.shared
                let count = try await native.cloudSyncDown(
                    appID: appID,
                    bottlePath: bottle.url.path(percentEncoded: false)
                )
                totalCount = count
                Self.log.info("Downloaded \(count) cloud files for app \(appID)")
            } catch {
                Self.log.info("Cloud sync-down failed: \(error.localizedDescription)")
            }
        }

        Self.log.info("Total synced \(totalCount) files before launch for app \(appID)")
        onStatus?("Synced \(totalCount) saves from Steam Cloud")
        return SyncResult(filesDownloaded: totalCount, filesUploaded: 0, filesDeleted: 0)
    }

    // MARK: - Sync After Exit (Wine Prefix → Cloud)

    /// Sync cloud saves after game exit.
    /// Collects from Wine prefix and uploads to Steam Cloud.
    public func syncAfterExit(
        appID: Int,
        saveDir: URL,
        bottle: Bottle? = nil,
        autoCloudDirs: [URL] = [],
        onStatus: ((String) -> Void)? = nil
    ) async throws -> SyncResult {
        guard SteamSessionManager.shared.isLoggedIn else {
            return SyncResult(filesDownloaded: 0, filesUploaded: 0, filesDeleted: 0)
        }

        onStatus?("Uploading saves to Steam Cloud...")

        var totalCount = 0

        if let bottle {
            do {
                let native = SteamNativeService.shared
                let count = try await native.cloudSyncUp(
                    appID: appID,
                    bottlePath: bottle.url.path(percentEncoded: false)
                )
                totalCount = count
                Self.log.info("Uploaded \(count) files to Steam Cloud for app \(appID)")
            } catch {
                Self.log.info("Cloud sync-up failed: \(error.localizedDescription)")
            }
        }

        onStatus?("Uploaded \(totalCount) saves to Steam Cloud")
        return SyncResult(filesDownloaded: 0, filesUploaded: totalCount, filesDeleted: 0)
    }

    // MARK: - Auto-Cloud directory scanning

    /// Find Auto-Cloud save directories by scanning for known save file patterns in Wine prefix.
    public static func findAutoCloudDirs(bottle: Bottle, appID: Int) -> [URL] {
        let fm = FileManager.default
        let userDir = bottle.url
            .appending(path: "drive_c/users/crossover")

        let searchDirs = [
            userDir.appending(path: "AppData/Local"),
            userDir.appending(path: "AppData/LocalLow"),
            userDir.appending(path: "AppData/Roaming"),
            userDir.appending(path: "Saved Games"),
            userDir.appending(path: "Documents"),
        ]

        var results: [URL] = []
        for dir in searchDirs {
            guard fm.fileExists(atPath: dir.path(percentEncoded: false)),
                  let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            while let fileURL = enumerator.nextObject() as? URL {
                let name = fileURL.lastPathComponent.lowercased()
                if name.hasSuffix(".sav") || name.hasSuffix(".save") || name.hasSuffix(".savegame") {
                    let saveDir = fileURL.deletingLastPathComponent()
                    if !results.contains(saveDir) {
                        results.append(saveDir)
                    }
                }
            }
        }
        return results
    }

    // MARK: - Goldberg save directory

    /// Returns the Goldberg Emulator save directory for a game in Wine.
    public static func goldbergSaveDir(bottle: Bottle, appID: Int) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "users")
            .appending(path: "crossover")
            .appending(path: "AppData")
            .appending(path: "Roaming")
            .appending(path: "Goldberg SteamEmu Saves")
            .appending(path: "\(appID)")
            .appending(path: "remote")
    }
}
