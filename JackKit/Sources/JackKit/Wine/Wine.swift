//
//  Wine.swift
//  Jack
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

public class Wine {
    /// URL to the installed `DXVK` folder
    private static let dxvkFolder: URL = JackWineInstaller.libraryFolder.appending(path: "DXVK")
    /// Path to the `wine64` binary
    public static let wineBinary: URL = JackWineInstaller.binFolder.appending(path: "wine64")
    /// Parth to the `wineserver` binary
    private static let wineserverBinary: URL = JackWineInstaller.binFolder.appending(path: "wineserver")

    /// Run a process on a executable file given by the `executableURL`
    private static func runProcess(
        name: String? = nil, args: [String], environment: [String: String], executableURL: URL, directory: URL? = nil,
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = directory ?? executableURL.deletingLastPathComponent()
        process.environment = environment
        process.qualityOfService = .userInitiated

        return try process.runStream(
            name: name ?? args.joined(separator: " "), fileHandle: fileHandle
        )
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    private static func runWineProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        directory: URL? = nil, fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        return try runProcess(
            name: name, args: args, environment: environment, executableURL: wineBinary,
            directory: directory, fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    private static func runWineserverProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        return try runProcess(
            name: name, args: args, environment: environment, executableURL: wineserverBinary,
            fileHandle: fileHandle
        )
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    public static func runWineProcess(
        name: String? = nil, args: [String], bottle: Bottle,
        workingDirectory: URL? = nil, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        fileHandle.writeInfo(for: bottle)

        return try runWineProcess(
            name: name, args: args,
            environment: constructWineEnvironment(for: bottle, environment: environment),
            directory: workingDirectory,
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    public static func runWineserverProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        fileHandle.writeInfo(for: bottle)

        return try runWineserverProcess(
            name: name, args: args,
            environment: constructWineServerEnvironment(for: bottle, environment: environment),
            fileHandle: fileHandle
        )
    }

    /// Execute a `wine start /unix {url}` command returning the output result
    public static func runProgram(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:]
    ) async throws {
        if bottle.settings.dxvk {
            try enableDXVK(bottle: bottle)
        }

        for await _ in try Self.runWineProcess(
            name: url.lastPathComponent,
            args: ["start", "/unix", url.path(percentEncoded: false)] + args,
            bottle: bottle, environment: environment
        ) { }
    }

    public static func generateRunCommand(
        at url: URL, bottle: Bottle, args: String, environment: [String: String]
    ) -> String {
        var wineCmd = "\(wineBinary.esc) start /unix \(url.esc) \(args)"
        let env = constructWineEnvironment(for: bottle, environment: environment)
        for environment in env {
            wineCmd = "\(environment.key)=\"\(environment.value)\" " + wineCmd
        }

        return wineCmd
    }

    public static func generateTerminalEnvironmentCommand(bottle: Bottle) -> String {
        var cmd = """
        export PATH=\"\(JackWineInstaller.binFolder.path):$PATH\"
        export WINE=\"wine64\"
        alias wine=\"wine64\"
        alias winecfg=\"wine64 winecfg\"
        alias msiexec=\"wine64 msiexec\"
        alias regedit=\"wine64 regedit\"
        alias regsvr32=\"wine64 regsvr32\"
        alias wineboot=\"wine64 wineboot\"
        alias wineconsole=\"wine64 wineconsole\"
        alias winedbg=\"wine64 winedbg\"
        alias winefile=\"wine64 winefile\"
        alias winepath=\"wine64 winepath\"
        """

        let env = constructWineEnvironment(for: bottle, environment: constructWineEnvironment(for: bottle))
        for environment in env {
            cmd += "\nexport \(environment.key)=\"\(environment.value)\""
        }

        return cmd
    }

    /// Run a `wineserver` command with the given arguments and return the output result
    private static func runWineserver(_ args: [String], bottle: Bottle) async throws -> String {
        var result: [ProcessOutput] = []

        for await output in try Self.runWineserverProcess(args: args, bottle: bottle, environment: [:]) {
            result.append(output)
        }

        return result.compactMap { output -> String? in
            switch output {
            case .started, .terminated:
                return nil
            case .message(let message), .error(let message):
                return message
            }
        }.joined()
    }

    @discardableResult
    /// Run a `wine` command with the given arguments and return the output result
    public static func runWine(
        _ args: [String], bottle: Bottle?, environment: [String: String] = [:]
    ) async throws -> String {
        var result: [String] = []
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        var environment = environment

        if let bottle = bottle {
            fileHandle.writeInfo(for: bottle)
            environment = constructWineEnvironment(for: bottle, environment: environment)
        }

        for await output in try runWineProcess(args: args, environment: environment, fileHandle: fileHandle) {
            switch output {
            case .started, .terminated:
                break
            case .message(let message), .error(let message):
                result.append(message)
            }
        }

        return result.joined()
    }

    public static func wineVersion() async throws -> String {
        var output = try await runWine(["--version"], bottle: nil)
        output.replace("wine-", with: "")

        // Deal with WineCX version names
        if let index = output.firstIndex(where: { $0.isWhitespace }) {
            return String(output.prefix(upTo: index))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public static func runBatchFile(url: URL, bottle: Bottle) async throws -> String {
        return try await runWine(["cmd", "/c", url.path(percentEncoded: false)], bottle: bottle)
    }

    public static func killBottle(bottle: Bottle) throws {
        Task.detached(priority: .userInitiated) {
            try await runWineserver(["-k"], bottle: bottle)
        }
    }

    public static func enableDXVK(bottle: Bottle) throws {
        try FileManager.default.replaceDLLs(
            in: bottle.url.appending(path: "drive_c").appending(path: "windows").appending(path: "system32"),
            withContentsIn: Wine.dxvkFolder.appending(path: "x64")
        )
        try FileManager.default.replaceDLLs(
            in: bottle.url.appending(path: "drive_c").appending(path: "windows").appending(path: "syswow64"),
            withContentsIn: Wine.dxvkFolder.appending(path: "x32")
        )
    }

    /// Construct an environment merging the bottle values with the given values
    private static func constructWineEnvironment(
        for bottle: Bottle, environment: [String: String] = [:]
    ) -> [String: String] {
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "fixme-all",
            "GST_DEBUG": "1"
        ]
        bottle.settings.environmentVariables(wineEnv: &result)
        guard !environment.isEmpty else { return result }
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }

    // MARK: - Steam DRM daemon

    /// Launch steam.exe silently inside the bottle as a background DRM daemon.
    /// Uses research-backed fixes for the steamwebhelper dialog on Wine macOS 2024+:
    ///   - chmod -x steamwebhelper.exe (Steam still runs for IPC, no browser UI needed)
    ///   - BootStrapperInhibitAll=enable in steam.cfg (blocks auto-update that re-breaks it)
    ///   - -allosarches -cef-force-32bit (avoids chrome_elf.dll abort on 64-bit CEF)
    ///   - LANG=en_US.UTF-8 (prevents HTTP_ParseDate locale bug e.g. Netherlands)
    /// Returns true if Steam has been logged in at least once in the bottle
    /// (loginusers.vdf exists and is non-empty).
    public static func isSteamLoggedIn(in bottle: Bottle) -> Bool {
        let loginFile = BottleData.steamDir
            .appending(path: "config")
            .appending(path: "loginusers.vdf")
        guard let data = try? Data(contentsOf: loginFile),
              let text = String(data: data, encoding: .utf8) else { return false }
        // loginusers.vdf has at least one user entry if logged in
        return text.contains("\"users\"") && text.count > 50
    }

    /// Perform a one-time interactive login to steam.exe with username+password.
    /// Launches steam.exe with `-login user pass -silent`, which authenticates in the background.
    /// The user must approve Steam Guard on their phone. After that, credentials are cached
    /// and `launchSteamDaemon` can use `-login username` without a password.
    public static func loginSteamInteractive(
        bottle: Bottle, username: String, password: String
    ) async throws {
        let steamExe = BottleData.steamDir.appending(path: "steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path(percentEncoded: false)) else {
            throw SteamDaemonError.steamExeNotFound
        }

        // Replace steamwebhelper with sleeping stub (keeps it "alive" so no dialog)
        // but do NOT write steam.cfg — BootStrapperInhibitAll blocks the auth flow.
        replaceSteamWebHelper()

        // Remove steam.cfg if present: BootStrapperInhibitAll=enable blocks login
        let steamCfg = BottleData.steamDir.appending(path: "steam.cfg")
        try? FileManager.default.removeItem(at: steamCfg)

        var env = constructWineEnvironment(for: bottle)
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"

        let process = Process()
        process.executableURL = wineBinary
        process.arguments = [
            "start", "/unix", steamExe.path(percentEncoded: false),
            "-login", username, password,
            "-silent", "-allosarches", "-cef-force-32bit", "-no-dwrite"
        ]
        process.environment = env
        process.currentDirectoryURL = wineBinary.deletingLastPathComponent()
        try process.run()
    }

    /// Replace steamwebhelper.exe with the sleeping stub without writing steam.cfg.
    /// Used during login (steam.cfg blocks auth).
    private static func replaceSteamWebHelper() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: BottleData.steamDir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for case let url as URL in e {
            guard url.lastPathComponent.lowercased() == "steamwebhelper.exe" else { continue }
            let path = url.path(percentEncoded: false)
            if let existing = try? Data(contentsOf: url),
               existing.count == sleepingStubPE.count,
               existing.count > 0x9D,
               existing[0x9C] == 2 { continue }
            let backup = path + ".original_jack"
            if !fm.fileExists(atPath: backup) {
                try? fm.copyItem(atPath: path, toPath: backup)
            }
            fm.createFile(atPath: path, contents: sleepingStubPE)
        }
    }

    /// Launch steam.exe silently as a DRM daemon.
    /// - Parameter username: Steam account username for auto-login (required for DRM).
    @discardableResult
    public static func launchSteamDaemon(bottle: Bottle, username: String = "") throws -> Process {
        prepareSteamForDaemon()

        let steamExe = BottleData.steamDir.appending(path: "steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path(percentEncoded: false)) else {
            throw SteamDaemonError.steamExeNotFound
        }

        var env = constructWineEnvironment(for: bottle)
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"

        var args = [
            "start", "/unix", steamExe.path(percentEncoded: false),
            "-allosarches", "-cef-force-32bit",
            "-nofriendsui", "-silent", "-no-dwrite"
        ]
        // -login is required for DRM: without it steam.exe starts but isn't authenticated
        if !username.isEmpty {
            args += ["-login", username]
        }

        let process = Process()
        process.executableURL = wineBinary
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = wineBinary.deletingLastPathComponent()
        try process.run()
        return process
    }

    /// Open steam.exe with full UI so the user can log in interactively (one-time setup).
    /// After this, launchSteamDaemon can auto-login with cached credentials.
    /// NOTE: restores the original steamwebhelper.exe so the Steam UI can render.
    public static func launchSteamForSetup(bottle: Bottle) throws {
        let steamExe = BottleData.steamDir.appending(path: "steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path(percentEncoded: false)) else {
            throw SteamDaemonError.steamExeNotFound
        }
        // Restore original steamwebhelper so Steam can render its CEF/login UI.
        // Do NOT call prepareSteamForDaemon() here — that replaces steamwebhelper
        // with a sleeping stub which kills all UI rendering.
        restoreSteamWebHelper()

        var env = constructWineEnvironment(for: bottle)
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"

        let process = Process()
        process.executableURL = wineBinary
        process.arguments = [
            "start", "/unix", steamExe.path(percentEncoded: false),
            "-allosarches", "-no-dwrite"
            // No -silent, no -cef-force-32bit: allow full CEF UI for login
        ]
        process.environment = env
        process.currentDirectoryURL = wineBinary.deletingLastPathComponent()
        try process.run()
    }

    /// Restore the original steamwebhelper.exe from backup (if it was replaced by the sleeping stub).
    public static func restoreSteamWebHelper() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: BottleData.steamDir, includingPropertiesForKeys: []) else { return }
        for case let url as URL in e {
            guard url.lastPathComponent.lowercased() == "steamwebhelper.exe" else { continue }
            let backup = url.path(percentEncoded: false) + ".original_jack"
            guard fm.fileExists(atPath: backup) else { continue }
            try? fm.removeItem(at: url)
            try? fm.copyItem(atPath: backup, toPath: url.path(percentEncoded: false))
        }
    }

