//
//  SteamCMClient.swift
//  JackKit
//
//  Native Steam Connection Manager client.
//  Connects to Steam servers via WebSocket, handles protobuf messages,
//  authenticates with access tokens, maintains heartbeat, generates app tickets.
//
//  This replaces Wine Steam entirely for authentication.
//

import Foundation
import os.log
import CryptoKit
import Compression

public final class SteamCMClient: @unchecked Sendable {
    public static let shared = SteamCMClient()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamCM")

    // Connection state
    public enum State: Sendable {
        case disconnected
        case connecting
        case connected
        case loggedOn
    }

    private var state: State = .disconnected
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // Session
    private var steamID: UInt64 = 0
    private var sessionID: Int32 = 0
    private var cellID: UInt32 = 0
    private var heartbeatInterval: Int32 = 0

    // Job tracking for request-response pairs
    private struct JobState: Sendable {
        var nextJobID: UInt64 = 1
        var pendingJobs: [UInt64: CheckedContinuation<(CMsgProtoBufHeader, Data), Error>] = [:]
    }
    private let jobs = OSAllocatedUnfairLock(initialState: JobState())

    // Callbacks
    public var onStateChanged: ((State) -> Void)?
    public var onDisconnected: ((Error?) -> Void)?

    public var isLoggedOn: Bool { state == .loggedOn }
    public var currentSteamID: UInt64 { steamID }

    private init() {}

    // MARK: - CM Server Discovery

    private struct CMListResponse: Decodable {
        let response: CMListInner?
    }
    private struct CMListInner: Decodable {
        let serverlist: [CMServer]?
        let serverlist_websockets: [String]?
    }
    private struct CMServer: Decodable {
        let endpoint: String?
        let type: String?
    }

    /// Get WebSocket CM server addresses from Steam directory.
    private func getCMServers() async throws -> [String] {
        let url = URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&maxcount=10")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(CMListResponse.self, from: data)

        if let wsList = resp.response?.serverlist_websockets, !wsList.isEmpty {
            return wsList.map { "wss://\($0)/cmsocket/" }
        }

        // Fallback: use serverlist endpoints marked as websocket
        if let servers = resp.response?.serverlist {
            let wsServers = servers.compactMap { s -> String? in
                guard s.type == "websockets", let ep = s.endpoint else { return nil }
                return "wss://\(ep)/cmsocket/"
            }
            if !wsServers.isEmpty { return wsServers }
        }

        // Hardcoded fallback
        return ["wss://cm1-fra1.steamserver.net/cmsocket/"]
    }

    // MARK: - Connect

    /// Connect to a Steam CM server via WebSocket.
    public func connect() async throws {
        guard state == .disconnected else { return }
        setState(.connecting)

        let servers = try await getCMServers()
        guard let serverURL = servers.randomElement(), let url = URL(string: serverURL) else {
            throw CMError.noServersAvailable
        }

        Self.log.info("Connecting to CM: \(serverURL)")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        setState(.connected)

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// Disconnect from the CM server.
    public func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        steamID = 0
        sessionID = 0
        setState(.disconnected)

        // Fail any pending jobs
        let pending = jobs.withLock { state -> [UInt64: CheckedContinuation<(CMsgProtoBufHeader, Data), Error>] in
            let p = state.pendingJobs
            state.pendingJobs.removeAll()
            return p
        }
        for (_, continuation) in pending {
            continuation.resume(throwing: CMError.disconnected)
        }
    }

    // MARK: - Login

