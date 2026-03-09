//
//  SteamIPCBridge.swift
//  JackKit
//
//  Bridge between SwiftUI and the JackSteamBridge (.NET/SteamKit2) background process.
//  Communicates via JSON-over-stdin/stdout.
//
//  Architecture:
//    Swift (UI) ──JSON──► JackSteamBridge (.NET) ──SteamKit2──► Steam Servers
//    Goldberg configured with credentials from the bridge session.
//    Wine runs the game with Goldberg DLLs.
//

import Foundation
import os.log

// MARK: - Public types (formerly in SteamNativeAuth.swift)

public enum SteamGuardType: Sendable {
    case none
    case deviceConfirmation
    case deviceCode
    case emailCode(domain: String)
    case emailConfirmation(domain: String)
}

public struct SteamLoginResult: Sendable {
    public let steamID64: String
    public let accessToken: String
    public let refreshToken: String
    public let accountName: String

    public init(steamID64: String, accessToken: String, refreshToken: String, accountName: String) {
        self.steamID64 = steamID64
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountName = accountName
    }
}

// MARK: - Bridge

public final class SteamIPCBridge: @unchecked Sendable {
    public static let shared = SteamIPCBridge()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamIPCBridge")

    // .NET process
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    // Request/response correlation
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private let requestLock = NSLock()

    // Event handlers
    private var eventHandlers: [String: @Sendable ([String: Any]) -> Void] = [:]

    // State
    public private(set) var isRunning = false
    private var guardCodeContinuation: CheckedContinuation<String, Never>?

    private init() {}

    // MARK: - Installation

    /// Directory where the bridge binary lives.
    private static var bridgeDir: URL {
        BottleData.steamCMDDir
            .deletingLastPathComponent()
            .appending(path: "JackSteamBridge")
    }

