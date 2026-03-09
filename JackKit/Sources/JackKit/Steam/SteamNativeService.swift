//
//  SteamNativeService.swift
//  JackKit
//
//  Interfaces with Steam via the jacksteam.py Python CLI.
//  No Steam.app dependency — connects directly to Steam network.
//

import Foundation
import os.log

public final class SteamNativeService: @unchecked Sendable {
    public static let shared = SteamNativeService()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamNative")

    /// Path to the jacksteam.py script.
    private var scriptPath: String {
        let bundled = Bundle.main.path(forResource: "jacksteam", ofType: "py")
        if let bundled, FileManager.default.fileExists(atPath: bundled) { return bundled }

        let external = "/Volumes/Volume/Jack/JackCloudSync/jacksteam.py"
        if FileManager.default.fileExists(atPath: external) { return external }

        return "/Users/valeriodomenici/Code/jack/JackCloudSync/jacksteam.py"
    }

    /// Path to python3 interpreter.
    /// Prefers /usr/local/bin/python3 (3.10) where the `steam` library is installed.
    private var pythonPath: String {
        for path in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/usr/bin/python3"
    }

    private init() {}

    // MARK: - Steam Status

    /// Always returns true — no Steam.app needed.
    public func isSteamRunning() async -> Bool {
        return SteamSessionManager.shared.isLoggedIn
    }

    /// Get the currently logged-in Steam user from session.
    public func getCurrentUser() async throws -> (steamID64: String, accountName: String) {
        let session = SteamSessionManager.shared
        guard session.isLoggedIn else {
            throw SteamNativeError.notLoggedIn
        }
        return (session.steamID64, session.accountName)
    }

    // MARK: - Authentication

    /// Login with username/password/2FA via Python CLI.
    /// Returns the full login result including refresh token.
    public func login(username: String, password: String, twoFactorCode: String? = nil) async throws -> SteamLoginResult {
        var args = ["login", username, password]
        if let code = twoFactorCode, !code.isEmpty {
            args.append(code)
        }

        let result = try await runScript(args)

        guard result["success"] as? Bool == true else {
            let error = result["error"] as? String ?? "Login failed"
            throw SteamNativeError.loginFailed(error)
        }

        return SteamLoginResult(
            steamID64: result["steamID64"] as? String ?? "",
            accessToken: result["accessToken"] as? String ?? "",
            refreshToken: result["refreshToken"] as? String ?? "",
            accountName: result["accountName"] as? String ?? username
        )
    }

    // MARK: - Cloud Sync

    /// List cloud files for a game.
    public func cloudList(appID: Int) async throws -> [(filename: String, size: Int)] {
        let token = try await getRefreshToken()
        let result = try await runScript(["list", "\(appID)", token])

        guard let files = result["files"] as? [[String: Any]] else { return [] }
        return files.map { f in
            (
                filename: f["filename"] as? String ?? "",
                size: f["size"] as? Int ?? 0
            )
        }
    }

    /// Upload a single file to Steam Cloud (overwrite).
    public func cloudUpload(appID: Int, localPath: String, cloudFilename: String) async throws -> Bool {
        let token = try await getRefreshToken()
        let result = try await runScript(["upload", "\(appID)", localPath, cloudFilename, token])
        return (result["success"] as? Bool) == true
    }

    /// Download a single file from Steam Cloud.
    public func cloudDownload(appID: Int, cloudFilename: String, localPath: String) async throws -> Bool {
        let token = try await getRefreshToken()
        let result = try await runScript(["download", "\(appID)", localPath, token])
        return (result["downloaded"] as? Int ?? 0) > 0
    }

    /// Sync cloud → Wine prefix (before launch).
    public func cloudSyncDown(appID: Int, bottlePath: String) async throws -> Int {
        let token = try await getRefreshToken()
        let result = try await runScript(["sync-down", "\(appID)", bottlePath, token])
        return result["downloaded"] as? Int ?? 0
    }

    /// Sync Wine prefix → cloud (after exit).
    public func cloudSyncUp(appID: Int, bottlePath: String) async throws -> Int {
        let token = try await getRefreshToken()
        let result = try await runScript(["sync-up", "\(appID)", bottlePath, token])
        return result["uploaded"] as? Int ?? 0
    }

    // MARK: - Owned Games

    /// Fetch all owned app IDs from Steam licenses via CM network.
    public func getOwnedAppIDs() async throws -> [Int] {
        let token = try await getRefreshToken()
        let result = try await runScript(["licenses", token])
        guard let appids = result["appids"] as? [Any] else { return [] }
        return appids.compactMap { ($0 as? Int) ?? Int("\($0)") }
    }

    // MARK: - Game Download

