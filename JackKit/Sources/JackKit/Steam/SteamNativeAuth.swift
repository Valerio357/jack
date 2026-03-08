//
//  SteamNativeAuth.swift
//  JackKit
//
//  Native Steam authentication via IAuthenticationService Web API.
//  No Wine, no Steam.exe — pure HTTPS to Steam servers.
//
//  Flow:
//    1. GetPasswordRSAPublicKey → RSA public key for password encryption
//    2. BeginAuthSessionViaCredentials → start login, get client_id + allowed confirmations
//    3. User approves via Steam Guard (mobile push or email code)
//    4. PollAuthSessionStatus → access_token + refresh_token
//    5. Decode JWT → SteamID64
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

// MARK: - Public types

public enum SteamGuardType: Sendable {
    case none
    case deviceConfirmation           // Push notification to Steam mobile app
    case deviceCode                   // TOTP code from Steam mobile authenticator
    case emailCode(domain: String)    // Code sent via email
    case emailConfirmation(domain: String)
}

public struct SteamLoginResult: Sendable {
    public let steamID64: String
    public let accessToken: String
    public let refreshToken: String
    public let accountName: String
}

public enum SteamNativeAuthError: LocalizedError {
    case rsaKeyFailed
    case encryptionFailed
    case loginFailed(String)
    case steamGuardRequired(SteamGuardType)
    case pollTimeout
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .rsaKeyFailed: return "Failed to get RSA key from Steam"
        case .encryptionFailed: return "Failed to encrypt password"
        case .loginFailed(let msg): return "Steam login failed: \(msg)"
        case .steamGuardRequired(let type):
            switch type {
            case .deviceConfirmation: return "Approve login on your Steam mobile app"
            case .deviceCode: return "Enter Steam Guard code from authenticator"
            case .emailCode(let domain): return "Enter code sent to \(domain)"
            case .emailConfirmation(let domain): return "Confirm login via email (\(domain))"
            case .none: return "Steam Guard required"
            }
        case .pollTimeout: return "Login timed out. Try again."
        case .invalidResponse: return "Invalid response from Steam"
        case .cancelled: return "Login cancelled"
        }
    }
}

// MARK: - SteamNativeAuth

public final class SteamNativeAuth: @unchecked Sendable {
    public static let shared = SteamNativeAuth()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamNativeAuth")
    private static let baseURL = "https://api.steampowered.com"

    // Active login session state
    private var clientID: String?
    private var requestID: String?
    private var pollInterval: Double = 5.0
    private var pendingGuardType: SteamGuardType?

    private init() {}

