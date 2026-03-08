//
//  SteamSessionManager.swift
//  JackKit
//
//  Manages the persistent native Steam session.
//  Stores refresh_token in Keychain, access_token in memory.
//  Handles token refresh and session lifecycle.
//
//  This file is part of Jack.
//
//  Jack is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//

import Foundation
import Security
import os.log

public final class SteamSessionManager: @unchecked Sendable {
    public static let shared = SteamSessionManager()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamSession")
    private static let keychainService = "com.isaacmarovitz.Jack.SteamSession"
    private static let keychainAccount = "refreshToken"

    // In-memory state
    private(set) public var steamID64: String = ""
    private(set) public var accountName: String = ""
    private(set) public var accessToken: String = ""
    private var refreshToken: String = ""

    public var isLoggedIn: Bool { !steamID64.isEmpty && !refreshToken.isEmpty }

    private init() {
        loadSession()
    }

    // MARK: - Session persistence

    /// Save session after successful login.
    public func saveSession(result: SteamLoginResult) {
        self.steamID64 = result.steamID64
        self.accountName = result.accountName
        self.accessToken = result.accessToken
        self.refreshToken = result.refreshToken

        // Store in UserDefaults (non-sensitive)
        UserDefaults.standard.set(result.steamID64, forKey: "steamUserID")
        UserDefaults.standard.set(result.accountName, forKey: "steamUsername")

        // Store refresh token in Keychain
        saveToKeychain(result.refreshToken)

        Self.log.info("Session saved for \(result.accountName) (\(result.steamID64))")
    }

    /// Load session from persistent storage.
    private func loadSession() {
        steamID64 = UserDefaults.standard.string(forKey: "steamUserID") ?? ""
        accountName = UserDefaults.standard.string(forKey: "steamUsername") ?? ""
        refreshToken = loadFromKeychain() ?? ""

        if !refreshToken.isEmpty {
            // Decode steamID from refresh token if not stored
            if steamID64.isEmpty, let sid = Self.extractSteamID(from: refreshToken) {
                steamID64 = sid
            }
            Self.log.info("Session loaded for \(self.accountName) (\(self.steamID64))")
        }
    }

    /// Clear session (logout).
    public func logout() {
        steamID64 = ""
        accountName = ""
        accessToken = ""
        refreshToken = ""

        UserDefaults.standard.removeObject(forKey: "steamUserID")
        UserDefaults.standard.removeObject(forKey: "steamUsername")
        deleteFromKeychain()

        Self.log.info("Session cleared")
    }

    // MARK: - Token refresh

    /// Refresh the access token using the stored refresh token.
    /// Called before operations that need a valid access token.
    public func refreshAccessToken() async throws {
        guard !refreshToken.isEmpty else {
            throw SteamSessionError.noSession
        }

        var request = URLRequest(
            url: URL(string: "https://api.steampowered.com/IAuthenticationService/GenerateAccessTokenForApp/v1")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "refresh_token=\(refreshToken)&steamid=\(steamID64)"
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let resp = try JSONDecoder().decode(RefreshResponse.self, from: data)

        if let token = resp.response?.access_token, !token.isEmpty {
            self.accessToken = token
            Self.log.info("Access token refreshed")
        } else {
            // Refresh token expired — user needs to login again
            logout()
            throw SteamSessionError.sessionExpired
        }
    }

    /// Get a valid access token, refreshing if needed.
    public func getAccessToken() async throws -> String {
        if !accessToken.isEmpty {
            // Check if JWT is still valid (not expired)
            if !isTokenExpired(accessToken) {
                return accessToken
            }
        }
        try await refreshAccessToken()
        return accessToken
    }

    private func isTokenExpired(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return true }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload += "=" }
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return true }
        return Date().timeIntervalSince1970 > exp - 60 // 1 min buffer
    }

    // MARK: - JWT decode

    /// Extract SteamID64 from a JWT token's `sub` claim.
    private static func extractSteamID(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload += "=" }
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              sub.hasPrefix("7656119") else { return nil }
        return sub
    }

    // MARK: - Keychain helpers

    private func saveToKeychain(_ value: String) {
        deleteFromKeychain()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecValueData: value.data(using: .utf8)!,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Types

    private struct RefreshResponse: Decodable {
        let response: RefreshInner?
    }
    private struct RefreshInner: Decodable {
        let access_token: String?
    }

    public enum SteamSessionError: LocalizedError {
        case noSession
        case sessionExpired

        public var errorDescription: String? {
            switch self {
            case .noSession: return "Not logged in to Steam"
            case .sessionExpired: return "Steam session expired. Please log in again."
            }
        }
    }
}