    /// Download a game via Steam CDN (no SteamCMD needed).
    /// Streams progress lines as JSON to onProgress callback.
    public func downloadGame(
        appID: Int,
        installDir: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Bool {
        let token = try await getRefreshToken()
        let script = scriptPath
        let python = pythonPath
        guard FileManager.default.fileExists(atPath: script) else {
            throw SteamNativeError.toolNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script, "download-game", "\(appID)", installDir, token]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Stream stdout for progress
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let line = String(data: data, encoding: .utf8) else { return }
                for l in line.components(separatedBy: .newlines) where !l.isEmpty {
                    onProgress?(l)
                }
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil

                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                    Self.log.debug("download-game stderr: \(errStr)")
                }

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(throwing: SteamNativeError.toolFailed(proc.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Game Launch Preparation

    /// Prepare Wine environment for a game launch.
    public func prepareForLaunch(
        appID: Int,
        bottle: Bottle,
        gameDir: URL,
        exeDir: URL,
        exeURL: URL
    ) async throws {
        let session = SteamSessionManager.shared
        guard session.isLoggedIn else {
            throw SteamNativeError.notLoggedIn
        }

        let steamID = session.steamID64
        let accountName = session.accountName

        // 1. Write steam_appid.txt
        try? "\(appID)\n".write(
            to: gameDir.appending(path: "steam_appid.txt"),
            atomically: true, encoding: .utf8
        )
        try? "\(appID)\n".write(
            to: exeDir.appending(path: "steam_appid.txt"),
            atomically: true, encoding: .utf8
        )

        // 2. Apply Goldberg Steam emulator
        try await GoldbergService.shared.ensureInstalled()
        try GoldbergService.shared.apply(
            to: exeDir,
            gameDir: gameDir,
            appID: appID,
            username: accountName.isEmpty ? "Player" : accountName,
            steamID: steamID
        )

        // 3. Strip SteamStub DRM
        try await SteamlessService.shared.stripIfNeeded(exe: exeURL)

        Self.log.info("Prepared launch for app \(appID) (steamID=\(steamID))")
    }

    /// Build environment variables for the game process.
    public func launchEnvironment(appID: Int) -> [String: String] {
        [
            "SteamAppId": "\(appID)",
            "SteamGameId": "\(appID)",
            "WINEDLLOVERRIDES": "steam.exe=d;steamwebhelper.exe=d",
        ]
    }

    // MARK: - Wine Registry

    private func setupWineRegistry(bottle: Bottle, steamID: String) async throws {
        let steamPath = "C:\\\\Program Files (x86)\\\\Steam"

        let steam3ID: UInt32
        if let id64 = UInt64(steamID) {
            steam3ID = UInt32(id64 & 0xFFFFFFFF)
        } else {
            steam3ID = 0
        }

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

        let regFile = bottle.url.appending(path: "drive_c").appending(path: "steam_reg.reg")
        try regContent.write(to: regFile, atomically: true, encoding: .utf8)

        _ = try? await Wine.runWine([
            "reg", "import", "C:\\steam_reg.reg"
        ], bottle: bottle)

        try? FileManager.default.removeItem(at: regFile)
    }

    // MARK: - Helpers

    private func getRefreshToken() async throws -> String {
        let session = SteamSessionManager.shared
        guard !session.refreshToken.isEmpty else {
            throw SteamNativeError.notLoggedIn
        }
        return session.refreshToken
    }

    // MARK: - Script Runner

    private func runScript(_ arguments: [String]) async throws -> [String: Any] {
        let python = pythonPath
        let script = scriptPath
        guard FileManager.default.fileExists(atPath: script) else {
            throw SteamNativeError.toolNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script] + arguments
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                    Self.log.debug("jacksteam stderr: \(errStr)")
                }

                guard let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !outStr.isEmpty,
                      let jsonData = outStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    if proc.terminationStatus != 0 {
                        continuation.resume(throwing: SteamNativeError.toolFailed(proc.terminationStatus))
                    } else {
                        continuation.resume(returning: [:])
                    }
                    return
                }

                continuation.resume(returning: json)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Steam Local Files

    /// Read account name from Steam's loginusers.vdf for a given SteamID.
    public static func readAccountName(steamID64: String) -> String? {
        let vdfPath = NSHomeDirectory() + "/Library/Application Support/Steam/config/loginusers.vdf"
        guard let content = try? String(contentsOfFile: vdfPath, encoding: .utf8) else { return nil }

        guard let idRange = content.range(of: "\"\(steamID64)\"") else { return nil }
        let afterID = content[idRange.upperBound...]

        if let nameRange = afterID.range(of: "\"AccountName\""),
           let start = afterID[nameRange.upperBound...].range(of: "\""),
           let end = afterID[start.upperBound...].range(of: "\"") {
            return String(afterID[start.upperBound..<end.lowerBound])
        }

        if let nameRange = afterID.range(of: "\"PersonaName\""),
           let start = afterID[nameRange.upperBound...].range(of: "\""),
           let end = afterID[start.upperBound...].range(of: "\"") {
            return String(afterID[start.upperBound..<end.lowerBound])
        }

        return nil
    }

    /// Read Steam ID from loginusers.vdf (most recent user).
    public static func readSteamIDFromVDF() -> String? {
        let vdfPath = NSHomeDirectory() + "/Library/Application Support/Steam/config/loginusers.vdf"
        guard let content = try? String(contentsOfFile: vdfPath, encoding: .utf8) else { return nil }

        var currentID: String?
        var mostRecentID: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("\"7656") && trimmed.hasSuffix("\"") {
                currentID = trimmed.replacingOccurrences(of: "\"", with: "")
            }

            if trimmed.contains("\"MostRecent\"") && trimmed.contains("\"1\"") {
                mostRecentID = currentID
            }
        }

        return mostRecentID ?? currentID
    }

    // MARK: - Errors

    public enum SteamNativeError: LocalizedError {
        case steamNotRunning(String)
        case notLoggedIn
        case loginFailed(String)
        case toolNotFound
        case toolFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .steamNotRunning(let msg): return "Steam is not running: \(msg)"
            case .notLoggedIn: return "Not logged in to Steam. Sign in first."
            case .loginFailed(let msg): return "Steam login failed: \(msg)"
            case .toolNotFound: return "jacksteam.py not found"
            case .toolFailed(let code): return "jacksteam.py failed (exit \(code))"
            }
        }
    }
}