    /// Check if the bridge binary is installed.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.bridgeBinaryPath().path(percentEncoded: false))
    }

    /// Ensure the bridge binary is available, building from source if the project exists.
    public func ensureInstalled() async throws {
        if isInstalled { return }

        let fm = FileManager.default
        let destDir = Self.bridgeDir
        let dest = destDir.appending(path: "JackSteamBridge")

        // Try to build from source (dev environment)
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SteamCM/
            .deletingLastPathComponent()  // Steam/
            .deletingLastPathComponent()  // JackKit/Sources/JackKit/
            .deletingLastPathComponent()  // JackKit/Sources/
            .deletingLastPathComponent()  // JackKit/
            .deletingLastPathComponent()  // jack/
            .appending(path: "JackSteamBridge/JackSteamBridge")

        let csproj = projectDir.appending(path: "JackSteamBridge.csproj")
        if fm.fileExists(atPath: csproj.path(percentEncoded: false)) {
            Self.log.info("Building JackSteamBridge from source...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/share/dotnet/dotnet")
            process.arguments = [
                "publish", "-c", "Release", "-r", "osx-arm64",
                "--self-contained", "-o", destDir.path(percentEncoded: false)
            ]
            process.currentDirectoryURL = projectDir
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw BridgeError.buildFailed
            }

            // Make executable and ad-hoc sign
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path(percentEncoded: false))
            let signProc = Process()
            signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProc.arguments = ["-s", "-", "--force", dest.path(percentEncoded: false)]
            try signProc.run()
            signProc.waitUntilExit()
            Self.log.info("JackSteamBridge built successfully")
            return
        }

        throw BridgeError.bridgeNotFound
    }

    // MARK: - Process lifecycle

    /// Start the JackSteamBridge .NET process.
    public func start() throws {
        guard !isRunning else { return }

        let bridgePath = Self.bridgeBinaryPath()
        guard FileManager.default.fileExists(atPath: bridgePath.path(percentEncoded: false)) else {
            throw BridgeError.bridgeNotFound
        }

        let proc = Process()
        proc.executableURL = bridgePath

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        process = proc

        try proc.run()
        isRunning = true

        // Read stdout (JSON responses) in background — must start AFTER isRunning = true
        Task.detached { [weak self] in
            self?.readStdout()
        }

        // Log stderr in background
        Task.detached { [weak self] in
            self?.readStderr()
        }
        Self.log.info("JackSteamBridge process started (PID=\(proc.processIdentifier))")

        // Monitor process termination
        proc.terminationHandler = { [weak self] p in
            Self.log.warning("JackSteamBridge exited with code \(p.terminationStatus)")
            self?.isRunning = false
            self?.failAllPending(error: BridgeError.processExited)
        }
    }

    /// Stop the .NET process.
    public func stop() {
        guard isRunning, let proc = process else { return }
        _ = try? sendCommandSync("shutdown", params: nil)
        proc.terminate()
        process = nil
        isRunning = false
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Ensure the bridge process is running, starting it if needed.
    /// Auto-builds from source in dev environment if binary not found.
    public func ensureRunning() async throws {
        if isRunning { return }
        if !isInstalled { try await ensureInstalled() }
        try start()
    }

    // MARK: - Login

    /// Login with credentials. Returns guard type if 2FA is needed.
    /// SteamKit2 handles the entire flow including RSA encryption.
    public func login(accountName: String, password: String, guardData: String? = nil) async throws -> SteamLoginResult {
        try await ensureRunning()

        var params: [String: Any] = [
            "accountName": accountName,
            "password": password,
        ]
        if let gd = guardData { params["guardData"] = gd }

        let resp = try await sendCommand("login", params: params)

        guard resp["success"] as? Bool == true else {
            throw BridgeError.loginFailed(resp["error"] as? String ?? "Unknown error")
        }

        return SteamLoginResult(
            steamID64: resp["steamID64"] as? String ?? "",
            accessToken: resp["accessToken"] as? String ?? "",
            refreshToken: resp["refreshToken"] as? String ?? "",
            accountName: resp["accountName"] as? String ?? accountName
        )
    }

    /// Start QR code login. Returns the challenge URL.
    /// Login result arrives as an event.
    public func loginQR() async throws -> String {
        try await ensureRunning()
        let resp = try await sendCommand("loginQR", params: nil)
        return resp["challengeURL"] as? String ?? ""
    }

    /// Login with a saved refresh token.
    public func loginWithToken(accountName: String, refreshToken: String) async throws -> SteamLoginResult {
        try await ensureRunning()
        let resp = try await sendCommand("loginWithToken", params: [
            "accountName": accountName,
            "refreshToken": refreshToken,
        ])

        guard resp["success"] as? Bool == true else {
            throw BridgeError.loginFailed("Token login failed")
        }

        return SteamLoginResult(
            steamID64: resp["steamID64"] as? String ?? "",
            accessToken: "",
            refreshToken: refreshToken,
            accountName: resp["accountName"] as? String ?? accountName
        )
    }

    /// Submit a Steam Guard code (TOTP or email).
    public func submitGuardCode(_ code: String) async throws {
        try await ensureRunning()
        _ = try await sendCommand("submitGuardCode", params: ["code": code])
    }

    /// Register a handler for Steam Guard prompts from the .NET process.
    public func onSteamGuardRequired(_ handler: @escaping @Sendable (SteamGuardType) -> Void) {
        eventHandlers["steamGuardRequired"] = { data in
            let type = data["type"] as? String ?? ""
            switch type {
            case "deviceCode":
                handler(.deviceCode)
            case "emailCode":
                let email = data["email"] as? String ?? ""
                handler(.emailCode(domain: email))
            case "deviceConfirmation":
                handler(.deviceConfirmation)
            default:
                handler(.none)
            }
        }
    }

    /// Register a handler for login results (from QR or async auth).
    public func onLoginResult(_ handler: @escaping @Sendable (SteamLoginResult?) -> Void) {
        eventHandlers["loginResult"] = { data in
            guard data["success"] as? Bool == true else {
                handler(nil)
                return
            }
            handler(SteamLoginResult(
                steamID64: data["steamID64"] as? String ?? "",
                accessToken: data["accessToken"] as? String ?? "",
                refreshToken: data["refreshToken"] as? String ?? "",
                accountName: data["accountName"] as? String ?? ""
            ))
        }
    }

    // MARK: - Session info

    public func getSessionInfo() async throws -> (isLoggedOn: Bool, steamID64: String, accountName: String) {
        try await ensureRunning()
        let resp = try await sendCommand("getSessionInfo", params: nil)
        return (
            isLoggedOn: resp["isLoggedOn"] as? Bool ?? false,
            steamID64: resp["steamID64"] as? String ?? "",
            accountName: resp["accountName"] as? String ?? ""
        )
    }

    // MARK: - Token refresh via CM

    /// Get a fresh access token via the SteamKit2 CM session.
    /// This works for SteamClient platform tokens (unlike the Web API).
    public func getAccessToken() async throws -> String {
        try await ensureRunning()
        let resp = try await sendCommand("getAccessToken", params: nil)
        guard resp["success"] as? Bool == true,
              let token = resp["accessToken"] as? String, !token.isEmpty else {
            throw BridgeError.commandFailed(resp["error"] as? String ?? "Failed to get access token")
        }
        return token
    }

    // MARK: - Cloud

    public struct CloudFileInfo: Sendable {
        public let filename: String
        public let size: Int
        public let sha: String
        public let timestamp: Int
        public let url: String
        public let root: String  // Auto-Cloud root: WinAppDataLocal, WinAppDataRoaming, etc.
    }

    public func cloudEnumerate(appID: Int) async throws -> [CloudFileInfo] {
        try await ensureRunning()
        let session = SteamSessionManager.shared

        // Web-based approach: needs accessToken + steamID64
        var params: [String: Any] = ["appID": appID]
        if !session.steamID64.isEmpty { params["steamID64"] = session.steamID64 }

        // Get access token (try stored, then refresh)
        var token = session.accessToken
        if token.isEmpty {
            // Try refreshing via session manager or bridge
            do {
                token = try await session.getAccessToken(forceRefresh: true)
            } catch {
                Self.log.warning("Could not get access token: \(error.localizedDescription)")
            }
        }
        if !token.isEmpty { params["accessToken"] = token }

        // Also pass CM credentials as fallback
        if !session.accountName.isEmpty { params["accountName"] = session.accountName }
        if !session.refreshToken.isEmpty { params["refreshToken"] = session.refreshToken }

        let resp = try await sendCommand("cloudEnumerate", params: params)

        // Check for error
        if let error = resp["error"] as? String {
            throw BridgeError.commandFailed(error)
        }

        guard let files = resp["files"] as? [[String: Any]] else { return [] }
        return files.map { f in
            CloudFileInfo(
                filename: f["filename"] as? String ?? "",
                size: 0, // Size comes as string from web ("9.94 KB")
                sha: "",
                timestamp: 0,
                url: f["url"] as? String ?? "",
                root: f["root"] as? String ?? ""
            )
        }
    }

    /// Upload a single file to Steam Cloud via the CM bridge (CloudKit approach).
    /// Returns true if the file was committed to Steam Cloud.
    public func cloudUpload(appID: Int, filename: String, fileData: Data) async throws -> Bool {
        try await ensureRunning()
        let session = SteamSessionManager.shared

        let base64 = fileData.base64EncodedString()
        var params: [String: Any] = [
            "appID": appID,
            "filename": filename,
            "fileData": base64,
        ]

        // Pass CM credentials for EnsureLoggedIn
        if !session.accountName.isEmpty { params["accountName"] = session.accountName }
        if !session.refreshToken.isEmpty { params["refreshToken"] = session.refreshToken }

        let resp = try await sendCommand("cloudUpload", params: params)

        if let error = resp["error"] as? String {
            throw BridgeError.commandFailed(error)
        }

        return resp["success"] as? Bool ?? false
    }

    // MARK: - Setup for game launch

    /// Prepare Wine environment for a game launch with native Steam session.
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

        // 1. Ensure bridge is connected and session alive
        try await ensureRunning()

        // 2. Write Wine registry entries so games see Steam as "running"
        try await setupWineRegistry(bottle: bottle, steamID: steamID)

        // 3. Write steam_appid.txt
        try? "\(appID)\n".write(
            to: gameDir.appending(path: "steam_appid.txt"),
            atomically: true, encoding: .utf8
        )
        try? "\(appID)\n".write(
            to: exeDir.appending(path: "steam_appid.txt"),
            atomically: true, encoding: .utf8
        )

        // 4. Apply Goldberg with real Steam credentials
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

        env["WINEDLLOVERRIDES"] = "dxgi,d3d9,d3d10core,d3d11=n,b;steam.exe=d;steamwebhelper.exe=d"

        if !session.steamID64.isEmpty {
            env["SteamUser"] = session.accountName
        }

        return env
    }

    // MARK: - CM Session Management

    /// Ensure the SteamKit2 CM session is established.
    public func ensureCMSession() async throws {
        let session = SteamSessionManager.shared
        guard session.isLoggedIn else {
            throw BridgeError.notLoggedIn
        }

        try await ensureRunning()

        // Check if already logged on
        let info = try await getSessionInfo()
        if info.isLoggedOn { return }

        // Try token login first
        do {
            _ = try await loginWithToken(
                accountName: session.accountName,
                refreshToken: session.refreshToken
            )
            Self.log.info("CM session established via token for \(session.accountName)")
            return
        } catch {
            Self.log.warning("Token login failed: \(error.localizedDescription), session may need re-auth in Settings")
            throw BridgeError.loginFailed("Steam session needs re-authentication. Go to Settings > Refresh session.")
        }
    }

    // MARK: - Wine Registry Setup

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

    // MARK: - JSON-RPC IPC

    private func sendCommand(_ command: String, params: [String: Any]?) async throws -> [String: Any] {
        let id = UUID().uuidString

        return try await withCheckedThrowingContinuation { continuation in
            requestLock.lock()
            pendingRequests[id] = continuation
            requestLock.unlock()

            var message: [String: Any] = [
                "id": id,
                "command": command,
            ]
            if let p = params { message["params"] = p }

            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  var line = String(data: data, encoding: .utf8) else {
                requestLock.lock()
                pendingRequests.removeValue(forKey: id)
                requestLock.unlock()
                continuation.resume(throwing: BridgeError.serializationFailed)
                return
            }

            line += "\n"
            stdinPipe?.fileHandleForWriting.write(line.data(using: .utf8)!)
        }
    }

    private func sendCommandSync(_ command: String, params: [String: Any]?) throws -> [String: Any] {
        var message: [String: Any] = ["id": UUID().uuidString, "command": command]
        if let p = params { message["params"] = p }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var line = String(data: data, encoding: .utf8) else {
            throw BridgeError.serializationFailed
        }
        line += "\n"
        stdinPipe?.fileHandleForWriting.write(line.data(using: .utf8)!)
        return [:]
    }

    private func readStdout() {
        guard let handle = stdoutPipe?.fileHandleForReading else { return }

        var lineBuffer = Data()

        while isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF

            lineBuffer.append(chunk)

            // Process complete lines
            while let newlineRange = lineBuffer.range(of: Data([0x0A])) {
                let lineData = lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound]
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                // Check if event or response
                if let eventName = json["event"] as? String {
                    let eventData = json["data"] as? [String: Any] ?? [:]
                    if let handler = eventHandlers[eventName] {
                        handler(eventData)
                    }
                } else if let id = json["id"] as? String {
                    let data = json["data"] as? [String: Any] ?? [:]
                    requestLock.lock()
                    let continuation = pendingRequests.removeValue(forKey: id)
                    requestLock.unlock()

                    if json["success"] as? Bool == true {
                        // Safe: data is created locally from JSON parsing, not shared
                        nonisolated(unsafe) let sendableData = data
                        continuation?.resume(returning: sendableData)
                    } else {
                        let error = json["error"] as? String ?? "Unknown error"
                        continuation?.resume(throwing: BridgeError.commandFailed(error))
                    }
                }
            }
        }
    }

    private func readStderr() {
        guard let handle = stderrPipe?.fileHandleForReading else { return }
        while isRunning {
            let data = handle.availableData
            if data.isEmpty { break }
            if let line = String(data: data, encoding: .utf8) {
                Self.log.debug("\(line, privacy: .public)")
            }
        }
    }

    private func failAllPending(error: Error) {
        requestLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        requestLock.unlock()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Bridge binary path

    private static func bridgeBinaryPath() -> URL {
        // 1. Check inside app bundle
        if let bundled = Bundle.main.url(forResource: "JackSteamBridge", withExtension: nil) {
            return bundled
        }
        // 2. Check in Jack data directory
        return BottleData.steamCMDDir
            .deletingLastPathComponent()
            .appending(path: "JackSteamBridge")
            .appending(path: "JackSteamBridge")
    }

    // MARK: - Errors

    public enum BridgeError: LocalizedError {
        case notLoggedIn
        case goldbergFailed(String)
        case bridgeNotFound
        case buildFailed
        case processExited
        case serializationFailed
        case commandFailed(String)
        case loginFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "Not logged in. Sign in to Steam first."
            case .goldbergFailed(let msg): return "Failed to prepare game: \(msg)"
            case .bridgeNotFound: return "JackSteamBridge not found. Reinstall the app."
            case .buildFailed: return "Failed to build JackSteamBridge from source."
            case .processExited: return "Steam bridge process exited unexpectedly."
            case .serializationFailed: return "Failed to serialize bridge command."
            case .commandFailed(let msg): return "Bridge command failed: \(msg)"
            case .loginFailed(let msg): return "Login failed: \(msg)"
            }
        }
    }
}