    /// Prepare Steam installation to suppress the steamwebhelper dialog.
    ///
    /// Root cause: Steam 2024+ checks that steamwebhelper.exe is ALIVE (not just launched).
    /// Neither dummy-PE-that-exits nor chmod-x work — Steam shows the dialog in both cases.
    ///
    /// Fix: replace steamwebhelper.exe with a "sleeping stub" PE that imports
    /// kernel32.dll!Sleep and calls Sleep(INFINITE) in a loop. The process stays
    /// resident → Steam's monitor sees it as alive → no dialog. Uses ~0% CPU.
    public static func prepareSteamForDaemon() {
        let fm = FileManager.default

        // 1. steam.cfg: block auto-update (would restore real steamwebhelper)
        let steamCfg = BottleData.steamDir.appending(path: "steam.cfg")
        let cfgContent = "BootStrapperInhibitAll=enable\nBootStrapperForceSelfUpdate=disable\n"
        try? cfgContent.write(to: steamCfg, atomically: true, encoding: .utf8)

        // 2. Replace steamwebhelper.exe with a sleeping stub.
        //    The stub imports kernel32!Sleep and calls Sleep(0xFFFFFFFF) in a loop.
        //    Steam detects it as alive → no "Steamwebhelper not responding" dialog.
        for searchDir in [BottleData.steamDir] {
            guard let e = fm.enumerator(at: searchDir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in e {
                guard url.lastPathComponent.lowercased() == "steamwebhelper.exe" else { continue }
                let path = url.path(percentEncoded: false)
                // Skip only if already replaced with the GUI stub (check size + subsystem byte 0x9C = 2)
                if let existing = try? Data(contentsOf: url),
                   existing.count == sleepingStubPE.count,
                   existing.count > 0x9D,
                   existing[0x9C] == 2 { continue }
                // Backup original
                let backup = path + ".original_jack"
                if !fm.fileExists(atPath: backup) {
                    try? fm.copyItem(atPath: path, toPath: backup)
                }
                fm.createFile(atPath: path, contents: sleepingStubPE)
            }
        }
    }

    public static func disableSteamWebHelper(bottle: Bottle) { prepareSteamForDaemon() }

    public enum SteamDaemonError: LocalizedError {
        case steamExeNotFound
        public var errorDescription: String? {
            "steam.exe not found in the bottle. Please install Steam first."
        }
    }

    /// PE32 sleeping stub (1536 bytes).
    /// Imports kernel32.dll!Sleep, calls Sleep(0xFFFFFFFF) in an infinite loop.
    /// Used to replace steamwebhelper.exe so Steam thinks it's alive (no dialog).
    ///
    /// Layout:
    ///   0x000–0x1FF  headers (.rdata VirtualAddr=0x1000, .text VirtualAddr=0x2000)
    ///   0x200–0x3FF  .rdata: import table → kernel32.dll!Sleep
    ///   0x400–0x5FF  .text:  push 0xFFFFFFFF; call [IAT_Sleep]; jmp back
    private static let sleepingStubPE: Data = {
        var pe = Data(count: 0x600)

        // ── DOS Header ──────────────────────────────────────────────────────
        pe[0x00] = 0x4D; pe[0x01] = 0x5A          // MZ
        pe.withUnsafeMutableBytes { b in
            b.storeBytes(of: UInt32(0x40).littleEndian, toByteOffset: 0x3C, as: UInt32.self) // e_lfanew
        }

        // ── PE Signature ────────────────────────────────────────────────────
        pe[0x40] = 0x50; pe[0x41] = 0x45           // "PE\0\0"

        pe.withUnsafeMutableBytes { b in
            // ── COFF Header (at 0x44) ────────────────────────────────────────
            b.storeBytes(of: UInt16(0x014C).littleEndian, toByteOffset: 0x44, as: UInt16.self) // i386
            b.storeBytes(of: UInt16(2).littleEndian,      toByteOffset: 0x46, as: UInt16.self) // 2 sections
            b.storeBytes(of: UInt16(0x00E0).littleEndian, toByteOffset: 0x54, as: UInt16.self) // OptHdr size
            b.storeBytes(of: UInt16(0x0103).littleEndian, toByteOffset: 0x56, as: UInt16.self) // RELOCS_STRIPPED|EXEC|32BIT

            // ── Optional Header PE32 (at 0x58) ──────────────────────────────
            b.storeBytes(of: UInt16(0x010B).littleEndian, toByteOffset: 0x58, as: UInt16.self) // PE32
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x5C, as: UInt32.self) // SizeOfCode
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x60, as: UInt32.self) // SizeOfInitData
            b.storeBytes(of: UInt32(0x2000).littleEndian, toByteOffset: 0x68, as: UInt32.self) // EntryPoint RVA
            b.storeBytes(of: UInt32(0x2000).littleEndian, toByteOffset: 0x6C, as: UInt32.self) // BaseOfCode
            b.storeBytes(of: UInt32(0x1000).littleEndian, toByteOffset: 0x70, as: UInt32.self) // BaseOfData
            b.storeBytes(of: UInt32(0x00400000).littleEndian, toByteOffset: 0x74, as: UInt32.self) // ImageBase
            b.storeBytes(of: UInt32(0x1000).littleEndian, toByteOffset: 0x78, as: UInt32.self) // SectionAlign
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x7C, as: UInt32.self) // FileAlign
            b.storeBytes(of: UInt16(4).littleEndian,      toByteOffset: 0x80, as: UInt16.self) // MajorOSVer
            b.storeBytes(of: UInt16(4).littleEndian,      toByteOffset: 0x88, as: UInt16.self) // MajorSubsysVer
            b.storeBytes(of: UInt32(0x4000).littleEndian, toByteOffset: 0x90, as: UInt32.self) // SizeOfImage
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x94, as: UInt32.self) // SizeOfHeaders
            b.storeBytes(of: UInt16(2).littleEndian,      toByteOffset: 0x9C, as: UInt16.self) // Subsystem=GUI (no console window)
            b.storeBytes(of: UInt32(0x100000).littleEndian, toByteOffset: 0xA0, as: UInt32.self)
            b.storeBytes(of: UInt32(0x001000).littleEndian, toByteOffset: 0xA4, as: UInt32.self)
            b.storeBytes(of: UInt32(0x100000).littleEndian, toByteOffset: 0xA8, as: UInt32.self)
            b.storeBytes(of: UInt32(0x001000).littleEndian, toByteOffset: 0xAC, as: UInt32.self)
            b.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0xB4, as: UInt32.self) // NumDirs
            // DataDirectory[1] = Import Table: RVA=0x1000, Size=0x50
            b.storeBytes(of: UInt32(0x1000).littleEndian, toByteOffset: 0xC0, as: UInt32.self)
            b.storeBytes(of: UInt32(0x0050).littleEndian, toByteOffset: 0xC4, as: UInt32.self)

            // ── Section header 1: .rdata (at 0x138) ─────────────────────────
            // ".rdata\0\0"
            let rn: [UInt8] = [0x2E,0x72,0x64,0x61,0x74,0x61,0x00,0x00]
            for i in 0..<8 { b.storeBytes(of: rn[i], toByteOffset: 0x138+i, as: UInt8.self) }
            b.storeBytes(of: UInt32(0x60).littleEndian,   toByteOffset: 0x140, as: UInt32.self) // VirtualSize
            b.storeBytes(of: UInt32(0x1000).littleEndian, toByteOffset: 0x144, as: UInt32.self) // VirtualAddr
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x148, as: UInt32.self) // RawSize
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x14C, as: UInt32.self) // RawPtr
            b.storeBytes(of: UInt32(0x40000040).littleEndian, toByteOffset: 0x15C, as: UInt32.self) // DATA|READ

            // ── Section header 2: .text (at 0x160) ──────────────────────────
            // ".text\0\0\0"
            let tn: [UInt8] = [0x2E,0x74,0x65,0x78,0x74,0x00,0x00,0x00]
            for i in 0..<8 { b.storeBytes(of: tn[i], toByteOffset: 0x160+i, as: UInt8.self) }
            b.storeBytes(of: UInt32(0x0D).littleEndian,   toByteOffset: 0x168, as: UInt32.self) // VirtualSize=13
            b.storeBytes(of: UInt32(0x2000).littleEndian, toByteOffset: 0x16C, as: UInt32.self) // VirtualAddr
            b.storeBytes(of: UInt32(0x0200).littleEndian, toByteOffset: 0x170, as: UInt32.self) // RawSize
            b.storeBytes(of: UInt32(0x0400).littleEndian, toByteOffset: 0x174, as: UInt32.self) // RawPtr
            b.storeBytes(of: UInt32(0x60000020).littleEndian, toByteOffset: 0x184, as: UInt32.self) // CODE|EXEC|READ

            // ── .rdata section (file offset 0x200 = VA 0x401000) ────────────
            // IMAGE_IMPORT_DESCRIPTOR for kernel32.dll
            //   OriginalFirstThunk = 0x1028 (ILT RVA)
            b.storeBytes(of: UInt32(0x1028).littleEndian, toByteOffset: 0x200, as: UInt32.self)
            //   Name = 0x1040 ("kernel32.dll")
            b.storeBytes(of: UInt32(0x1040).littleEndian, toByteOffset: 0x20C, as: UInt32.self)
            //   FirstThunk = 0x1020 (IAT RVA — Sleep address slot)
            b.storeBytes(of: UInt32(0x1020).littleEndian, toByteOffset: 0x210, as: UInt32.self)
            // Null descriptor at 0x214 (zeros — already)

            // IAT at 0x220 (RVA 0x1020): initially → hint+name RVA, patched by loader
            b.storeBytes(of: UInt32(0x1030).littleEndian, toByteOffset: 0x220, as: UInt32.self)
            // IAT terminator at 0x224: 0

            // ILT at 0x228 (RVA 0x1028)
            b.storeBytes(of: UInt32(0x1030).littleEndian, toByteOffset: 0x228, as: UInt32.self)
            // ILT terminator at 0x22C: 0

            // IMAGE_IMPORT_BY_NAME at 0x230 (RVA 0x1030): hint=0, name="Sleep\0"
            // hint = 0 (already)
            let sn: [UInt8] = [0x53,0x6C,0x65,0x65,0x70,0x00]  // "Sleep\0"
            for i in 0..<6 { b.storeBytes(of: sn[i], toByteOffset: 0x232+i, as: UInt8.self) }

            // "kernel32.dll\0" at 0x240 (RVA 0x1040)
            let k: [UInt8] = [0x6B,0x65,0x72,0x6E,0x65,0x6C,0x33,0x32,0x2E,0x64,0x6C,0x6C,0x00]
            for i in 0..<13 { b.storeBytes(of: k[i], toByteOffset: 0x240+i, as: UInt8.self) }

            // ── .text section (file offset 0x400 = VA 0x402000) ─────────────
            // push 0xFFFFFFFF (INFINITE)   → 68 FF FF FF FF
            b.storeBytes(of: UInt8(0x68),          toByteOffset: 0x400, as: UInt8.self)
            b.storeBytes(of: UInt32(0xFFFFFFFF).littleEndian, toByteOffset: 0x401, as: UInt32.self)
            // call dword ptr [0x00401020]  → FF 15 20 10 40 00  (IAT Sleep slot)
            b.storeBytes(of: UInt8(0xFF),          toByteOffset: 0x405, as: UInt8.self)
            b.storeBytes(of: UInt8(0x15),          toByteOffset: 0x406, as: UInt8.self)
            b.storeBytes(of: UInt32(0x00401020).littleEndian, toByteOffset: 0x407, as: UInt32.self)
            // jmp short -13 (back to push)  → EB F3
            // Next IP = 0x40D; 0x40D + sign(0xF3) = 0x40D - 0x0D = 0x400 ✓
            b.storeBytes(of: UInt8(0xEB),          toByteOffset: 0x40B, as: UInt8.self)
            b.storeBytes(of: UInt8(0xF3),          toByteOffset: 0x40C, as: UInt8.self)
        }
        return pe
    }()

    /// Construct an environment merging the bottle values with the given values
    private static func constructWineServerEnvironment(
        for bottle: Bottle, environment: [String: String] = [:]
    ) -> [String: String] {
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "fixme-all",
            "GST_DEBUG": "1"
        ]
        guard !environment.isEmpty else { return result }
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }
}

