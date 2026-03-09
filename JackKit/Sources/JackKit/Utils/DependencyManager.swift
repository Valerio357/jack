//
//  DependencyManager.swift
//  JackKit
//
//  This file is part of Jack.
//
//  Jack is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//

import Foundation
import os.log

/// Checks and installs all runtime dependencies needed by Jack.
public final class DependencyManager: @unchecked Sendable {
    public static let shared = DependencyManager()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "Dependencies")

    private init() {}

    // MARK: - Venv

    /// Jack's dedicated Python virtual environment directory.
    public static var venvDir: URL {
        BottleData.containerDir.appending(path: "Python")
    }

    /// The python3 binary inside the venv.
    public var venvPython: String {
        Self.venvDir.appending(path: "bin/python3").path(percentEncoded: false)
    }

    /// Whether the venv exists and has the python binary.
    public var isVenvReady: Bool {
        FileManager.default.fileExists(atPath: venvPython)
    }

    // MARK: - Dependency Status

    public struct Status: Sendable {
        public var rosetta: Bool
        public var jackWine: Bool
        public var python3: Bool
        public var pythonSteam: Bool
        public var steamCMD: Bool
        public var mono: Bool
        public var gptk: Bool

        public var allReady: Bool {
            rosetta && jackWine && python3 && pythonSteam && steamCMD
            // mono is optional — only needed for Steamless DRM stripping
            // gptk is optional — alternative Wine engine with D3DMetal
        }
    }

    /// Check all dependencies and return their status.
    public func checkAll() async -> Status {
        Status(
            rosetta: Rosetta2.isRosettaInstalled,
            jackWine: JackWineInstaller.isJackWineInstalled(),
            python3: isPython3Installed,
            pythonSteam: checkPythonPackages(),
            steamCMD: SteamCMDService.shared.isInstalled,
            mono: isMonoInstalled,
            gptk: GPTKInstaller.shared.isInstalled
        )
    }

    // MARK: - Python 3

    /// Find system Python 3 (used to create the venv).
    public var systemPython3Path: String? {
        for path in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    public var isPython3Installed: Bool {
        systemPython3Path != nil
    }

    /// The python path to use for running scripts — venv if available, system otherwise.
    public var pythonPath: String {
        if isVenvReady { return venvPython }
        return systemPython3Path ?? "/usr/bin/python3"
    }

    /// Check if required pip packages (steam, gevent) are importable in the venv.
    public func checkPythonPackages() -> Bool {
        let python = isVenvReady ? venvPython : (systemPython3Path ?? "")
        guard !python.isEmpty, FileManager.default.fileExists(atPath: python) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import steam; import gevent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Create the venv and install required packages.
    public func installPythonPackages() async throws {
        guard let sysPython = systemPython3Path else {
            throw DependencyError.pythonNotFound
        }

        let venvPath = Self.venvDir.path(percentEncoded: false)

        // Step 1: Create venv if it doesn't exist
        if !isVenvReady {
            Self.log.info("Creating Python venv at \(venvPath)")

            let fm = FileManager.default
            let parent = Self.venvDir.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path(percentEncoded: false)) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            let venvProc = Process()
            venvProc.executableURL = URL(fileURLWithPath: sysPython)
            venvProc.arguments = ["-m", "venv", venvPath]

            let stderr = Pipe()
            venvProc.standardOutput = FileHandle.nullDevice
            venvProc.standardError = stderr

            try venvProc.run()

            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                venvProc.terminationHandler = { _ in c.resume() }
            }

            if venvProc.terminationStatus != 0 {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                throw DependencyError.pipInstallFailed("Failed to create venv: \(errStr)")
            }
        }

        // Step 2: Install packages in the venv
        Self.log.info("Installing Python packages: steam, gevent")

        let pipProc = Process()
        pipProc.executableURL = URL(fileURLWithPath: venvPython)
        pipProc.arguments = ["-m", "pip", "install", "--quiet", "steam", "gevent"]

        let pipStderr = Pipe()
        pipProc.standardOutput = FileHandle.nullDevice
        pipProc.standardError = pipStderr

        try pipProc.run()

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pipProc.terminationHandler = { _ in c.resume() }
        }

        if pipProc.terminationStatus != 0 {
            let errData = pipStderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            Self.log.error("pip install failed: \(errStr)")
            throw DependencyError.pipInstallFailed(errStr)
        }

        Self.log.info("Python packages installed successfully in venv")
    }

    // MARK: - Mono

    public var monoPath: String? {
        for path in ["/opt/homebrew/bin/mono", "/usr/local/bin/mono", "/usr/bin/mono"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    public var isMonoInstalled: Bool {
        monoPath != nil
    }

    /// Install Mono via Homebrew.
    public func installMono() async throws {
        guard let brew = brewPath else {
            throw DependencyError.homebrewNotFound
        }

        Self.log.info("Installing Mono via Homebrew")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "mono"]

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw DependencyError.brewInstallFailed("mono", errStr)
        }

        Self.log.info("Mono installed successfully")
    }

    // MARK: - Python 3 via Homebrew

    /// Install Python 3 via Homebrew.
    public func installPython3() async throws {
        guard let brew = brewPath else {
            throw DependencyError.homebrewNotFound
        }

        Self.log.info("Installing Python 3 via Homebrew")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "python@3.10"]

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw DependencyError.brewInstallFailed("python@3.10", errStr)
        }

        Self.log.info("Python 3.10 installed successfully")
    }

    // MARK: - SteamCMD

    /// Install SteamCMD (delegates to existing service).
    public func installSteamCMD() async throws {
        try await SteamCMDService.shared.ensureInstalled()
    }

    // MARK: - Homebrew

    public var brewPath: String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    public var isHomebrewInstalled: Bool {
        brewPath != nil
    }

    // MARK: - Errors

    public enum DependencyError: LocalizedError {
        case pythonNotFound
        case pipInstallFailed(String)
        case homebrewNotFound
        case brewInstallFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "Python 3 is not installed."
            case .pipInstallFailed(let msg):
                return "Failed to install Python packages: \(msg)"
            case .homebrewNotFound:
                return "Homebrew is not installed. Visit https://brew.sh to install it."
            case .brewInstallFailed(let pkg, let msg):
                return "Failed to install \(pkg): \(msg)"
            }
        }
    }
}
