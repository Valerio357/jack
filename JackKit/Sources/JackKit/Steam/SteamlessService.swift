//
//  SteamlessService.swift
//  JackKit
//
//  Native SteamStub DRM stripper — removes the SteamStub wrapper from game
//  executables directly via PE manipulation.  No Wine or .NET dependency.
//
//  SteamStub adds a ".bind" section to the PE that runs before the real entry
//  point, checks for a running Steam client, and optionally encrypts the
//  original code section.  Goldberg replaces steam_api.dll but can't help if
//  the stub itself blocks launch.  This service patches the PE entry point
//  back to the original and decrypts the code section when needed.
//
//  Supports SteamStub variant 3.x (32-bit and 64-bit).
//

import Foundation

public enum SteamlessError: LocalizedError {
    case notSteamStub
    case unsupportedVariant
    case corruptHeader
    case unpackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSteamStub:        return "No SteamStub DRM detected."
        case .unsupportedVariant:  return "Unsupported SteamStub variant."
        case .corruptHeader:       return "Corrupt SteamStub header."
        case .unpackFailed(let d): return "SteamStub strip failed: \(d)"
        }
    }
}

public final class SteamlessService: @unchecked Sendable {
    public static let shared = SteamlessService()
    private init() {}

    // MARK: - Public API