enum WineInterfaceError: Error {
    case invalidResponce
}

enum RegistryType: String {
    case binary = "REG_BINARY"
    case dword = "REG_DWORD"
    case qword = "REG_QWORD"
    case string = "REG_SZ"
}

extension Wine {
    public static let logsFolder = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appending(path: "Logs").appending(path: Bundle.jackBundleIdentifier)

    public static func makeFileHandle() throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: Self.logsFolder.path) {
            try FileManager.default.createDirectory(at: Self.logsFolder, withIntermediateDirectories: true)
        }

        let dateString = Date.now.ISO8601Format()
        let fileURL = Self.logsFolder.appending(path: dateString).appendingPathExtension("log")
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        return try FileHandle(forWritingTo: fileURL)
    }
}

extension Wine {
    private enum RegistryKey: String {
        case currentVersion = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#
        case macDriver = #"HKCU\Software\Wine\Mac Driver"#
        case desktop = #"HKCU\Control Panel\Desktop"#
    }

    private static func addRegistryKey(
        bottle: Bottle, key: String, name: String, data: String, type: RegistryType
    ) async throws {
        try await runWine(
            ["reg", "add", key, "-v", name, "-t", type.rawValue, "-d", data, "-f"],
            bottle: bottle
        )
    }

    private static func queryRegistryKey(
        bottle: Bottle, key: String, name: String, type: RegistryType
    ) async throws -> String? {
        let output = try await runWine(["reg", "query", key, "-v", name], bottle: bottle)
        let lines = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        guard let line = lines.first(where: { $0.contains(type.rawValue) }) else { return nil }
        let array = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let value = array.last else { return nil }
        return String(value)
    }

