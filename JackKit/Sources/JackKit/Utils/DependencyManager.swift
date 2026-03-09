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

    // MARK: - Dependency Status

    public struct Status: Sendable {
        public var rosetta: Bool
        public var jackWine: Bool
        public var python3: Bool
        public var pythonSteam: Bool
        public var steamCMD: Bool
        public var mono: Bool

        public var allReady: Bool {
            rosetta && jackWine && python3 && pythonSteam && steamCMD
            // mono is optional — only needed for Steamless DRM stripping
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
            mono: isMonoInstalled
        )
    }

    // MARK: - Python 3

    /// The Python 3 path Jack uses (prefers 3.10 for steam library compatibility).
    public var python3Path: String? {
        for path in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    public var isPython3Installed: Bool {
        python3Path != nil
    }

    /// Check if required pip packages (steam, gevent) are importable.
    public func checkPythonPackages() -> Bool {
        guard let python = python3Path else { return false }

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

    /// Install the required pip packages.
    public func installPythonPackages() async throws {
        guard let python = python3Path else {
            throw DependencyError.pythonNotFound
        }

        Self.log.info("Installing Python packages: steam, gevent")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "pip", "install", "--user", "--quiet", "steam", "gevent"]

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
            Self.log.error("pip install failed: \(errStr)")
            throw DependencyError.pipInstallFailed(errStr)
        }

        Self.log.info("Python packages installed successfully")
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
