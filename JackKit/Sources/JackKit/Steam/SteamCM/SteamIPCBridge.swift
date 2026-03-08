//
//  SteamIPCBridge.swift
//  JackKit
//
//  Bridge between the native Steam CM client and Wine.
//  Sets up the Wine registry and environment so games think Steam is running.
//
//  Architecture:
//    1. Write Wine registry entries (ActiveProcess, SteamPath, etc.)
//    2. Generate steam_api config files (steam_appid.txt, etc.)
//    3. Keep CM session alive while game runs
//    4. For DRM: use Goldberg with real Steam ID from native session
//       (Phase 2: direct IPC pipe emulation)
//

import Foundation
import os.log

public final class SteamIPCBridge: @unchecked Sendable {
    public static let shared = SteamIPCBridge()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamIPCBridge")

    private init() {}

    // MARK: - Setup for game launch

    /// Prepare Wine environment for a game launch with native Steam session.
    /// Sets registry, environment variables, and applies Goldberg with real credentials.
    public func prepareForLaunch(
        appID: Int,
        bottle: Bottle,
        gameDir: URL,
        exeDir: URL
    ) async throws {
        let session = SteamSessionManager.shared
        guard session.isLoggedIn else {
            throw BridgeError.notLoggedIn
        }

        let steamID = session.steamID64
        let accountName = session.accountName

        // 1. Write Wine registry entries so games see Steam as "running"
        try await setupWineRegistry(bottle: bottle, steamID: steamID)

        // 2. Write steam_appid.txt
        try? "\(appID)\n".write(
            to: gameDir.appending(path: "steam_appid.txt"),
            atomically: true, encoding: .utf8
        )
        try? "\(appID)\n".write(
            to: exeDir.appending(path: "steam_appid.txt"),
            atomically: true, encoding: .utf8
        )

        // 3. Apply Goldberg with real Steam credentials
        //    Goldberg replaces steam_api64.dll so the game doesn't need
        //    a real IPC connection — but uses our real Steam ID and app ownership.
        try await GoldbergService.shared.ensureInstalled()
        try GoldbergService.shared.apply(
            to: exeDir,
            gameDir: gameDir,
            appID: appID,
            username: accountName.isEmpty ? "Player" : accountName,
            steamID: steamID
        )

        Self.log.info("Bridge ready for app \(appID) (steamID=\(steamID))")
    }

    /// Build environment variables for the game process.
    public func launchEnvironment(appID: Int) -> [String: String] {
        let session = SteamSessionManager.shared
        var env: [String: String] = [
            "SteamAppId": "\(appID)",
            "SteamGameId": "\(appID)",
        ]

        // DXVK overrides + block real steam.exe (Goldberg handles everything)
        env["WINEDLLOVERRIDES"] = "dxgi,d3d9,d3d10core,d3d11=n,b;steam.exe=d;steamwebhelper.exe=d"

        if !session.steamID64.isEmpty {
            env["SteamUser"] = session.accountName
        }

        return env
    }

    // MARK: - Wine Registry Setup

    /// Write Steam registry entries so the game environment looks correct.
    /// Uses a single .reg file import instead of 7 sequential Wine reg add commands.
    private func setupWineRegistry(bottle: Bottle, steamID: String) async throws {
        let steamPath = "C:\\\\Program Files (x86)\\\\Steam"

        // Convert SteamID64 to Steam3 AccountID
        let steam3ID: UInt32
        if let id64 = UInt64(steamID) {
            steam3ID = UInt32(id64 & 0xFFFFFFFF)
        } else {
            steam3ID = 0
        }

        // Build a .reg file with all entries at once (single Wine process)
        let regContent = """
            Windows Registry Editor Version 5.00

            [HKEY_CURRENT_USER\\Software\\Valve\\Steam]
            "SteamPath"="\(steamPath)"
            "SteamExe"="\(steamPath)\\\\steam.exe"
            "Language"="english"

            [HKEY_CURRENT_USER\\Software\\Valve\\Steam\\ActiveProcess]
            "ActiveUser"=dword:\(String(format: "%08x", steam3ID))
            "pid"=dword:000003e8
            "Universe"=dword:00000001
            "SteamClientDll"="\(steamPath)\\\\steamclient.dll"
            "SteamClientDll64"="\(steamPath)\\\\steamclient64.dll"
            """

        // Write temp .reg file inside the bottle's drive_c
        let regFile = bottle.url.appending(path: "drive_c").appending(path: "steam_reg.reg")
        try regContent.write(to: regFile, atomically: true, encoding: .utf8)

        // Import with a single Wine process
        _ = try? await Wine.runWine([
            "reg", "import", "C:\\steam_reg.reg"
        ], bottle: bottle)

        try? FileManager.default.removeItem(at: regFile)
    }

    // MARK: - CM Session Management

    /// Ensure the CM client is connected and logged in.
    /// Uses tokens from SteamSessionManager.
    public func ensureCMSession() async throws {
        let cm = SteamCMClient.shared
        let session = SteamSessionManager.shared

        guard session.isLoggedIn else {
            throw BridgeError.notLoggedIn
        }

        if cm.isLoggedOn { return }

        // Get a fresh access token
        let accessToken = try await session.getAccessToken()

        // Connect and logon
        try await cm.connect()
        try await cm.logOn(accountName: session.accountName, accessToken: accessToken)

        Self.log.info("CM session established for \(session.accountName)")
    }

    // MARK: - Errors

    public enum BridgeError: LocalizedError {
        case notLoggedIn
        case goldbergFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "Not logged in. Sign in to Steam first."
            case .goldbergFailed(let msg): return "Failed to prepare game: \(msg)"
            }
        }
    }
}
