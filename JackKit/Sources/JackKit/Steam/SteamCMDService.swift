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
    case steamGuardRequired

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Impossibile scaricare SteamCMD."
        case .extractionFailed:
            return "Impossibile estrarre SteamCMD."
        case .loginFailed(let msg):
            return "Login SteamCMD fallito: \(msg)"
        case .installFailed(let msg):
            return "Installazione gioco fallita: \(msg)"
        case .notInstalled:
            return "SteamCMD non è installato."
        case .steamGuardRequired:
            return "Steam Guard attivo: accedi con SteamCMD da Terminale una volta, poi Jack userà le credenziali salvate."
        }
    }
}

public final class SteamCMDService: @unchecked Sendable {
    public static let shared = SteamCMDService()

    private let cmdDir = BottleData.steamCMDDir
    private let cmdDownloadURL = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"

    private var steamcmdPath: URL {
        cmdDir.appending(path: "steamcmd.sh")
    }

    private init() {}

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

        // Extract with tar (no pipe so no deadlock risk)
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

    /// Test login with SteamCMD.
    /// After first successful login with password, SteamCMD caches credentials
    /// and subsequent logins only need the username.
    public func login(username: String, password: String? = nil) async throws {
        guard isInstalled else { throw SteamCMDError.notInstalled }

        // Build the steamcmd argument list (not a shell string — avoids quoting issues)
        var steamArgs: [String] = ["+login", username]
        if let pw = password, !pw.isEmpty {
            steamArgs.append(pw)
        }
        steamArgs.append("+quit")

        let (exitCode, output) = try await runSteamCMD(steamArgs: steamArgs)

        // Steam Guard / two-factor
        if output.contains("Two-factor") || output.contains("Steam Guard")
            || output.contains("two-factor") || output.contains("SteamGuard") {
            throw SteamCMDError.steamGuardRequired
        }

        // Explicit failures
        if output.contains("FAILED") || output.contains("Invalid Password")
            || output.contains("Invalid password") {
            throw SteamCMDError.loginFailed(extractLoginError(from: output))
        }

        // Successful login prints "Logged in OK" or "Login Successful"
        let success = output.contains("Logged in OK")
            || output.contains("Login Successful")
            || output.contains("Logging in user") && output.contains("...OK")

        if !success && exitCode != 0 {
            throw SteamCMDError.loginFailed("Exit code \(exitCode). Output:\n\(output.suffix(300))")
        }
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

        let steamArgs: [String] = [
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", installDir.path(percentEncoded: false),
            "+login", username,
            "+app_update", "\(appID)", "validate",
            "+quit"
        ]

        let (exitCode, fullOutput) = try await runSteamCMD(steamArgs: steamArgs, onOutput: onProgress)

        if exitCode != 0 && !fullOutput.contains("Success") {
            throw SteamCMDError.installFailed(extractLoginError(from: fullOutput))
        }
    }

    // MARK: - Paths

    /// Per-game install directory: SteamCMD/games/<appID>/
    /// Using appID avoids fragile name-matching.
    public static func gameInstallDir(appID: Int) -> URL {
        BottleData.steamCMDDir.appending(path: "games").appending(path: "\(appID)")
    }

    // MARK: - Game Executable Discovery

    /// Find the main game executable in the installed game directory.
    /// Excludes setup/uninstall/redistrib exes; returns the largest remaining .exe.
    public static func findGameExecutable(in gameDir: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: gameDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }

        let excludePatterns = ["unins", "setup", "install", "redist", "vcredist",
                               "dxsetup", "dotnet", "crash", "report", "ue4prereq",
                               "launch", "updater", "unarc"]

        var candidates: [(url: URL, size: Int)] = []

        for case let fileURL as URL in enumerator {
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

    /// Run steamcmd.sh with the given arguments.
    /// Reads output asynchronously to avoid pipe-buffer deadlock.
    private func runSteamCMD(
        steamArgs: [String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> (Int32, String) {
        let process = Process()
        // Use /bin/bash to execute the shell script properly
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // First arg is the script path; remaining args are steamcmd arguments
        process.arguments = [steamcmdPath.path(percentEncoded: false)] + steamArgs
        process.currentDirectoryURL = cmdDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read output in a detached task to drain the pipe and prevent deadlock.
        // The process.waitUntilExit() below blocks the calling thread, but since
        // we're in an async context via withCheckedThrowingContinuation, the output
        // task runs concurrently on another thread.
        let handle = pipe.fileHandleForReading
        var fullOutput = ""
        let outputLock = NSLock()

        // Use NotificationCenter to read data asynchronously
        let outputTask = Task.detached {
            var accumulated = ""
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let chunk = String(data: data, encoding: .utf8) {
                    accumulated += chunk
                    onOutput?(chunk)
                }
            }
            return accumulated
        }

        // Wait for process exit on a background thread to not block Swift concurrency
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        fullOutput = await outputTask.value
        _ = outputLock  // silence warning

        return (process.terminationStatus, fullOutput)
    }

    private func extractLoginError(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        if let errorLine = lines.first(where: {
            $0.contains("FAILED") || $0.contains("Invalid") || $0.contains("ERROR") || $0.contains("error")
        }) {
            return errorLine.trimmingCharacters(in: .whitespaces)
        }
        // Return last non-empty line as fallback
        if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return last.trimmingCharacters(in: .whitespaces)
        }
        return "Nessun output da SteamCMD"
    }
}
