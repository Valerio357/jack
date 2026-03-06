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
    private struct Response: Codable, Sendable {
        let response: GamesResponse
    }

    private struct GamesResponse: Codable, Sendable {
        let gameCount: Int?
        let games: [SteamGame]?

        enum CodingKeys: String, CodingKey {
            case gameCount = "game_count"
            case games
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"]
        return URLSession(configuration: config)
    }()

    public static func getOwnedGames(steamID: String, apiKey: String) async throws -> [SteamGame] {
        guard var components = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.response.games ?? []
    }

    /// Fetch game size from Steam Store API. Returns GB.
    public static func getGameSizeGB(appID: Int) async -> Double? {
        let urlString = "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=pc_requirements,mac_requirements&l=english"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let appData = json["\(appID)"] as? [String: Any],
                  (appData["success"] as? Bool) == true,
                  let dataDict = appData["data"] as? [String: Any] else { return nil }

            for key in ["pc_requirements", "mac_requirements"] {
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

        // (pattern, isGB) — capture group 1 = the number
        let patterns: [(String, Bool)] = [
            (#"(?:Storage|Spazio|Space|HDD|SSD)\s*:\s*(\d+[,.]?\d*)\s*GB"#, true),
            (#"(\d+[,.]?\d*)\s*GB\s+(?:available|liberi|free|di spazio)"#, true),
            (#"(\d+[,.]?\d*)\s*GB"#, true),
            (#"(?:Storage|Space)\s*:\s*(\d+)\s*MB"#, false),
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
