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

    /// Best effort to get game size in GB from Steam Store API
    public static func getGameSizeGB(appID: Int) async -> Double? {
        // Use the storefront API with English to have consistent parsing
        let urlString = "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=requirements&l=english"
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            guard let appData = json?["\(appID)"] as? [String: Any],
                  let success = appData["success"] as? Bool, success,
                  let dataDict = appData["data"] as? [String: Any] else {
                return nil
            }
            
            // Try to find it in pc_requirements
            if let pcReq = dataDict["pc_requirements"] as? [String: Any],
               let minimum = pcReq["minimum"] as? String {
                if let size = parseSizeFromRequirements(minimum) {
                    return size
                }
            }
            
            // Try mac_requirements as fallback
            if let macReq = dataDict["mac_requirements"] as? [String: Any],
               let minimum = macReq["minimum"] as? String {
                if let size = parseSizeFromRequirements(minimum) {
                    return size
                }
            }
            
        } catch {
            print("DEBUG: Failed to fetch game size for \(appID): \(error)")
        }
        return nil
    }
    
    private static func parseSizeFromRequirements(_ html: String) -> Double? {
        // Clean HTML tags
        let cleanText = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        
        // Look for "XX GB" but specifically after "Storage" or "Space"
        // Patterns: "70 GB available space", "Storage: 70 GB", etc.
        let patterns = [
            #"(\d+)\s*GB\s*available"#,
            #"Storage:\s*(\d+)\s*GB"#,
            #"Space:\s*(\d+)\s*GB"#,
            #"(\d+)\s*GB"#
        ]
        
        let nsString = cleanText as NSString
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                if let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: nsString.length)) {
                    if let size = Double(nsString.substring(with: match.range(at: 1))) {
                        // Sanity check: disk space is usually > 1GB for modern games, 
                        // but let's just return the first match that looks like a disk requirement
                        if size > 1 {
                            return size
                        }
                    }
                }
            }
        }
        return nil
    }
}
