//
//  BottleData.swift
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
import SemanticVersion

public struct BottleData: Codable {
    private static let defaultContainerDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library")
        .appending(path: "Containers")
        .appending(path: Bundle.jackBundleIdentifier)

    /// The root directory for all Jack data. Configurable via Settings.
    public static var containerDir: URL {
        if let custom = UserDefaults.standard.url(forKey: "jackDataLocation") {
            return custom
        }
        return defaultContainerDir
    }

    /// Set a custom root directory for all Jack data, or `nil` to restore the default.
    /// Migrates stored bottle paths from the old container to the new one.
    public static func setCustomDataLocation(_ url: URL?) {
        let oldContainer = containerDir

        if let url {
            UserDefaults.standard.set(url, forKey: "jackDataLocation")
        } else {
            UserDefaults.standard.removeObject(forKey: "jackDataLocation")
        }

        let newContainer = containerDir
        guard oldContainer != newContainer else { return }

        // Migrate bottle paths in the plist from old container to new container
        var data = BottleData()
        let oldPrefix = oldContainer.path(percentEncoded: false)
        let newPrefix = newContainer.path(percentEncoded: false)
        var changed = false

        data.paths = data.paths.map { path in
            let pathStr = path.path(percentEncoded: false)
            if pathStr.hasPrefix(oldPrefix) {
                let relative = String(pathStr.dropFirst(oldPrefix.count))
                changed = true
                return newContainer.appending(path: relative)
            }
            return path
        }

        if changed {
            data.encode()
        }
    }

    public static var bottleEntriesDir: URL {
        containerDir
            .appending(path: "BottleVM")
            .appendingPathExtension("plist")
    }

    public static var defaultBottleDir: URL {
        containerDir.appending(path: "Bottles")
    }

    public static var sharedDir: URL {
        containerDir.appending(path: "Shared")
    }

    /// Path to Steam installation inside the Shared bottle
    public static var steamDir: URL {
        sharedDir
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
    }

    /// Path to native macOS SteamCMD installation
    public static var steamCMDDir: URL {
        containerDir.appending(path: "SteamCMD")
    }

    /// Path to installed games (steamapps/common)
    public static var steamAppsDir: URL {
        steamDir
            .appending(path: "steamapps")
            .appending(path: "common")
    }

    static let currentVersion = SemanticVersion(1, 0, 0)

    private var fileVersion: SemanticVersion
    public var paths: [URL] = [] {
        didSet {
            encode()
        }
    }

    public init() {
        fileVersion = Self.currentVersion

        if !decode() {
            encode()
        }
    }

    public mutating func loadBottles() -> [Bottle] {
        var bottles: [Bottle] = []

        for path in paths {
            let bottleMetadata = path
                .appending(path: "Metadata")
                .appendingPathExtension("plist")
                .path(percentEncoded: false)

            if FileManager.default.fileExists(atPath: bottleMetadata) {
                bottles.append(Bottle(bottleUrl: path, isAvailable: true))
            } else {
                bottles.append(Bottle(bottleUrl: path))
            }
        }

        return bottles
    }

    @discardableResult
    private mutating func decode() -> Bool {
        let decoder = PropertyListDecoder()
        do {
            let data = try Data(contentsOf: Self.bottleEntriesDir)
            self = try decoder.decode(BottleData.self, from: data)
            if self.fileVersion != Self.currentVersion {
                print("Invalid file version \(self.fileVersion)")
                return false
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func encode() -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            try FileManager.default.createDirectory(at: Self.containerDir, withIntermediateDirectories: true)
            let data = try encoder.encode(self)
            try data.write(to: Self.bottleEntriesDir)
            return true
        } catch {
            return false
        }
    }
}
