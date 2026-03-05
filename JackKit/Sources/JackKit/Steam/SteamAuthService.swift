//
//  SteamAuthService.swift
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

import AppKit
import AuthenticationServices

@MainActor
public final class SteamAuthService: NSObject, ObservableObject {
    public static let shared = SteamAuthService()
    private var authSession: ASWebAuthenticationSession?

    public func login() async throws -> String {
        guard var components = URLComponents(string: "https://steamcommunity.com/openid/login") else {
            throw SteamAuthError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.return_to", value: "barrel://auth/callback"),
            URLQueryItem(name: "openid.realm", value: "barrel://"),
            URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select")
        ]
        guard let url = components.url else { throw SteamAuthError.invalidURL }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "barrel") { callbackURL, error in
                if let error = error {
                    let asError = error as? ASWebAuthenticationSessionError
                    if asError?.code == .canceledLogin {
                        continuation.resume(throwing: SteamAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL, let steamID = Self.extractSteamID(from: callbackURL) else {
                    continuation.resume(throwing: SteamAuthError.noSteamID)
                    return
                }
                continuation.resume(returning: steamID)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
    }

    private static func extractSteamID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let claimedID = components.queryItems?.first(where: { $0.name == "openid.claimed_id" })?.value,
              let claimedURL = URL(string: claimedID) else { return nil }
        return claimedURL.lastPathComponent
    }
}

extension SteamAuthService: ASWebAuthenticationPresentationContextProviding {
    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
}

public enum SteamAuthError: LocalizedError, Sendable {
    case invalidURL, noSteamID, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Steam login URL"
        case .noSteamID: return "Could not extract Steam ID from callback"
        case .cancelled: return "Login was cancelled"
        }
    }
}