    /// Properly percent-encode parameters for application/x-www-form-urlencoded.
    /// Unlike urlQueryAllowed, this encodes +, /, = and other chars that have
    /// special meaning in form data.
    private static let formSafeChars: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: formSafeChars) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: formSafeChars) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    // MARK: - Step 1: Get RSA public key

    private struct RSAKeyResponse: Decodable {
        let response: RSAKeyInner?
    }
    private struct RSAKeyInner: Decodable {
        let publickey_mod: String
        let publickey_exp: String
        let timestamp: String
    }

    private func getPasswordRSAPublicKey(accountName: String) async throws -> (mod: String, exp: String, timestamp: String) {
        let url = URL(string: "\(Self.baseURL)/IAuthenticationService/GetPasswordRSAPublicKey/v1/?account_name=\(accountName)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(RSAKeyResponse.self, from: data)
        guard let key = resp.response else { throw SteamNativeAuthError.rsaKeyFailed }
        return (key.publickey_mod, key.publickey_exp, key.timestamp)
    }

    // MARK: - RSA encryption

    private func encryptPassword(_ password: String, modHex: String, expHex: String) throws -> String {
        // Convert hex strings to Data
        guard let modData = Data(hexString: modHex),
              let expData = Data(hexString: expHex),
              let passwordData = password.data(using: .utf8) else {
            throw SteamNativeAuthError.encryptionFailed
        }

        // Build RSA public key from raw modulus + exponent
        let keyDict: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]

        // DER-encode the RSA public key (PKCS#1)
        let derKey = buildDERPublicKey(modulus: modData, exponent: expData)
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(derKey as CFData, keyDict as CFDictionary, &error) else {
            throw SteamNativeAuthError.encryptionFailed
        }

        // Encrypt with PKCS1 padding (what Steam expects)
        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, passwordData as CFData, &error) else {
            throw SteamNativeAuthError.encryptionFailed
        }

        return (encrypted as Data).base64EncodedString()
    }

    /// Build a DER-encoded PKCS#1 RSAPublicKey from raw modulus and exponent.
    private func buildDERPublicKey(modulus: Data, exponent: Data) -> Data {
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, exponent INTEGER }
        let modInteger = derInteger(modulus)
        let expInteger = derInteger(exponent)
        let sequence = derSequence(modInteger + expInteger)
        return sequence
    }

    private func derInteger(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        // Remove leading zeros but keep one if high bit set
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        // Prepend 0x00 if high bit is set (positive integer)
        if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return Data([0x02]) + derLength(bytes.count) + Data(bytes)
    }

    private func derSequence(_ content: Data) -> Data {
        return Data([0x30]) + derLength(content.count) + content
    }

    private func derLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        }
    }

    // MARK: - Step 2: Begin auth session

    private struct BeginAuthResponse: Decodable {
        let response: BeginAuthInner?
    }
    private struct BeginAuthInner: Decodable {
        let client_id: String?
        let request_id: String?
        let interval: Double?
        let allowed_confirmations: [ConfirmationInfo]?
        let steamid: String?
        let weak_token: String?
    }
    private struct ConfirmationInfo: Decodable {
        let confirmation_type: Int
        let associated_message: String?
    }

    /// Begin a credentials-based auth session. Returns the required Steam Guard type.
    public func beginLogin(accountName: String, password: String) async throws -> SteamGuardType {
        // Get RSA key
        let rsa = try await getPasswordRSAPublicKey(accountName: accountName)

        // Encrypt password
        let encryptedPassword = try encryptPassword(password, modHex: rsa.mod, expHex: rsa.exp)

        // Build request
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/IAuthenticationService/BeginAuthSessionViaCredentials/v1")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "account_name": accountName,
            "encrypted_password": encryptedPassword,
            "encryption_timestamp": rsa.timestamp,
            "remember_login": "true",
            "platform_type": "2",       // Desktop
            "persistence": "1",         // Persistent
            "device_friendly_name": "Jack for Mac",
            "website_id": "Client",
        ]
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        // Debug: log raw response
        if let rawJSON = String(data: data, encoding: .utf8) {
            Self.log.debug("BeginAuth response: \(rawJSON)")
        }

        let resp = try JSONDecoder().decode(BeginAuthResponse.self, from: data)
        guard let inner = resp.response, let cid = inner.client_id, let rid = inner.request_id else {
            // Check for error message in the response
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = raw["error_message"] as? String {
                throw SteamNativeAuthError.loginFailed(errorMsg)
            }
            throw SteamNativeAuthError.invalidResponse
        }

        self.clientID = cid
        self.requestID = rid
        self.pollInterval = inner.interval ?? 5.0

        // Determine what kind of confirmation Steam wants
        let guardType = parseGuardType(from: inner.allowed_confirmations ?? [])
        self.pendingGuardType = guardType
        return guardType
    }

    private func parseGuardType(from confirmations: [ConfirmationInfo]) -> SteamGuardType {
        // confirmation_type values:
        // 1 = None (no guard)
        // 2 = Email code
        // 3 = Machine/device token (auto)
        // 4 = Steam Guard mobile confirmation (push)
        // 5 = Email confirmation
        // 6 = Device code (TOTP)
        for conf in confirmations {
            switch conf.confirmation_type {
            case 1: return .none
            case 4: return .deviceConfirmation
            case 6: return .deviceCode
            case 2: return .emailCode(domain: conf.associated_message ?? "")
            case 5: return .emailConfirmation(domain: conf.associated_message ?? "")
            default: continue
            }
        }
        return .none
    }

    // MARK: - Step 3: Submit Steam Guard code (if needed)

    public func submitGuardCode(_ code: String, type: SteamGuardType) async throws {
        guard let clientID = clientID else { throw SteamNativeAuthError.invalidResponse }

        let codeType: Int
        switch type {
        case .deviceCode: codeType = 6
        case .emailCode: codeType = 2
        default: return // No code needed
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/IAuthenticationService/UpdateAuthSessionWithSteamGuardCode/v1")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "client_id": clientID,
            "steamid": "",
            "code": code,
            "code_type": "\(codeType)",
        ]).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let raw = String(data: data, encoding: .utf8) {
            Self.log.debug("UpdateGuardCode response: \(raw)")
        }
    }

    // MARK: - Step 4: Poll for completion

    private struct PollResponse: Decodable {
        let response: PollInner?
    }
    private struct PollInner: Decodable {
        let access_token: String?
        let refresh_token: String?
        let new_guard_data: String?
        let account_name: String?
    }

    /// Poll until the auth session is approved. Returns login result.
    public func pollForResult() async throws -> SteamLoginResult {
        guard let clientID = clientID, let requestID = requestID else {
            throw SteamNativeAuthError.invalidResponse
        }

        let deadline = Date().addingTimeInterval(120) // 2 min timeout
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(pollInterval))

            var request = URLRequest(url: URL(string: "\(Self.baseURL)/IAuthenticationService/PollAuthSessionStatus/v1")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode([
                "client_id": clientID,
                "request_id": requestID,
            ]).data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            let resp = try JSONDecoder().decode(PollResponse.self, from: data)

            if let inner = resp.response,
               let accessToken = inner.access_token, !accessToken.isEmpty,
               let refreshToken = inner.refresh_token, !refreshToken.isEmpty {

                let steamID = Self.extractSteamID(from: accessToken) ?? ""
                let accountName = inner.account_name ?? ""

                self.clientID = nil
                self.requestID = nil

                return SteamLoginResult(
                    steamID64: steamID,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    accountName: accountName
                )
            }
        }

        throw SteamNativeAuthError.pollTimeout
    }

    // MARK: - Convenience: full login flow

    /// Full login flow. Callback provides guard type so UI can show appropriate prompt.
    /// After callback, call submitGuardCode() if needed, then pollForResult().
    public func login(
        accountName: String,
        password: String
    ) async throws -> (guardType: SteamGuardType, poll: () async throws -> SteamLoginResult) {
        let guardType = try await beginLogin(accountName: accountName, password: password)

        return (guardType, { [self] in
            try await self.pollForResult()
        })
    }
}

// MARK: - JWT decode

extension SteamNativeAuth {
    static func extractSteamID(from jwt: String) -> String? {
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
}

// MARK: - Hex string Data extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