    /// Strips SteamStub DRM from a game executable (native PE patching).
    /// Backs up the original as `.steamstub_backup`.  Skips if already stripped
    /// or if no SteamStub is detected.
    @discardableResult
    public func stripIfNeeded(exe: URL) async throws -> URL {
        let fm = FileManager.default
        let backupURL = backupURL(for: exe)

        // Already stripped in a previous run
        if fm.fileExists(atPath: backupURL.path(percentEncoded: false)) {
            return exe
        }

        guard var data = try? Data(contentsOf: exe, options: []) else {
            return exe
        }

        // Locate .bind section
        guard let bindInfo = findBindSection(in: data) else {
            return exe // No SteamStub
        }

        // Parse stub header and patch — skip silently if variant is unrecognized
        // (Goldberg's fake steam_api should still satisfy the stub's API calls)
        do {
            try patchSteamStub(data: &data, bind: bindInfo)
        } catch SteamlessError.unsupportedVariant {
            return exe
        }

        // Write patched exe: backup original first
        try fm.copyItem(at: exe, to: backupURL)
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

    // MARK: - Internals

    private func backupURL(for exe: URL) -> URL {
        exe.deletingLastPathComponent()
            .appending(path: exe.lastPathComponent + ".steamstub_backup")
    }

    // MARK: - PE Parsing Helpers

    private struct BindSectionInfo {
        let sectionHeaderOffset: Int   // offset of the .bind section header in file
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
        // MZ
        guard data[0] == 0x4D, data[1] == 0x5A else { return nil }
        // PE offset
        let peOffset = readUInt32(data, at: 0x3C)
        guard peOffset > 0, Int(peOffset) + 4 < data.count else { return nil }
        // PE\0\0
        guard data[Int(peOffset)] == 0x50, data[Int(peOffset) + 1] == 0x45,
              data[Int(peOffset) + 2] == 0x00, data[Int(peOffset) + 3] == 0x00 else { return nil }

        let coffOffset = Int(peOffset) + 4
        guard coffOffset + 20 <= data.count else { return nil }

        let numberOfSections = Int(readUInt16(data, at: coffOffset + 2))
        let sizeOfOptionalHeader = Int(readUInt16(data, at: coffOffset + 16))
        let optionalHeaderOffset = coffOffset + 20

        // Determine PE32 vs PE32+
        guard optionalHeaderOffset + 2 <= data.count else { return nil }
        let magic = readUInt16(data, at: optionalHeaderOffset)
        let is64 = magic == 0x020B // PE32+ = 64-bit

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

    // MARK: - SteamStub v3.x Header

    // The .bind section raw data starts with the stub header.
    // First 4 bytes = XorKey.  Bytes 4..8 XOR'd with XorKey = signature.
    //
    // Variant 3.1 64-bit header layout (fields after XOR decryption):
    //   0x00  UInt32  XorKey
    //   0x04  UInt32  Signature          (0xC0DEC0DE)
    //   0x08  UInt64  ImageBase
    //   0x10  UInt32  AddressOfEntryPoint (stub EP)
    //   0x14  UInt32  BindSectionOffset
    //   0x18  UInt32  Unknown0
    //   0x1C  UInt32  OriginalEntryPoint  <-- what we need
    //   0x20  UInt32  Unknown1
    //   0x24  UInt32  PayloadSize
    //   0x28  UInt32  DRMPDllOffset
    //   0x2C  UInt32  DRMPDllSize
    //   0x30  UInt32  SteamAppId
    //   0x34  UInt32  Flags               bit 0 = code encrypted
    //   0x38  UInt32  BindSectionVirtualSize
    //   0x3C  UInt32  Unknown2
    //   0x40  UInt64  CodeSectionVirtualAddress
    //   0x48  UInt64  CodeSectionRawSize
    //   0x50  UInt32  XorKey2             (for code decryption)
    //
    // Variant 3.1 32-bit: same layout but ImageBase is UInt32 (4 bytes),
    //   so OEP shifts to 0x18, Flags to 0x30, etc.
    //
    // Variant 3.0: similar but slightly different offsets.  We detect by
    //   checking if the signature matches at the expected position.

    private func patchSteamStub(data: inout Data, bind: BindSectionInfo) throws {
        // The SteamStub header is at the PE entry point file offset (NOT at
        // the start of .bind — the section begins with stub code/data).
        let epRVA = readUInt32(data, at: bind.optionalHeaderOffset + 16)
        let hdrOff = Int(bind.rawDataOffset) + (Int(epRVA) - Int(bind.virtualAddress))
        let rawEnd = Int(bind.rawDataOffset) + Int(bind.rawDataSize)
        guard hdrOff >= Int(bind.rawDataOffset), hdrOff + 0x54 <= rawEnd,
              hdrOff + 0x54 <= data.count else {
            throw SteamlessError.corruptHeader
        }

        // Read XorKey (first 4 bytes at EP, NOT XOR'd)
        let xorKey = readUInt32(data, at: hdrOff)

        // Verify signature at offset 4
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
            // 64-bit: ImageBase is UInt64 at 0x08 (8 bytes)
            oepOffset = hdrOff + 0x1C
            flagsOffset = hdrOff + 0x34
            codeSectionVAOffset = hdrOff + 0x40
            codeSectionSizeOffset = hdrOff + 0x48
            xorKey2Offset = hdrOff + 0x50
        } else {
            // 32-bit: ImageBase is UInt32 at 0x08 (4 bytes), shifts everything by -4
            oepOffset = hdrOff + 0x18
            flagsOffset = hdrOff + 0x30
            codeSectionVAOffset = hdrOff + 0x3C
            codeSectionSizeOffset = hdrOff + 0x40
            xorKey2Offset = hdrOff + 0x44
        }

        // Decrypt OEP
        let oepEncrypted = readUInt32(data, at: oepOffset)
        let originalEntryPoint = oepEncrypted ^ xorKey

        guard originalEntryPoint != 0 else {
            throw SteamlessError.corruptHeader
        }

        // Read flags
        let flagsEncrypted = readUInt32(data, at: flagsOffset)
        let flags = flagsEncrypted ^ xorKey
        let codeEncrypted = (flags & 1) != 0

        // Decrypt code section if needed
        if codeEncrypted {
            try decryptCodeSection(
                data: &data, bind: bind,
                codeSectionVAOffset: codeSectionVAOffset,
                codeSectionSizeOffset: codeSectionSizeOffset,
                xorKey2Offset: xorKey2Offset,
                xorKey: xorKey
            )
        }

        // Patch PE AddressOfEntryPoint in optional header
        // For PE32: offset 0x10 from start of optional header (16)
        // For PE32+: same offset 0x10 (16)
        let epOffset = bind.optionalHeaderOffset + 16
        writeUInt32(&data, at: epOffset, value: originalEntryPoint)

        // Zero out the .bind section characteristics (mark it as discardable/unused)
        // Section characteristics is at offset 36 in the section header
        let charOffset = bind.sectionHeaderOffset + 36
        writeUInt32(&data, at: charOffset, value: 0x0200_0000) // IMAGE_SCN_MEM_DISCARDABLE
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

        // Find the file offset of the code section by matching its VA
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

                // XOR decrypt in 4-byte blocks
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
