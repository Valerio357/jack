//
//  SteamAPIClient.swift
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

public struct SteamAPIClient: Sendable {

    public enum SteamAPIError: LocalizedError {
        case noGamesFound
        case profilePrivate

        public var errorDescription: String? {
            switch self {
            case .noGamesFound:
                return "Nessun gioco trovato. Assicurati che la tua libreria Steam sia pubblica (Profilo → Modifica profilo → Impostazioni privacy → Dettagli gioco: Pubblico)."
            case .profilePrivate:
                return "Profilo Steam privato. Rendi pubblica la tua libreria nelle impostazioni privacy di Steam."
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Owned games (no API key needed)

    /// Fetch owned games using SteamCMD licenses_print + Steam Store for names.
    public static func getOwnedGames(steamID64: String, username: String) async throws -> [SteamGame] {
        // Get owned app IDs from SteamCMD
        let appIDs = try await SteamCMDService.shared.getOwnedAppIDs(username: username)
        guard !appIDs.isEmpty else {
            throw SteamAPIError.noGamesFound
        }

        // Resolve names via Steam Store API (cached to disk)
        let nameMap = await resolveAppNames(appIDs: appIDs)

        var games: [SteamGame] = []
        for appID in appIDs {
            let name = nameMap[appID] ?? ""
            // Skip obvious non-games
            if !name.isEmpty {
                let lower = name.lowercased()
                if lower.hasSuffix(" server") || lower.hasSuffix(" dedicated server")
                    || lower.contains("redistributable") || lower.contains("commonredist")
                    || lower.hasPrefix("steamworks") || lower.contains("proton ")
                    || lower.contains("steam linux runtime")
                    || lower.contains("soundtrack") || lower.contains("art book") {
                    continue
                }
            } else {
                continue // Skip unknown apps (likely tools/DLCs)
            }
            games.append(SteamGame(
                appid: appID,
                name: name,
                playtimeForever: 0,
                imgIconUrl: nil
            ))
        }

        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - App Name Resolution (via Steam Store API, cached to disk)

    /// Disk cache for resolved app names: { "appid": "name", ... }
    private static var nameCacheURL: URL {
        BottleData.steamCMDDir.appending(path: "app_names_cache.json")
    }

    /// Load cached names from disk.
    private static func loadNameCache() -> [Int: String] {
        guard let data = try? Data(contentsOf: nameCacheURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        var map: [Int: String] = [:]
        for (key, value) in dict {
            if let id = Int(key) { map[id] = value }
        }
        return map
    }

    /// Save names cache to disk.
    private static func saveNameCache(_ map: [Int: String]) {
        var dict: [String: String] = [:]
        for (key, value) in map { dict["\(key)"] = value }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: nameCacheURL, options: .atomic)
        }
    }

    /// Resolve app names for given IDs using disk cache + Steam Store API.
    private static func resolveAppNames(appIDs: [Int]) async -> [Int: String] {
        var nameMap = loadNameCache()

        // Find IDs that need resolving
        let missing = appIDs.filter { nameMap[$0] == nil }
        guard !missing.isEmpty else { return nameMap }

        // Fetch names in parallel batches (5 concurrent requests, store API rate limit ~200/5min)
        let batchSize = 5
        for batchStart in stride(from: 0, to: missing.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, missing.count)
            let batch = Array(missing[batchStart..<batchEnd])

            await withTaskGroup(of: (Int, String?).self) { group in
                for appID in batch {
                    group.addTask {
                        let name = await fetchAppName(appID: appID)
                        return (appID, name)
                    }
                }
                for await (appID, name) in group {
                    if let name, !name.isEmpty {
                        nameMap[appID] = name
                    } else {
                        // Mark as resolved (empty) so we don't re-fetch
                        nameMap[appID] = ""
                    }
                }
            }

            // Small delay between batches to respect rate limits
            if batchEnd < missing.count {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        saveNameCache(nameMap)
        return nameMap
    }

    /// Fetch a single app's name from the Steam Store API.
    private static func fetchAppName(appID: Int) async -> String? {
        let urlString = "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english&filters=basic"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let appData = json["\(appID)"] as? [String: Any],
                  (appData["success"] as? Bool) == true,
                  let dataDict = appData["data"] as? [String: Any],
                  let name = dataDict["name"] as? String else { return nil }
            return name
        } catch {
            return nil
        }
    }

    // MARK: - Game Size (from Steam Store API, no key needed)

    public static func getGameSizeGB(appID: Int) async -> Double? {
        let urlString = "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let appData = json["\(appID)"] as? [String: Any],
                  (appData["success"] as? Bool) == true,
                  let dataDict = appData["data"] as? [String: Any] else { return nil }

            for key in ["pc_requirements", "mac_requirements", "linux_requirements"] {
                if let req = dataDict[key] as? [String: Any] {
                    for field in ["minimum", "recommended"] {
                        if let html = req[field] as? String,
                           let size = parseSizeGB(from: html) {
                            return size
                        }
                    }
                }
            }
        } catch { }
        return nil
    }

    private static func parseSizeGB(from html: String) -> Double? {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let ns = text as NSString

        let patterns: [(String, Bool)] = [
            (#"(?:Storage|Spazio|Space|HDD|SSD|Disk)\s*:?\s*(\d+[,.]?\d*)\s*GB"#, true),
            (#"(\d+[,.]?\d*)\s*GB\s+(?:available|liberi|free|di spazio)"#, true),
            (#"(\d+[,.]?\d*)\s*GB"#, true),
            (#"(?:Storage|Space|Disk)\s*:?\s*(\d+)\s*MB"#, false),
            (#"(\d+)\s*MB\s+(?:available|liberi|free)"#, false),
        ]

        for (pattern, isGB) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1 else { continue }
            let captureRange = match.range(at: 1)
            guard captureRange.location != NSNotFound else { continue }
            let numStr = ns.substring(with: captureRange).replacingOccurrences(of: ",", with: ".")
            guard let num = Double(numStr), num > 0 else { continue }
            return isGB ? num : num / 1024.0
        }
        return nil
    }
}
