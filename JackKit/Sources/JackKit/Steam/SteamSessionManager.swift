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
    private static let keychainPasswordAccount = "steamPassword"

    // In-memory state
    private(set) public var steamID64: String = ""
    private(set) public var accountName: String = ""
    private(set) public var accessToken: String = ""
    private(set) public var refreshToken: String = ""

    public var isLoggedIn: Bool { !steamID64.isEmpty }

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
        UserDefaults.standard.set(result.accessToken, forKey: "steamAccessToken")

        // Store refresh token in Keychain
        saveToKeychain(result.refreshToken)

        Self.log.info("Session saved for \(result.accountName) (\(result.steamID64))")
    }

    /// Load session from persistent storage.
    private func loadSession() {
        steamID64 = UserDefaults.standard.string(forKey: "steamUserID") ?? ""
        accountName = UserDefaults.standard.string(forKey: "steamUsername") ?? ""
        accessToken = UserDefaults.standard.string(forKey: "steamAccessToken") ?? ""
        refreshToken = loadFromKeychain() ?? ""

        // Fallback: load from jacksteam session.json if Keychain is empty
        if refreshToken.isEmpty {
            loadFromSessionJSON()
        }

        if !refreshToken.isEmpty {
            // Decode steamID from refresh token if not stored
            if steamID64.isEmpty, let sid = Self.extractSteamID(from: refreshToken) {
                steamID64 = sid
                UserDefaults.standard.set(sid, forKey: "steamUserID")
            }
            Self.log.info("Session loaded for \(self.accountName) (\(self.steamID64))")
        }
    }

    /// Try loading session from jacksteam.py's session.json file.
    private func loadFromSessionJSON() {
        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.isaacmarovitz.Jack/SteamSession")
        let sessionFile = sessionDir.appending(path: "session.json")

        guard let data = try? Data(contentsOf: sessionFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let rt = json["refreshToken"] as? String ?? ""
        guard !rt.isEmpty else { return }

        Self.log.info("Loading session from jacksteam session.json")
        refreshToken = rt
        saveToKeychain(rt)

        if let sid = json["steamID64"] as? String, !sid.isEmpty, steamID64.isEmpty {
            steamID64 = sid
            UserDefaults.standard.set(sid, forKey: "steamUserID")
        }
        if let name = json["accountName"] as? String, !name.isEmpty, accountName.isEmpty {
            accountName = name
            UserDefaults.standard.set(name, forKey: "steamUsername")
        }
        if let at = json["accessToken"] as? String, !at.isEmpty, accessToken.isEmpty {
            accessToken = at
            UserDefaults.standard.set(at, forKey: "steamAccessToken")
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
        UserDefaults.standard.removeObject(forKey: "steamAccessToken")
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

        // Form-encode the refresh token (JWT with base64url chars)
        var formChars = CharacterSet.alphanumerics
        formChars.insert(charactersIn: "-._~")
        let encodedRT = refreshToken.addingPercentEncoding(withAllowedCharacters: formChars) ?? refreshToken
        request.httpBody = "refresh_token=\(encodedRT)&steamid=\(steamID64)"
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Log HTTP status for debugging
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Token refresh HTTP \(httpResp.statusCode): \(body)")
            throw SteamSessionError.sessionExpired
        }

        let resp = try JSONDecoder().decode(RefreshResponse.self, from: data)

        if let token = resp.response?.access_token, !token.isEmpty {
            self.accessToken = token
            UserDefaults.standard.set(token, forKey: "steamAccessToken")
            Self.log.info("Access token refreshed")
        } else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Token refresh empty response: \(body)")
            // Do NOT logout — just report the error so user doesn't lose session
            throw SteamSessionError.sessionExpired
        }
    }

    /// Get a valid access token, refreshing if needed via Web API.
    public func getAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, !accessToken.isEmpty {
            if !isTokenExpired(accessToken) {
                return accessToken
            }
        }

        try await refreshAccessToken()
        return accessToken
    }

    /// Sync session state from the running Steam client.
    /// Call this at app launch to detect the logged-in user.
    public func syncFromSteamClient() async {
        do {
            let (steamID, name) = try await SteamNativeService.shared.getCurrentUser()
            if steamID64 != steamID || accountName != name {
                steamID64 = steamID
                if !name.isEmpty { accountName = name }
                UserDefaults.standard.set(steamID, forKey: "steamUserID")
                if !name.isEmpty { UserDefaults.standard.set(name, forKey: "steamUsername") }
                Self.log.info("Session synced from Steam client: \(name) (\(steamID))")
            }
        } catch {
            Self.log.info("Could not sync from Steam client: \(error.localizedDescription)")
        }
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
            kSecUseDataProtectionKeychain: true,
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
            kSecUseDataProtectionKeychain: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess {
            // Fallback: try legacy keychain for migration
            return loadFromLegacyKeychain(account: Self.keychainAccount)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain() {
        deleteKeychainItem(account: Self.keychainAccount)
        deleteKeychainItem(account: Self.keychainPasswordAccount)
    }

    // MARK: - Steam password (for SteamCMD)

    /// Save Steam password in Keychain for SteamCMD use.
    public func savePassword(_ password: String) {
        deleteKeychainItem(account: Self.keychainPasswordAccount)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainPasswordAccount,
            kSecValueData: password.data(using: .utf8)!,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Load Steam password from Keychain.
    public var storedPassword: String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainPasswordAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess {
            return loadFromLegacyKeychain(account: Self.keychainPasswordAccount)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychainItem(account: String) {
        // Delete from Data Protection keychain
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(query as CFDictionary)

        // Also clean up legacy keychain items
        let legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }

    /// One-time fallback to read from legacy keychain and migrate to Data Protection keychain.
    private func loadFromLegacyKeychain(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }

        // Migrate: save to Data Protection keychain and delete legacy
        Self.log.info("Migrating keychain item '\(account)' to Data Protection keychain")
        let saveQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemAdd(saveQuery as CFDictionary, nil)

        // Remove old legacy item
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        return value
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