    public static func changeBuildVersion(bottle: Bottle, version: Int) async throws {
        try await addRegistryKey(bottle: bottle, key: RegistryKey.currentVersion.rawValue,
                                name: "CurrentBuild", data: "\(version)", type: .string)
        try await addRegistryKey(bottle: bottle, key: RegistryKey.currentVersion.rawValue,
                                name: "CurrentBuildNumber", data: "\(version)", type: .string)
    }

    public static func winVersion(bottle: Bottle) async throws -> WinVersion {
        let output = try await Wine.runWine(["winecfg", "-v"], bottle: bottle)
        let lines = output.split(whereSeparator: \.isNewline)

        if let lastLine = lines.last {
            let winString = String(lastLine)

            if let version = WinVersion(rawValue: winString) {
                return version
            }
        }

        throw WineInterfaceError.invalidResponce
    }

    public static func buildVersion(bottle: Bottle) async throws -> String? {
        return try await Wine.queryRegistryKey(
            bottle: bottle, key: RegistryKey.currentVersion.rawValue,
            name: "CurrentBuild", type: .string
        )
    }

    public static func retinaMode(bottle: Bottle) async throws -> Bool {
        let values: Set<String> = ["y", "n"]
        guard let output = try await Wine.queryRegistryKey(
            bottle: bottle, key: RegistryKey.macDriver.rawValue, name: "RetinaMode", type: .string
        ), values.contains(output) else {
            try await changeRetinaMode(bottle: bottle, retinaMode: false)
            return false
        }
        return output == "y"
    }

