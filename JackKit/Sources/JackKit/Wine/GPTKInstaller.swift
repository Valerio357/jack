//
//  GPTKInstaller.swift
//  JackKit
//
//  Manages installation of Apple's Game Porting Toolkit (GPTK).
//  Downloads GPTK from GitHub (Gcenx builds) and installs it alongside CrossOver Wine.
//

import Foundation
import os.log

public final class GPTKInstaller: @unchecked Sendable {
    public static let shared = GPTKInstaller()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "GPTK")

    /// GPTK release info
    private static let releaseAPI = "https://api.github.com/repos/Gcenx/game-porting-toolkit/releases/latest"

    /// Where GPTK Wine is installed
    public static var gptkDir: URL {
        JackWineInstaller.applicationFolder.appending(path: "GPTK")
    }

    /// GPTK wine64 binary
    public static var wineBinary: URL {
        gptkDir.appending(path: "wine/bin/wine64")
    }

    /// GPTK wineserver binary
    public static var wineserverBinary: URL {
        gptkDir.appending(path: "wine/bin/wineserver")
    }

    /// GPTK Wine lib directory (contains D3DMetal.framework, external libs)
    public static var wineLibDir: URL {
        gptkDir.appending(path: "wine/lib")
    }

    /// GPTK external libs (D3DMetal.framework, libd3dshared.dylib)
    public static var externalDir: URL {
        wineLibDir.appending(path: "external")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.wineBinary.path(percentEncoded: false))
    }

    private init() {}

    /// Download and install the latest GPTK release.
    public func install(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        let fm = FileManager.default

        // 1. Get download URL from GitHub API
        onProgress?("Fetching GPTK release info...")
        let downloadURL = try await fetchDownloadURL()

        // 2. Download the tarball
        onProgress?("Downloading GPTK (this may take a few minutes)...")
        let tempFile = fm.temporaryDirectory.appending(path: "gptk-download.tar.xz")
        if fm.fileExists(atPath: tempFile.path(percentEncoded: false)) {
            try? fm.removeItem(at: tempFile)
        }

        let (localURL, _) = try await URLSession.shared.download(from: URL(string: downloadURL)!)
        try fm.moveItem(at: localURL, to: tempFile)

        // 3. Extract to temp location
        onProgress?("Extracting GPTK...")
        let extractDir = fm.temporaryDirectory.appending(path: "gptk-extract")
        if fm.fileExists(atPath: extractDir.path(percentEncoded: false)) {
            try? fm.removeItem(at: extractDir)
        }
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", tempFile.path(percentEncoded: false), "-C", extractDir.path(percentEncoded: false)]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw GPTKError.extractionFailed
        }

        // 4. Find the Wine directory inside the extracted app bundle
        let resourcesDir = extractDir.appending(path: "Game Porting Toolkit.app/Contents/Resources")
        let wineDir = resourcesDir.appending(path: "wine")
        guard fm.fileExists(atPath: wineDir.appending(path: "bin/wine64").path(percentEncoded: false)) else {
            Self.log.error("GPTK wine64 not found at expected path: \(wineDir.path(percentEncoded: false))")
            throw GPTKError.invalidArchive
        }

        // 5. Install to GPTK directory
        onProgress?("Installing GPTK...")
        let destDir = Self.gptkDir
        if fm.fileExists(atPath: destDir.path(percentEncoded: false)) {
            try fm.removeItem(at: destDir)
        }
        let parentDir = destDir.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path(percentEncoded: false)) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try fm.copyItem(at: resourcesDir, to: destDir)

        // 6. Make wine binaries executable
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "+x",
                           destDir.appending(path: "wine/bin").path(percentEncoded: false)]
        try chmod.run()
        chmod.waitUntilExit()

        // 7. Verify installation
        guard fm.fileExists(atPath: Self.wineBinary.path(percentEncoded: false)) else {
            Self.log.error("GPTK install verification failed: wine64 not at \(Self.wineBinary.path(percentEncoded: false))")
            throw GPTKError.invalidArchive
        }

        // 8. Cleanup
        try? fm.removeItem(at: tempFile)
        try? fm.removeItem(at: extractDir)

        Self.log.info("GPTK installed at \(destDir.path(percentEncoded: false))")
        onProgress?("GPTK installed successfully!")
    }

    public func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.gptkDir.path(percentEncoded: false)) {
            try fm.removeItem(at: Self.gptkDir)
        }
        Self.log.info("GPTK uninstalled")
    }

    /// Fetch the latest release download URL from GitHub.
    private func fetchDownloadURL() async throws -> String {
        let url = URL(string: Self.releaseAPI)!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let first = assets.first,
              let downloadURL = first["browser_download_url"] as? String else {
            throw GPTKError.noRelease
        }

        return downloadURL
    }

    // MARK: - Errors

    public enum GPTKError: LocalizedError {
        case noRelease
        case extractionFailed
        case invalidArchive

        public var errorDescription: String? {
            switch self {
            case .noRelease: return "Could not find GPTK release on GitHub"
            case .extractionFailed: return "Failed to extract GPTK archive"
            case .invalidArchive: return "GPTK archive has unexpected structure"
            }
        }
    }
}
