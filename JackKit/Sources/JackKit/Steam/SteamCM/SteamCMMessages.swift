//
//  SteamCMMessages.swift
//  JackKit
//
//  Steam CM protocol message types and structures.
//  Based on SteamKit2 protocol definitions.
//

import Foundation

// MARK: - EMsg (Steam message types)

public enum EMsg: UInt32 {
    case multi                          = 1
    case clientHeartBeat                = 703
    case clientLogon                    = 5514
    case clientLogOnResponse            = 5515
    case clientLogOff                   = 5516
    case clientUpdateMachineAuth        = 5537
    case clientUpdateMachineAuthResponse = 5538
    case clientNewLoginKey              = 5463
    case clientNewLoginKeyAccepted      = 5464
    case clientGetAppOwnershipTicket    = 5526
    case clientGetAppOwnershipTicketResponse = 5527
    case clientPersonaState             = 5552
    case clientFriendsList              = 5553
    case clientAccountInfo              = 5155
    case clientEmailAddrInfo            = 5456
    case clientLicenseList              = 5434
    case clientGameConnectTokens        = 5507
    case clientPlayerNicknameList       = 5587
    case clientRequestedClientStats     = 5480
    case clientIsLimitedAccount         = 5430
    case serviceMethod                  = 5594
    case serviceMethodResponse          = 5595

    static let protobufFlag: UInt32 = 0x80000000
}

// MARK: - EResult

public enum EResult: Int32 {
    case ok = 1
    case fail = 2
    case noConnection = 3
    case invalidPassword = 5
    case loggedInElsewhere = 6
    case invalidProtocol = 8
    case invalidParam = 9
    case accountNotFound = 18
    case expired = 27
    case alreadyLoggedIn = 28
    case timeout = 42
    case rateLimitExceeded = 84
    case accountLoginDeniedThrottle = 87
    case tryAnotherCM = 68
    case invalidLoginAuthCode = 65
    case accountLogonDenied = 63  // Steam Guard
    case twoFactorCodeMismatch = 88
    case accessDenied = 15

    var isSuccess: Bool { self == .ok }
}

// MARK: - CMsgProtoBufHeader

public struct CMsgProtoBufHeader: Sendable {
    public var steamID: UInt64 = 0
    public var clientSessionID: Int32 = 0
    public var jobIDSource: UInt64 = UInt64.max
    public var jobIDTarget: UInt64 = UInt64.max
    public var targetJobName: String = ""
    public var eresult: Int32 = 0

    public init() {}

    public func encode() -> Data {
        var enc = ProtoEncoder()
        if steamID != 0 { enc.writeFixed64(field: 1, value: steamID) }
        if clientSessionID != 0 { enc.writeInt32(field: 2, value: clientSessionID) }
        if jobIDSource != UInt64.max { enc.writeFixed64(field: 10, value: jobIDSource) }
        if jobIDTarget != UInt64.max { enc.writeFixed64(field: 11, value: jobIDTarget) }
        if !targetJobName.isEmpty { enc.writeString(field: 12, value: targetJobName) }
        if eresult != 0 { enc.writeInt32(field: 13, value: eresult) }
        return enc.output
    }

    public static func decode(from data: Data) -> CMsgProtoBufHeader {
        var header = CMsgProtoBufHeader()
        var dec = ProtoDecoder(data: data)
        while let field = dec.readField() {
            switch field.number {
            case 1: header.steamID = dec.readFixed64() ?? 0
            case 2: header.clientSessionID = dec.readInt32() ?? 0
            case 10: header.jobIDSource = dec.readFixed64() ?? UInt64.max
            case 11: header.jobIDTarget = dec.readFixed64() ?? UInt64.max
            case 12: header.targetJobName = dec.readString() ?? ""
            case 13: header.eresult = dec.readInt32() ?? 0
            default: dec.skipField(field)
            }
        }
        return header
    }
}

// MARK: - CMsgClientLogon

public struct CMsgClientLogon {
    public var protocolVersion: UInt32 = 65580
    public var accountName: String = ""
    public var accessToken: String = ""       // Modern auth: JWT from Web API
    public var cellID: UInt32 = 0
    public var clientOSType: UInt32 = 16      // Win10
    public var clientLanguage: String = "english"
    public var shouldRememberPassword: Bool = true
    public var machineName: String = "Jack"
    public var machineID: Data = Data()

