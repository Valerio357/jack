//
//  SteamlessService.swift
//  JackKit
//
//  SteamStub DRM stripper — removes the SteamStub wrapper from game executables.
//
//  Uses the real Steamless CLI (by atom0s) via Mono to handle all SteamStub variants
//  including encrypted code sections. Falls back to native PE patching for simple
//  variants when Mono is not available.
//
//  SteamStub adds a ".bind" section to the PE that runs before the real entry point,
//  verifies Steam ownership, and optionally encrypts the original code section.
//  Goldberg replaces steam_api.dll but can't help if the stub itself blocks launch.
//

import Foundation
import os.log

public enum SteamlessError: LocalizedError {
    case notSteamStub
    case unsupportedVariant
    case corruptHeader
    case unpackFailed(String)
    case monoNotInstalled
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .notSteamStub:        return "No SteamStub DRM detected."
        case .unsupportedVariant:  return "Unsupported SteamStub variant."
        case .corruptHeader:       return "Corrupt SteamStub header."
        case .unpackFailed(let d): return "SteamStub strip failed: \(d)"
        case .monoNotInstalled:    return "Mono runtime is required to strip SteamStub DRM. Install it with: brew install mono"
        case .downloadFailed:      return "Failed to download Steamless CLI."
        }
    }
}

public final class SteamlessService: @unchecked Sendable {
    public static let shared = SteamlessService()

    /// Where Steamless CLI is stored
    private let steamlessDir = BottleData.steamCMDDir.appending(path: "Steamless")
    private let steamlessVersion = "v3.1.0.5"
    private let steamlessDownloadURL = "https://github.com/atom0s/Steamless/releases/download/v3.1.0.5/Steamless.v3.1.0.5.-.by.atom0s.zip"

    private var cliExe: URL { steamlessDir.appending(path: "Steamless.CLI.exe") }

    private init() {}

    // MARK: - Public API

    /// Returns true if the Mono runtime is available.
    public var isMonoInstalled: Bool {
        FileManager.default.fileExists(atPath: monoPath)
    }

    /// Returns true if Steamless CLI is downloaded and ready.
    public var isSteamlessInstalled: Bool {
        FileManager.default.fileExists(atPath: cliExe.path(percentEncoded: false))
    }