    public static func changeRetinaMode(bottle: Bottle, retinaMode: Bool) async throws {
        try await Wine.addRegistryKey(
            bottle: bottle, key: RegistryKey.macDriver.rawValue, name: "RetinaMode", data: retinaMode ? "y" : "n",
            type: .string
        )
    }

    public static func dpiResolution(bottle: Bottle) async throws -> Int? {
        guard let output = try await Wine.queryRegistryKey(bottle: bottle, key: RegistryKey.desktop.rawValue,
                                                     name: "LogPixels", type: .dword
        ) else { return nil }

        let noPrefix = output.replacingOccurrences(of: "0x", with: "")
        let int = Int(noPrefix, radix: 16)
        guard let int = int else { return nil }
        return int
    }

    public static func changeDpiResolution(bottle: Bottle, dpi: Int) async throws {
        try await Wine.addRegistryKey(
            bottle: bottle, key: RegistryKey.desktop.rawValue, name: "LogPixels", data: String(dpi),
            type: .dword
        )
    }

    @discardableResult
    public static func control(bottle: Bottle) async throws -> String {
        return try await Wine.runWine(["control"], bottle: bottle)
    }

    @discardableResult
    public static func regedit(bottle: Bottle) async throws -> String {
        return try await Wine.runWine(["regedit"], bottle: bottle)
    }

    @discardableResult
    public static func cfg(bottle: Bottle) async throws -> String {
        return try await Wine.runWine(["winecfg"], bottle: bottle)
    }

    @discardableResult
    public static func changeWinVersion(bottle: Bottle, win: WinVersion) async throws -> String {
        return try await Wine.runWine(["winecfg", "-v", win.rawValue], bottle: bottle)
    }
}