    /// Log on using an access token from SteamNativeAuth.
    public func logOn(accountName: String, accessToken: String) async throws {
        guard state == .connected else {
            throw CMError.notConnected
        }

        var logon = CMsgClientLogon()
        logon.accountName = accountName
        logon.accessToken = accessToken
        logon.protocolVersion = 65580
        logon.clientOSType = 16  // Windows 10
        logon.clientLanguage = "english"
        logon.shouldRememberPassword = true
        logon.machineName = "Jack-\(ProcessInfo.processInfo.hostName)"

        // Generate a simple machine ID
        logon.machineID = generateMachineID()

        let header = CMsgProtoBufHeader()  // Empty header for logon
        try await sendMessage(eMsg: .clientLogon, header: header, body: logon.encode())

        // Wait for logon response (handled in receiveLoop)
        // We use a continuation stored in a property
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.logonContinuation = continuation
        }
    }

    private var logonContinuation: CheckedContinuation<Void, Error>?

    // MARK: - App Ownership Ticket

    /// Request an app ownership ticket for the given app ID.
    public func getAppOwnershipTicket(appID: UInt32) async throws -> Data {
        guard state == .loggedOn else { throw CMError.notLoggedOn }

        var msg = CMsgClientGetAppOwnershipTicket()
        msg.appID = appID

        let (_, responseBody) = try await sendRequest(
            eMsg: .clientGetAppOwnershipTicket,
            body: msg.encode()
        )

        let resp = CMsgClientGetAppOwnershipTicketResponse.decode(from: responseBody)
        guard resp.eresult.isSuccess else {
            throw CMError.requestFailed(resp.eresult)
        }
        return resp.ticket
    }

    // MARK: - Send/Receive

    /// Send a protobuf message.
    private func sendMessage(eMsg: EMsg, header: CMsgProtoBufHeader, body: Data) async throws {
        guard let ws = webSocketTask else { throw CMError.notConnected }

        var hdr = header
        if steamID != 0 { hdr.steamID = steamID }
        if sessionID != 0 { hdr.clientSessionID = sessionID }

        let headerData = hdr.encode()

        // Frame format: [4-byte EMsg|protobuf_flag] [4-byte header_len] [header] [body]
        var frame = Data(capacity: 8 + headerData.count + body.count)
        var msgType = (eMsg.rawValue | EMsg.protobufFlag).littleEndian
        frame.append(Data(bytes: &msgType, count: 4))
        var headerLen = UInt32(headerData.count).littleEndian
        frame.append(Data(bytes: &headerLen, count: 4))
        frame.append(headerData)
        frame.append(body)

        try await ws.send(.data(frame))
    }

    /// Send a request and wait for the corresponding response.
    nonisolated private func sendRequest(eMsg: EMsg, body: Data) async throws -> (CMsgProtoBufHeader, Data) {
        let jobID = allocateJobID()

        var header = CMsgProtoBufHeader()
        header.jobIDSource = jobID

        // Send first, then wait
        try await sendMessage(eMsg: eMsg, header: header, body: body)

        // Now wait for the response via the receive loop
        return try await withCheckedThrowingContinuation { continuation in
            jobs.withLock { $0.pendingJobs[jobID] = continuation }
        }
    }

    private func allocateJobID() -> UInt64 {
        jobs.withLock { state in
            let id = state.nextJobID
            state.nextJobID += 1
            return id
        }
    }

    /// Receive loop — reads WebSocket frames and dispatches messages.
    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .data(let data):
                    handleMessage(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        handleMessage(data)
                    }
                @unknown default:
                    break
                }
            } catch {
                Self.log.error("WebSocket receive error: \(error.localizedDescription)")
                disconnect()
                onDisconnected?(error)
                return
            }
        }
    }

    /// Parse and dispatch a received message.
    private func handleMessage(_ data: Data) {
        guard data.count >= 8 else { return }

        let rawMsgType = data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }
        let msgType = UInt32(littleEndian: rawMsgType) & ~EMsg.protobufFlag
        let headerLen = Int(UInt32(littleEndian: data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }))

        guard data.count >= 8 + headerLen else { return }

        let headerData = Data(data[8..<8+headerLen])
        let bodyData = Data(data[(8+headerLen)...])
        let header = CMsgProtoBufHeader.decode(from: headerData)

        guard let eMsg = EMsg(rawValue: msgType) else {
            Self.log.debug("Unknown EMsg: \(msgType)")
            // Check if it's a response to a pending job
            resolveJob(header: header, body: bodyData)
            return
        }

        switch eMsg {
        case .clientLogOnResponse:
            handleLogOnResponse(header: header, body: bodyData)
        case .clientLicenseList:
            handleLicenseList(body: bodyData)
        case .multi:
            handleMulti(body: bodyData)
        default:
            // Check pending jobs
            resolveJob(header: header, body: bodyData)
        }
    }

    private func resolveJob(header: CMsgProtoBufHeader, body: Data) {
        let targetJob = header.jobIDTarget
        guard targetJob != UInt64.max else { return }

        let continuation = jobs.withLock { $0.pendingJobs.removeValue(forKey: targetJob) }

        continuation?.resume(returning: (header, body))
    }

    // MARK: - Message Handlers

    private func handleLogOnResponse(header: CMsgProtoBufHeader, body: Data) {
        let resp = CMsgClientLogOnResponse.decode(from: body)
        Self.log.info("LogOn response: eresult=\(resp.eresult.rawValue), steamID=\(header.steamID)")

        if resp.eresult.isSuccess {
            steamID = header.steamID
            sessionID = header.clientSessionID
            heartbeatInterval = resp.heartbeatSeconds
            cellID = resp.cellID

            setState(.loggedOn)
            startHeartbeat()

            logonContinuation?.resume()
            logonContinuation = nil
        } else {
            logonContinuation?.resume(throwing: CMError.logonFailed(resp.eresult))
            logonContinuation = nil
        }
    }

    private func handleLicenseList(body: Data) {
        let list = CMsgClientLicenseList.decode(from: body)
        Self.log.info("Received license list: \(list.licenses.count) licenses")
    }

    private func handleMulti(body: Data) {
        // Multi messages contain gzipped sub-messages
        // Parse the Multi wrapper
        var dec = ProtoDecoder(data: body)
        var sizeUnzipped: UInt32 = 0
        var payload: Data?

        while let field = dec.readField() {
            switch field.number {
            case 1: sizeUnzipped = dec.readUInt32() ?? 0
            case 2: payload = dec.readBytes()
            default: dec.skipField(field)
            }
        }

        guard var messageData = payload else { return }

        // If sizeUnzipped > 0, the payload is gzipped
        if sizeUnzipped > 0 {
            guard let decompressed = messageData.gunzip() else {
                Self.log.error("Failed to decompress Multi message")
                return
            }
            messageData = decompressed
        }

        // Parse sub-messages: each is [4-byte length][message data]
        var offset = 0
        while offset + 4 <= messageData.count {
            let subLen = Int(UInt32(littleEndian: messageData[offset..<offset+4]
                .withUnsafeBytes { $0.load(as: UInt32.self) }))
            offset += 4
            guard offset + subLen <= messageData.count else { break }
            let subData = Data(messageData[offset..<offset+subLen])
            handleMessage(subData)
            offset += subLen
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = max(10, heartbeatInterval)
        Self.log.info("Starting heartbeat every \(interval)s")

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(interval)))
                guard let self, self.state == .loggedOn else { return }
                let header = CMsgProtoBufHeader()
                try? await self.sendMessage(eMsg: .clientHeartBeat, header: header, body: Data())
            }
        }
    }

    // MARK: - State

    private func setState(_ newState: State) {
        state = newState
        onStateChanged?(newState)
        Self.log.info("CM state: \(String(describing: newState))")
    }

    // MARK: - Machine ID

    private func generateMachineID() -> Data {
        // Simple machine ID based on hostname hash
        let hostname = ProcessInfo.processInfo.hostName
        let hash = hostname.data(using: .utf8)?.sha1() ?? Data(count: 20)

        // Machine ID format: MessageObject with BB_3, FF_2, 3B_3 fields
        var enc = ProtoEncoder()
        enc.writeBytes(field: 1, value: hash)  // BB_3 = SHA1 of machine info
        enc.writeBytes(field: 2, value: hash)  // FF_2 = SHA1 of disk info
        enc.writeBytes(field: 3, value: hash)  // 3B_3 = SHA1 of MAC
        return enc.output
    }

    // MARK: - Errors

    public enum CMError: LocalizedError {
        case noServersAvailable
        case notConnected
        case notLoggedOn
        case disconnected
        case logonFailed(EResult)
        case requestFailed(EResult)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .noServersAvailable: return "No Steam CM servers available"
            case .notConnected: return "Not connected to Steam"
            case .notLoggedOn: return "Not logged on to Steam"
            case .disconnected: return "Disconnected from Steam"
            case .logonFailed(let r): return "Steam logon failed: \(r)"
            case .requestFailed(let r): return "Steam request failed: \(r)"
            case .timeout: return "Steam request timed out"
            }
        }
    }
}

