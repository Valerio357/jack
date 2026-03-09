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
                return "No games found. Make sure your Steam library is set to public (Profile → Edit Profile → Privacy Settings → Game details: Public)."
            case .profilePrivate:
                return "Private Steam profile. Make your library public in Steam privacy settings."
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Owned games

    private static let skipPatterns = [
        " server", " dedicated server", "redistributable", "commonredist",
        "steamworks", "proton ", "steam linux runtime", "soundtrack", "art book"
    ]

    private static func isNonGame(_ name: String) -> Bool {
        let lower = name.lowercased()
        return skipPatterns.contains { lower.contains($0) }
    }

    /// Fetch owned games. Tries Steam XML profile (public), then SteamCMD, then local scan.
    public static func getOwnedGames(steamID64: String, username: String) async throws -> [SteamGame] {
        // 1. Steam public XML profile (no API key, no SteamCMD)
        if let xmlGames = try? await fetchGamesFromXML(steamID64: steamID64), !xmlGames.isEmpty {
            // Merge with locally installed games not in the XML list
            let xmlIDs = Set(xmlGames.map(\.appid))
            let localOnly = scanInstalledGames().filter { !xmlIDs.contains($0.appid) }
            if !localOnly.isEmpty {
                let nameMap = await resolveAppNames(appIDs: localOnly.map(\.appid))
                let resolved = localOnly.compactMap { g -> SteamGame? in
                    guard let name = nameMap[g.appid], !name.isEmpty, !isNonGame(name) else { return nil }
                    return SteamGame(appid: g.appid, name: name, playtimeForever: 0, imgIconUrl: nil)
                }
                return (xmlGames + resolved).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            return xmlGames
        }

        // 2. JackSteam licenses via CM network (works with private profiles)
        if SteamSessionManager.shared.isLoggedIn,
           let appIDs = try? await SteamNativeService.shared.getOwnedAppIDs(),
           !appIDs.isEmpty {
            let nameMap = await resolveAppNames(appIDs: appIDs)
            let games = appIDs.compactMap { id -> SteamGame? in
                guard let name = nameMap[id], !name.isEmpty, !isNonGame(name) else { return nil }
                return SteamGame(appid: id, name: name, playtimeForever: 0, imgIconUrl: nil)
            }
            if !games.isEmpty {
                // Merge with locally installed games
                let ownedIDs = Set(games.map(\.appid))
                let localOnly = scanInstalledGames().filter { !ownedIDs.contains($0.appid) }
                if !localOnly.isEmpty {
                    let localNames = await resolveAppNames(appIDs: localOnly.map(\.appid))
                    let resolved = localOnly.compactMap { g -> SteamGame? in
                        guard let name = localNames[g.appid], !name.isEmpty, !isNonGame(name) else { return nil }
                        return SteamGame(appid: g.appid, name: name, playtimeForever: 0, imgIconUrl: nil)
                    }
                    return (games + resolved).sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }
                return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        // 3. SteamCMD licenses_print (requires cached credentials)
        if SteamCMDService.shared.isInstalled,
           let appIDs = try? await SteamCMDService.shared.getOwnedAppIDs(username: username),
           !appIDs.isEmpty {
            let nameMap = await resolveAppNames(appIDs: appIDs)
            let games = appIDs.compactMap { id -> SteamGame? in
                guard let name = nameMap[id], !name.isEmpty, !isNonGame(name) else { return nil }
                return SteamGame(appid: id, name: name, playtimeForever: 0, imgIconUrl: nil)
            }
            if !games.isEmpty {
                return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        // 4. Scan locally installed games
        let local = scanInstalledGames()
        if !local.isEmpty {
            let nameMap = await resolveAppNames(appIDs: local.map(\.appid))
            let games = local.compactMap { g -> SteamGame? in
                let name = nameMap[g.appid] ?? g.name
                guard !name.isEmpty, name != "App \(g.appid)" || nameMap[g.appid] == nil else {
                    // Use "App {id}" only if Store API also failed
                    return SteamGame(appid: g.appid, name: nameMap[g.appid] ?? g.name, playtimeForever: 0, imgIconUrl: nil)
                }
                return SteamGame(appid: g.appid, name: name, playtimeForever: 0, imgIconUrl: nil)
            }
            return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        throw SteamAPIError.noGamesFound
    }

    /// Fetch games from Steam's public XML profile.
    private static func fetchGamesFromXML(steamID64: String) async throws -> [SteamGame] {
        let urlString = "https://steamcommunity.com/profiles/\(steamID64)/games?xml=1"
        guard let url = URL(string: urlString) else { return [] }

        let (data, _) = try await session.data(from: url)
        guard let xml = String(data: data, encoding: .utf8) else { return [] }

        if xml.contains("<privacyState>private</privacyState>") { return [] }
        guard xml.contains("<game>") else { return [] }

        var games: [SteamGame] = []
        for block in xml.components(separatedBy: "<game>").dropFirst() {
            guard let appIDStr = xmlValue(block, "appID"),
                  let appID = Int(appIDStr) else { continue }
            let rawName = xmlValue(block, "name") ?? ""
            let name = rawName
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
            guard !name.isEmpty, !isNonGame(name) else { continue }
            games.append(SteamGame(appid: appID, name: name, playtimeForever: 0, imgIconUrl: nil))
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func xmlValue(_ block: String, _ tag: String) -> String? {
        guard let s = block.range(of: "<\(tag)>"),
              let e = block.range(of: "</\(tag)>") else { return nil }
        return String(block[s.upperBound..<e.lowerBound])
    }

    /// Scan local SteamCMD/games/ for installed games.
    private static func scanInstalledGames() -> [SteamGame] {
        let gamesDir = BottleData.steamCMDDir.appending(path: "games")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: gamesDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.compactMap { dir in
            guard let appID = Int(dir.lastPathComponent),
                  SteamCMDService.findGameExecutable(in: dir) != nil else { return nil }
            return SteamGame(appid: appID, name: "App \(appID)", playtimeForever: 0, imgIconUrl: nil)
        }
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