    /// Download and extract the Steamless CLI tool.
    public func ensureInstalled() async throws {
        if isSteamlessInstalled { return }

        let fm = FileManager.default
        try fm.createDirectory(at: steamlessDir, withIntermediateDirectories: true)

        guard let url = URL(string: steamlessDownloadURL) else { throw SteamlessError.downloadFailed }

        let (tempZip, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamlessError.downloadFailed
        }

        // Extract
        let extractDir = steamlessDir.appending(path: "tmp_extract")
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", tempZip.path(percentEncoded: false),
                           "-d", extractDir.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        try? fm.removeItem(at: tempZip)

        guard unzip.terminationStatus == 0 else { throw SteamlessError.downloadFailed }

        // Copy entire contents preserving structure (Plugins/ subfolder must exist)
        if let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard attrs?.isRegularFile == true else { continue }
                // Preserve relative path (e.g. Plugins/foo.dll)
                let relative = fileURL.path(percentEncoded: false)
                    .replacingOccurrences(of: extractDir.path(percentEncoded: false) + "/", with: "")
                let dest = steamlessDir.appending(path: relative)
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: fileURL, to: dest)
            }
        }

        try? fm.removeItem(at: extractDir)

        guard isSteamlessInstalled else { throw SteamlessError.downloadFailed }
    }

    /// Strips SteamStub DRM from a game executable.
    /// Uses Steamless CLI via Mono for full variant support.
    /// Backs up the original as `.steamstub_backup`.
    /// Skips if already stripped or if no SteamStub is detected.
    @discardableResult
    public func stripIfNeeded(exe: URL) async throws -> URL {
        let fm = FileManager.default
        let backup = backupURL(for: exe)

        // Already stripped in a previous run
        if fm.fileExists(atPath: backup.path(percentEncoded: false)) {
            return exe
        }

        // Check for .bind section
        guard hasSteamStub(exe: exe) else { return exe }

        // Try Steamless CLI via Mono (handles ALL variants including encrypted)
        if isMonoInstalled {
            try await ensureInstalled()
            try await runSteamlessCLI(exe: exe, backup: backup)
            return exe
        }

        // Fallback: native PE patching (only simple C0DEC0DE variants)
        guard var data = try? Data(contentsOf: exe, options: []) else { return exe }
        guard let bindInfo = findBindSection(in: data) else { return exe }

        do {
            try patchSteamStub(data: &data, bind: bindInfo)
        } catch SteamlessError.unsupportedVariant {
            // Can't strip without Mono
            throw SteamlessError.monoNotInstalled
        }

        try fm.copyItem(at: exe, to: backup)
        try data.write(to: exe, options: .atomic)
        return exe
    }

    /// Restore original SteamStub-wrapped exe (undo strip).
    public func restore(exe: URL) {
        let fm = FileManager.default
        let backup = backupURL(for: exe)
        guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        try? fm.removeItem(at: exe)
        try? fm.moveItem(at: backup, to: exe)
    }

    /// Returns true if a SteamStub backup exists for this exe.
    public func isStripped(exe: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: backupURL(for: exe).path(percentEncoded: false)
        )
    }

    /// Returns true if the exe has a `.bind` section (SteamStub DRM present).
    public func hasSteamStub(exe: URL) -> Bool {
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe),
              data.count > 512 else { return false }
        return findBindSection(in: data) != nil
    }

    // MARK: - Steamless CLI via Mono

    /// Path to mono binary (brew install mono)
    private var monoPath: String {
        // Check common mono locations
        for path in ["/opt/homebrew/bin/mono", "/usr/local/bin/mono", "/usr/bin/mono"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/mono"
    }

    private func runSteamlessCLI(exe: URL, backup: URL) async throws {
        let fm = FileManager.default

        // Backup original before stripping
        try fm.copyItem(at: exe, to: backup)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: monoPath)
        process.arguments = [cliExe.path(percentEncoded: false), exe.path(percentEncoded: false)]
        process.currentDirectoryURL = steamlessDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Wait with timeout (60 seconds for large executables)
        let pid = process.processIdentifier
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        // Steamless saves as exe.unpacked.exe
        let unpackedPath = exe.path(percentEncoded: false) + ".unpacked.exe"

        if process.terminationStatus == 0,
           fm.fileExists(atPath: unpackedPath) {
            // Replace original with unpacked version
            try fm.removeItem(at: exe)
            try fm.moveItem(atPath: unpackedPath, toPath: exe.path(percentEncoded: false))
        } else {
            // Restore backup on failure
            try? fm.removeItem(at: exe)
            try? fm.moveItem(at: backup, to: exe)
            try? fm.removeItem(atPath: unpackedPath)

            if output.contains("Successfully unpacked") {
                // Output says success but file is missing — shouldn't happen
                throw SteamlessError.unpackFailed("Unpacked file not found")
            } else {
                throw SteamlessError.unpackFailed(
                    output.components(separatedBy: .newlines)
                        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    ?? "Steamless exited with code \(process.terminationStatus)"
                )
            }
        }
    }

    // MARK: - Internals

    private func backupURL(for exe: URL) -> URL {
        exe.deletingLastPathComponent()
            .appending(path: exe.lastPathComponent + ".steamstub_backup")
    }

    // MARK: - PE Parsing Helpers

    private struct BindSectionInfo {
        let sectionHeaderOffset: Int
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawDataOffset: UInt32
        let rawDataSize: UInt32
        let sectionIndex: Int
        let numberOfSections: Int
        let coffHeaderOffset: Int
        let optionalHeaderOffset: Int
        let is64Bit: Bool
    }

    private func findBindSection(in data: Data) -> BindSectionInfo? {
        guard data.count > 512 else { return nil }
        guard data[0] == 0x4D, data[1] == 0x5A else { return nil }
        let peOffset = readUInt32(data, at: 0x3C)
        guard peOffset > 0, Int(peOffset) + 4 < data.count else { return nil }
        guard data[Int(peOffset)] == 0x50, data[Int(peOffset) + 1] == 0x45,
              data[Int(peOffset) + 2] == 0x00, data[Int(peOffset) + 3] == 0x00 else { return nil }

        let coffOffset = Int(peOffset) + 4
        guard coffOffset + 20 <= data.count else { return nil }

        let numberOfSections = Int(readUInt16(data, at: coffOffset + 2))
        let sizeOfOptionalHeader = Int(readUInt16(data, at: coffOffset + 16))
        let optionalHeaderOffset = coffOffset + 20

        guard optionalHeaderOffset + 2 <= data.count else { return nil }
        let magic = readUInt16(data, at: optionalHeaderOffset)
        let is64 = magic == 0x020B

        let sectionStart = optionalHeaderOffset + sizeOfOptionalHeader

        for i in 0..<numberOfSections {
            let off = sectionStart + i * 40
            guard off + 40 <= data.count else { break }
            let nameBytes = data[off..<(off + 8)]
            let name = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
            if name == ".bind" {
                return BindSectionInfo(
                    sectionHeaderOffset: off,
                    virtualAddress: readUInt32(data, at: off + 12),
                    virtualSize: readUInt32(data, at: off + 8),
                    rawDataOffset: readUInt32(data, at: off + 20),
                    rawDataSize: readUInt32(data, at: off + 16),
                    sectionIndex: i,
                    numberOfSections: numberOfSections,
                    coffHeaderOffset: coffOffset,
                    optionalHeaderOffset: optionalHeaderOffset,
                    is64Bit: is64
                )
            }
        }
        return nil
    }

    // MARK: - Native SteamStub v3.x Patcher (fallback)

    private func patchSteamStub(data: inout Data, bind: BindSectionInfo) throws {
        let epRVA = readUInt32(data, at: bind.optionalHeaderOffset + 16)
        let hdrOff = Int(bind.rawDataOffset) + (Int(epRVA) - Int(bind.virtualAddress))
        let rawEnd = Int(bind.rawDataOffset) + Int(bind.rawDataSize)
        guard hdrOff >= Int(bind.rawDataOffset), hdrOff + 0x54 <= rawEnd,
              hdrOff + 0x54 <= data.count else {
            throw SteamlessError.corruptHeader
        }

        let xorKey = readUInt32(data, at: hdrOff)
        let sigRaw = readUInt32(data, at: hdrOff + 4)
        let signature = sigRaw ^ xorKey
        guard signature == 0xC0DE_C0DE else {
            throw SteamlessError.unsupportedVariant
        }

        let oepOffset: Int
        let flagsOffset: Int
        let codeSectionVAOffset: Int
        let codeSectionSizeOffset: Int
        let xorKey2Offset: Int

        if bind.is64Bit {
            oepOffset = hdrOff + 0x1C
            flagsOffset = hdrOff + 0x34
            codeSectionVAOffset = hdrOff + 0x40
            codeSectionSizeOffset = hdrOff + 0x48
            xorKey2Offset = hdrOff + 0x50
        } else {
            oepOffset = hdrOff + 0x18
            flagsOffset = hdrOff + 0x30
            codeSectionVAOffset = hdrOff + 0x3C
            codeSectionSizeOffset = hdrOff + 0x40
            xorKey2Offset = hdrOff + 0x44
        }

        let oepEncrypted = readUInt32(data, at: oepOffset)
        let originalEntryPoint = oepEncrypted ^ xorKey
        guard originalEntryPoint != 0 else { throw SteamlessError.corruptHeader }

        let flagsEncrypted = readUInt32(data, at: flagsOffset)
        let flags = flagsEncrypted ^ xorKey
        let codeEncrypted = (flags & 1) != 0

        if codeEncrypted {
            try decryptCodeSection(
                data: &data, bind: bind,
                codeSectionVAOffset: codeSectionVAOffset,
                codeSectionSizeOffset: codeSectionSizeOffset,
                xorKey2Offset: xorKey2Offset,
                xorKey: xorKey
            )
        }

        let epOffset = bind.optionalHeaderOffset + 16
        writeUInt32(&data, at: epOffset, value: originalEntryPoint)

        let charOffset = bind.sectionHeaderOffset + 36
        writeUInt32(&data, at: charOffset, value: 0x0200_0000)
    }

    private func decryptCodeSection(
        data: inout Data, bind: BindSectionInfo,
        codeSectionVAOffset: Int, codeSectionSizeOffset: Int,
        xorKey2Offset: Int, xorKey: UInt32
    ) throws {
        let codeVA: UInt64
        let codeSize: UInt64
        if bind.is64Bit {
            codeVA = readUInt64(data, at: codeSectionVAOffset) ^ UInt64(xorKey)
            codeSize = readUInt64(data, at: codeSectionSizeOffset) ^ UInt64(xorKey)
        } else {
            codeVA = UInt64(readUInt32(data, at: codeSectionVAOffset) ^ xorKey)
            codeSize = UInt64(readUInt32(data, at: codeSectionSizeOffset) ^ xorKey)
        }

        let xorKey2 = readUInt32(data, at: xorKey2Offset) ^ xorKey
        guard codeSize > 0, codeSize < UInt64(data.count) else { return }

        let peOffset = Int(readUInt32(data, at: 0x3C))
        let coffOffset = peOffset + 4
        let numSections = Int(readUInt16(data, at: coffOffset + 2))
        let optHdrSize = Int(readUInt16(data, at: coffOffset + 16))
        let secStart = coffOffset + 20 + optHdrSize

        for i in 0..<numSections {
            let sh = secStart + i * 40
            guard sh + 40 <= data.count else { break }
            let secVA = readUInt32(data, at: sh + 12)
            if UInt64(secVA) == codeVA {
                let secRawOff = Int(readUInt32(data, at: sh + 20))
                let decryptLen = min(Int(codeSize), data.count - secRawOff)
                guard decryptLen > 0 else { break }

                var pos = secRawOff
                let end = secRawOff + decryptLen
                while pos + 4 <= end {
                    let val = readUInt32(data, at: pos) ^ xorKey2
                    writeUInt32(&data, at: pos, value: val)
                    pos += 4
                }
                break
            }
        }
    }

    // MARK: - Binary read/write helpers

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return UInt64(data[offset])
            | (UInt64(data[offset + 1]) << 8)
            | (UInt64(data[offset + 2]) << 16)
            | (UInt64(data[offset + 3]) << 24)
            | (UInt64(data[offset + 4]) << 32)
            | (UInt64(data[offset + 5]) << 40)
            | (UInt64(data[offset + 6]) << 48)
            | (UInt64(data[offset + 7]) << 56)
    }

    private func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        guard offset + 4 <= data.count else { return }
        data[offset]     = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