// MARK: - Data helpers

extension Data {
    func sha1() -> Data {
        let digest = Insecure.SHA1.hash(data: self)
        return Data(digest)
    }

    /// Decompress gzip data using Apple's Compression framework.
    func gunzip() -> Data? {
        guard count > 10 else { return nil }
        // Check gzip magic number
        guard self[0] == 0x1F && self[1] == 0x8B else {
            return self // Not gzipped, return as-is
        }

        // Skip gzip header (10 bytes minimum) to get to raw deflate stream
        var headerSize = 10
        let flags = self[3]
        if flags & 0x04 != 0 { // FEXTRA
            guard count > headerSize + 2 else { return nil }
            let extraLen = Int(self[headerSize]) | (Int(self[headerSize + 1]) << 8)
            headerSize += 2 + extraLen
        }
        if flags & 0x08 != 0 { // FNAME
            while headerSize < count && self[headerSize] != 0 { headerSize += 1 }
            headerSize += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while headerSize < count && self[headerSize] != 0 { headerSize += 1 }
            headerSize += 1
        }
        if flags & 0x02 != 0 { headerSize += 2 } // FHCRC

        guard headerSize < count else { return nil }
        let compressed = self[headerSize..<(count - 8)] // Skip 8-byte trailer

        // Decompress raw deflate
        let sourceSize = compressed.count
        let destinationSize = sourceSize * 10  // Initial guess
        var destinationBuffer = [UInt8](repeating: 0, count: destinationSize)

        let result = compressed.withUnsafeBytes { sourcePtr -> Int in
            compression_decode_buffer(
                &destinationBuffer, destinationSize,
                sourcePtr.bindMemory(to: UInt8.self).baseAddress!, sourceSize,
                nil, COMPRESSION_ZLIB
            )
        }

        guard result > 0 else { return nil }
        return Data(destinationBuffer[0..<result])
    }
}