    public init() {}

    public func encode() -> Data {
        var enc = ProtoEncoder()
        enc.writeUInt32(field: 1, value: protocolVersion)
        if !accountName.isEmpty { enc.writeString(field: 50, value: accountName) }
        if !accessToken.isEmpty { enc.writeString(field: 113, value: accessToken) }
        if cellID != 0 { enc.writeUInt32(field: 3, value: cellID) }
        enc.writeUInt32(field: 6, value: clientOSType)
        enc.writeString(field: 200, value: clientLanguage)
        enc.writeBool(field: 124, value: shouldRememberPassword)
        if !machineName.isEmpty { enc.writeString(field: 62, value: machineName) }
        if !machineID.isEmpty { enc.writeBytes(field: 108, value: machineID) }
        return enc.output
    }
}

// MARK: - CMsgClientLogOnResponse

public struct CMsgClientLogOnResponse {
    public var eresult: EResult = .fail
    public var heartbeatSeconds: Int32 = 0
    public var clientSuppliedSteamID: UInt64 = 0
    public var ipCountryCode: String = ""
    public var vanityURL: String = ""
    public var cellID: UInt32 = 0

    public static func decode(from data: Data) -> CMsgClientLogOnResponse {
        var msg = CMsgClientLogOnResponse()
        var dec = ProtoDecoder(data: data)
        while let field = dec.readField() {
            switch field.number {
            case 1:
                let raw = dec.readInt32() ?? 2
                msg.eresult = EResult(rawValue: raw) ?? .fail
            case 3: msg.heartbeatSeconds = dec.readInt32() ?? 0
            case 21: msg.clientSuppliedSteamID = dec.readFixed64() ?? 0
            case 26: msg.ipCountryCode = dec.readString() ?? ""
            case 44: msg.vanityURL = dec.readString() ?? ""
            case 33: msg.cellID = dec.readUInt32() ?? 0
            default: dec.skipField(field)
            }
        }
        return msg
    }
}

// MARK: - CMsgClientGetAppOwnershipTicket

public struct CMsgClientGetAppOwnershipTicket {
    public var appID: UInt32 = 0

    public func encode() -> Data {
        var enc = ProtoEncoder()
        enc.writeUInt32(field: 1, value: appID)
        return enc.output
    }
}

// MARK: - CMsgClientGetAppOwnershipTicketResponse

public struct CMsgClientGetAppOwnershipTicketResponse {
    public var eresult: EResult = .fail
    public var appID: UInt32 = 0
    public var ticket: Data = Data()

    public static func decode(from data: Data) -> CMsgClientGetAppOwnershipTicketResponse {
        var msg = CMsgClientGetAppOwnershipTicketResponse()
        var dec = ProtoDecoder(data: data)
        while let field = dec.readField() {
            switch field.number {
            case 1:
                let raw = dec.readUInt32() ?? 2
                msg.eresult = EResult(rawValue: Int32(raw)) ?? .fail
            case 2: msg.appID = dec.readUInt32() ?? 0
            case 3: msg.ticket = dec.readBytes() ?? Data()
            default: dec.skipField(field)
            }
        }
        return msg
    }
}

// MARK: - CMsgClientLicenseList

public struct CMsgClientLicenseList {
    public struct License {
        public var packageID: UInt32 = 0
        public var lastChangeNumber: UInt32 = 0
    }

    public var eresult: EResult = .fail
    public var licenses: [License] = []

    public static func decode(from data: Data) -> CMsgClientLicenseList {
        var msg = CMsgClientLicenseList()
        var dec = ProtoDecoder(data: data)
        while let field = dec.readField() {
            switch field.number {
            case 1:
                let raw = dec.readInt32() ?? 2
                msg.eresult = EResult(rawValue: raw) ?? .fail
            case 2:
                if let subData = dec.readBytes() {
                    var sub = ProtoDecoder(data: subData)
                    var license = License()
                    while let sf = sub.readField() {
                        switch sf.number {
                        case 1: license.packageID = sub.readUInt32() ?? 0
                        case 7: license.lastChangeNumber = sub.readUInt32() ?? 0
                        default: sub.skipField(sf)
                        }
                    }
                    msg.licenses.append(license)
                }
            default: dec.skipField(field)
            }
        }
        return msg
    }
}
