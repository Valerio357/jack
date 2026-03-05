//
//  SteamGame.swift
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

public struct SteamGame: Codable, Identifiable, Sendable {
    public let appid: Int
    public let name: String
    public let playtimeForever: Int
    public let imgIconUrl: String?

    public var id: Int { appid }

    enum CodingKeys: String, CodingKey {
        case appid
        case name
        case playtimeForever = "playtime_forever"
        case imgIconUrl = "img_icon_url"
    }

    // MARK: - Image URLs (Steam CDN)

    public var iconURL: URL? {
        guard let hash = imgIconUrl, !hash.isEmpty else { return nil }
        return URL(string: "https://media.steampowered.com/steamcommunity/public/images/apps/\(appid)/\(hash).jpg")
    }

    /// 460×215 landscape header art
    public var headerURL: URL? {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/header.jpg")
    }

    /// 600×900 portrait capsule — ideal for detail panel
    public var capsulePortraitURL: URL? {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg")
    }

    // MARK: - Helpers

    public var playtimeHours: Int { playtimeForever / 60 }
}
