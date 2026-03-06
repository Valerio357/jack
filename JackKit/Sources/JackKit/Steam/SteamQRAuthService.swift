//
//  SteamQRAuthService.swift
//  JackKit
//
//  Implements Steam's official QR code login protocol.
//  Flow: BeginAuthSessionViaQR → show QR → user scans with Steam mobile app
//        → PollAuthSessionStatus → decode JWT → SteamID64
//

import Foundation

public enum SteamQRAuthError: LocalizedError {
    case sessionFailed(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sessionFailed(let msg): return "QR login fallito: \(msg)"
        case .timeout: return "QR scaduto. Riprova."
        case .cancelled: return "Login annullato."
        }
    }
}

@MainActor
public final class SteamQRAuthService: ObservableObject {
    public static let shared = SteamQRAuthService()

    @Published public var challengeURL: String?
    @Published public var isActive = false
    @Published public var error: String?

    private var pollTask: Task<String, Error>?
    private static let baseURL = "https://api.steampowered.com/IAuthenticationService"

    private init() {}

    // MARK: - Begin session

    /// Start a QR auth session. Returns the challenge URL to show as QR code.
    public func beginSession() async throws -> String {
        isActive = true
        error = nil

        var req = URLRequest(url: URL(string: "\(Self.baseURL)/BeginAuthSessionViaQR/v1")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "device_friendly_name=Jack%20for%20Mac&device_type=1&platform_type=2"
        req.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(SteamQRBeginResponse.self, from: data)
        guard let inner = json.response, !inner.challenge_url.isEmpty else {
            throw SteamQRAuthError.sessionFailed("Nessuna challenge_url dalla risposta Steam.")
        }
        challengeURL = inner.challenge_url
        return inner.challenge_url
    }

    /// Poll until the user approves the QR login. Returns SteamID64.
    public func poll(clientID: String, requestID: String, interval: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(180) // 3 min timeout
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(max(3, interval)))

            var req = URLRequest(url: URL(string: "\(Self.baseURL)/PollAuthSessionStatus/v1")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "client_id=\(clientID)&request_id=\(requestID)".data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONDecoder().decode(SteamQRPollResponse.self, from: data)

            if let token = json.response?.access_token, !token.isEmpty {
                if let steamID = Self.extractSteamID(from: token) {
                    isActive = false
                    challengeURL = nil
                    return steamID
                }
            }
        }
        isActive = false
        throw SteamQRAuthError.timeout
    }

    /// Full login flow: begin + poll. Calls onQRReady with the URL to show as QR.
    public func login(onQRReady: @escaping @Sendable (String) -> Void) async throws -> String {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/BeginAuthSessionViaQR/v1")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "device_friendly_name=Jack%20for%20Mac&device_type=1&platform_type=2"
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let begin = try JSONDecoder().decode(SteamQRBeginResponse.self, from: data)
        guard let inner = begin.response else {
            throw SteamQRAuthError.sessionFailed("Risposta Steam non valida.")
        }
        onQRReady(inner.challenge_url)

        return try await poll(
            clientID: inner.client_id,
            requestID: inner.request_id,
            interval: inner.interval
        )
    }

    public func cancel() {
        pollTask?.cancel()
        isActive = false
        challengeURL = nil
    }

    // MARK: - JWT decode

    /// Decode the JWT access_token to extract SteamID64 from the `sub` claim.
    static func extractSteamID(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        // Base64url → base64 padding
        while payload.count % 4 != 0 { payload += "=" }
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONDecoder().decode(JWTPayload.self, from: data),
              json.sub.hasPrefix("7656119") else { return nil }
        return json.sub
    }
}

// MARK: - Codable models

private struct SteamQRBeginResponse: Decodable {
    let response: SteamQRBeginInner?
}
private struct SteamQRBeginInner: Decodable {
    let client_id: String
    let challenge_url: String
    let request_id: String
    let interval: Double
}
private struct SteamQRPollResponse: Decodable {
    let response: SteamQRPollInner?
}
private struct SteamQRPollInner: Decodable {
    let access_token: String?
}
private struct JWTPayload: Decodable {
    let sub: String
}
