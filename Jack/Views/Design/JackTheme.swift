//
//  JackTheme.swift
//  Jack
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

import SwiftUI
import JackKit

// MARK: - Colour palette

extension Color {
    /// #0D1B2A — primary dark navy background
    static let jackBackground = Color(red: 0.051, green: 0.106, blue: 0.165)
    /// #4A90D9 — electric blue accent
    static let jackAccent = Color(red: 0.290, green: 0.565, blue: 0.851)
    /// #FFFFFF with 8 % opacity — card surface
    static let jackCard = Color.white.opacity(0.08)
    /// #FFFFFF with 12 % opacity — hovered card surface
    static let jackCardHover = Color.white.opacity(0.13)
    /// #FFFFFF with 15 % opacity — card border
    static let jackCardBorder = Color.white.opacity(0.12)
    /// #4CAF50 — success / platinum+gold
    static let jackSuccess = Color(red: 0.298, green: 0.686, blue: 0.314)
    /// #FF9800 — warning / silver+bronze
    static let jackWarning = Color(red: 1.000, green: 0.596, blue: 0.000)
    /// #F44336 — error / borked
    static let jackError = Color(red: 0.957, green: 0.263, blue: 0.212)
}

// MARK: - Typography helpers

extension Font {
    static let jackTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let jackHeadline = Font.system(.headline, design: .default, weight: .semibold)
    static let jackBody = Font.system(.body, design: .default)
    static let jackCaption = Font.system(.caption, design: .default)
}

// MARK: - Compatibility colour helpers

extension CompatibilityTier {
    var jackColor: Color {
        switch self {
        case .platinum: return .jackAccent
        case .gold: return .jackSuccess
        case .silver: return Color(red: 0.8, green: 0.8, blue: 0.85)
        case .bronze: return .jackWarning
        case .borked: return .jackError
        case .unknown: return .secondary
        }
    }

    var isPlayable: Bool {
        switch self {
        case .platinum, .gold: return true
        default: return false
        }
    }
}
