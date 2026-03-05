//
//  ProtonDBClient.swift
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

public enum CompatibilityTier: String, Codable, Sendable {
    case platinum
    case gold
    case silver
    case bronze
    case borked
    case unknown

    public var displayName: String {
        switch self {
        case .platinum: return "Platinum"
        case .gold: return "Gold"
        case .silver: return "Silver"
        case .bronze: return "Bronze"
        case .borked: return "Borked"
        case .unknown: return "Unknown"
        }
    }
}

public struct ProtonDBSummary: Sendable {
    public let tier: CompatibilityTier
    public let totalReports: Int
    public let score: Double
    public var stars: Double { (score * 4) + 1 }
    public static let unknown = ProtonDBSummary(tier: .unknown, totalReports: 0, score: 0)
}

public struct ProtonDBClient: Sendable {
    private struct RawSummary: Codable, Sendable {
        let tier: String?
        let total: Int?
        let score: Double?
    }

    public static func summary(for appID: Int) async -> ProtonDBSummary {
        guard let url = URL(string: "https://www.protondb.com/api/v1/reports/summaries/\(appID).json") else {
            return .unknown
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = try JSONDecoder().decode(RawSummary.self, from: data)
            let tier = CompatibilityTier(rawValue: raw.tier ?? "") ?? .unknown
            return ProtonDBSummary(tier: tier, totalReports: raw.total ?? 0, score: raw.score ?? 0)
        } catch {
            return .unknown
        }
    }

    public static func compatibility(for appID: Int) async -> CompatibilityTier {
        await summary(for: appID).tier
    }
}
