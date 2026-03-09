//
//  SteamCMDService.swift
//  JackKit
//
//  This file is part of Jack.
//
//  Jack is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Jack is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Jack.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

public enum SteamCMDError: LocalizedError {
    case downloadFailed
    case extractionFailed
    case loginFailed(String)
    case installFailed(String)
    case notInstalled
    case steamGuardRequired(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download SteamCMD."
        case .extractionFailed:
            return "Failed to extract SteamCMD."
        case .loginFailed(let msg):
            return "SteamCMD login failed: \(msg)"
        case .installFailed(let msg):
            return "Game installation failed: \(msg)"
        case .notInstalled:
            return "SteamCMD is not installed."
        case .steamGuardRequired(let msg):
            return msg
        }
    }
}

/// Result of a successful SteamCMD login.
public struct SteamCMDLoginResult: Sendable {
    /// SteamID64 extracted from login output (e.g. "76561199203490348")
    public let steamID64: String
}

public final class SteamCMDService: @unchecked Sendable {
    public static let shared = SteamCMDService()

    private let cmdDir = BottleData.steamCMDDir
    private let cmdDownloadURL = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"

    private var steamcmdPath: URL {
        cmdDir.appending(path: "steamcmd.sh")
    }

    private var currentProcess: Process?

    private init() {}

    /// Kill any running SteamCMD install/update process.
    public func cancelCurrentInstall() {
        currentProcess?.interrupt()
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: - Installation

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: steamcmdPath.path(percentEncoded: false))
    }

    /// Download and extract SteamCMD for macOS (native, no Wine)
    public func ensureInstalled() async throws {
        if isInstalled { return }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: cmdDir.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: cmdDir, withIntermediateDirectories: true)
        }

        guard let url = URL(string: cmdDownloadURL) else {
            throw SteamCMDError.downloadFailed
        }

        let (tempFileURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SteamCMDError.downloadFailed
        }

        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-xzf", tempFileURL.path(percentEncoded: false),
                                "-C", cmdDir.path(percentEncoded: false)]
        tarProcess.qualityOfService = .userInitiated
        try tarProcess.run()
        tarProcess.waitUntilExit()

        try? fileManager.removeItem(at: tempFileURL)

        guard tarProcess.terminationStatus == 0 else {
            throw SteamCMDError.extractionFailed
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: steamcmdPath.path(percentEncoded: false)
        )
    }

    // MARK: - Login

    /// Login to SteamCMD. Returns SteamID64 extracted from output.
    /// After first successful login with password, SteamCMD caches credentials.
    @discardableResult
    public func login(
        username: String,
        password: String? = nil,
        steamGuardCode: String? = nil
    ) async throws -> SteamCMDLoginResult {
        guard isInstalled else { throw SteamCMDError.notInstalled }

        var steamArgs: [String] = ["+login", username]
        if let pw = password, !pw.isEmpty {
            steamArgs.append(pw)
            if let code = steamGuardCode, !code.isEmpty {
                steamArgs.append(code)
            }
        }
        steamArgs.append("+quit")

        let (exitCode, output) = try await runSteamCMD(steamArgs: steamArgs)

        // Cached credentials missing — only happens when no password supplied
        if output.contains("Cached credentials not found") {
            throw SteamCMDError.loginFailed("No saved credentials. Please enter your password.")
        }

        // Rate limit
        if output.contains("Rate Limit") {
            throw SteamCMDError.loginFailed(
                "Too many login attempts. Please wait a few minutes and try again."
            )
        }

        // Steam Guard / two-factor
        let guardWasProvided = steamGuardCode != nil && !(steamGuardCode?.isEmpty ?? true)
        if output.contains("Two-factor code mismatch") || output.contains("code mismatch") {
            throw SteamCMDError.loginFailed("Codice Steam Guard errato. Riprova con un nuovo codice.")
        }
        if !guardWasProvided,
           output.contains("Two-factor") || output.contains("Steam Guard")
            || output.contains("two-factor") || output.contains("SteamGuard") {
            throw SteamCMDError.steamGuardRequired(
                "Enter your Steam Guard code (5 characters from the Steam Mobile app)."
            )
        }

        // Explicit failures
        if output.contains("FAILED") || output.contains("Invalid Password")
            || output.contains("Invalid password") || output.contains("ERROR") {
            throw SteamCMDError.loginFailed(extractLoginError(from: output))
        }

        // Extract SteamID64 from output: "Logging in user 'xxx' [U:1:XXXXXXXXX]"
        let steamID64 = Self.extractSteamID64(from: output)

        let success = output.contains("Logged in OK")
            || output.contains("Login Successful")
            || (output.contains("Logging in user") && output.contains("...OK"))

        if !success && exitCode != 0 {
            throw SteamCMDError.loginFailed("Exit code \(exitCode). Output:\n\(String(output.suffix(300)))")
        }

        guard let id = steamID64 else {
            // Login succeeded but couldn't extract ID — still OK for downloads
            return SteamCMDLoginResult(steamID64: "")
        }
        return SteamCMDLoginResult(steamID64: id)
    }

    // MARK: - Owned Games (via licenses_print)

    /// Get all owned app IDs by parsing SteamCMD `licenses_print` output.
    public func getOwnedAppIDs(username: String) async throws -> [Int] {
        guard isInstalled else { throw SteamCMDError.notInstalled }

        let steamArgs = ["+login", username, "+licenses_print", "+quit"]
        let (_, output) = try await runSteamCMD(steamArgs: steamArgs)

        if output.contains("Cached credentials not found") {
            throw SteamCMDError.loginFailed("No saved credentials. Please log in first.")
        }

        return Self.parseAppIDs(from: output)
    }

    /// Parse app IDs from `licenses_print` output.
    /// Each license block has: " - Apps    : 374320, 411420,  "
    static func parseAppIDs(from output: String) -> [Int] {
        var appIDs = Set<Int>()
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- Apps") || trimmed.hasPrefix("Apps") else { continue }
            // Extract everything after the colon
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let idsString = trimmed[trimmed.index(after: colonIndex)...]
            let parts = idsString.components(separatedBy: ",")
            for part in parts {
                let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = Int(cleaned), id > 0 {
                    appIDs.insert(id)
                }
            }
        }
        return Array(appIDs).sorted()
    }

    /// Extract SteamID64 from SteamCMD login output.
    /// Looks for pattern: [U:1:XXXXXXXXX] and converts to SteamID64.
    static func extractSteamID64(from output: String) -> String? {
        // Pattern: [U:1:ACCOUNT_ID]
        guard let regex = try? NSRegularExpression(
            pattern: #"\[U:1:(\d+)\]"#
        ) else { return nil }

        let ns = output as NSString
        guard let match = regex.firstMatch(
            in: output,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges > 1 else { return nil }

        let accountIDRange = match.range(at: 1)
        guard accountIDRange.location != NSNotFound,
              let accountID = UInt64(ns.substring(with: accountIDRange)) else { return nil }

        // SteamID64 = 76561197960265728 + accountID
        let steamID64 = 76561197960265728 + accountID
        return "\(steamID64)"
    }

    // MARK: - Game Installation

    /// Install a Windows game via SteamCMD with `@sSteamCmdForcePlatformType windows`
    public func installGame(
        appID: Int,
        username: String,
        installDir: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        guard isInstalled else { throw SteamCMDError.notInstalled }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: installDir.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
        }

        var steamArgs: [String] = [
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", installDir.path(percentEncoded: false),
            "+login", username,
        ]

        // If we have a stored password, pass it so SteamCMD doesn't need cached credentials
        if let pw = SteamSessionManager.shared.storedPassword, !pw.isEmpty {
            steamArgs.append(pw)
        }

        steamArgs += ["+app_update", "\(appID)", "validate", "+quit"]

        // 4-hour timeout for large game downloads (e.g. 100+ GB)
        let (exitCode, fullOutput) = try await runSteamCMD(
            steamArgs: steamArgs, onOutput: onProgress, timeout: 14400
        )

        if fullOutput.contains("Cached credentials not found") || fullOutput.contains("password:") {
            throw SteamCMDError.loginFailed(
                "No saved credentials. Go to Settings and log in with SteamCMD."
            )
        }

        // SteamCMD exits 0 on success but may also print "Success" with non-zero exit
        // Also handle "fully installed" for already-complete games
        if exitCode != 0
            && !fullOutput.contains("Success")
            && !fullOutput.contains("fully installed") {
            throw SteamCMDError.installFailed(extractLoginError(from: fullOutput))
        }
    }

    // MARK: - Paths

    /// Per-game install directory: SteamCMD/games/<appID>/
    public static func gameInstallDir(appID: Int) -> URL {
        BottleData.steamCMDDir.appending(path: "games").appending(path: "\(appID)")
    }

    // MARK: - Game Executable Discovery

    /// Find the main game executable in the installed game directory.
    public static func findGameExecutable(in gameDir: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: gameDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }

        let excludePatterns = ["unins", "setup", "install", "redist", "vcredist",
                               "dxsetup", "dotnet", "crashreport", "crashhandler",
                               "crashsender", "report", "ue4prereq",
                               "launch", "updater", "unarc"]

        var candidates: [(url: URL, size: Int)] = []

        for case let fileURL as URL in enumerator {
            // Skip files inside steamapps/downloading/ — those are incomplete downloads
            let filePath = fileURL.path(percentEncoded: false)
            if filePath.contains("/steamapps/downloading/") { continue }
            guard fileURL.pathExtension.lowercased() == "exe" else { continue }
            let name = fileURL.lastPathComponent.lowercased()
            if excludePatterns.contains(where: { name.contains($0) }) { continue }
            let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attrs?.isRegularFile == true else { continue }
            candidates.append((url: fileURL, size: attrs?.fileSize ?? 0))
        }

        return candidates.max(by: { $0.size < $1.size })?.url
    }

    // MARK: - Private

    /// Patterns that indicate SteamCMD is waiting for interactive input.
    /// When detected, the process is killed immediately.
    /// IMPORTANT: these must NOT match error messages like "Two-factor code mismatch".
    /// Only match prompts that indicate SteamCMD is blocked waiting for stdin.
    private static let interactivePrompts = [
        "Steam Guard code:",     // prompt for guard code
        "Two-factor code:",      // prompt for 2FA code
        "two-factor code:",
        "Enter the current code", // another prompt variant
        "password:",             // password prompt (only appears when no password on CLI)
    ]

    private func runSteamCMD(
        steamArgs: [String],
        onOutput: (@Sendable (String) -> Void)? = nil,
        timeout: TimeInterval = 300
    ) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [steamcmdPath.path(percentEncoded: false)] + steamArgs
        process.currentDirectoryURL = cmdDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Redirect stdin from /dev/null so SteamCMD gets EOF on any read
        process.standardInput = FileHandle.nullDevice

        try process.run()
        currentProcess = process

        let handle = pipe.fileHandleForReading
        let pid = process.processIdentifier

        // Read output in real-time, kill process if it asks for interactive input
        let prompts = Self.interactivePrompts
        let outputTask = Task.detached {
            var accumulated = ""
            var alreadyKilled = false
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let chunk = String(data: data, encoding: .utf8) {
                    accumulated += chunk
                    onOutput?(chunk)

                    // Only check the new chunk for interactive prompts (not the
                    // entire accumulated output) to avoid false positives after
                    // a prompt string appeared earlier in a non-blocking context.
                    if !alreadyKilled, prompts.contains(where: { chunk.contains($0) }) {
                        alreadyKilled = true
                        kill(-pid, SIGKILL)
                        kill(pid, SIGKILL)
                    }
                }
            }
            return accumulated
        }

        // Wait for exit — timeout is configurable (short for login, long for downloads)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }

        let fullOutput = await outputTask.value
        currentProcess = nil

        return (process.terminationStatus, fullOutput)
    }

    private func extractLoginError(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        if let errorLine = lines.first(where: {
            $0.contains("FAILED") || $0.contains("Invalid") || $0.contains("ERROR") || $0.contains("error")
        }) {
            return errorLine.trimmingCharacters(in: .whitespaces)
        }
        if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return last.trimmingCharacters(in: .whitespaces)
        }
        return "No output from SteamCMD"
    }
}
