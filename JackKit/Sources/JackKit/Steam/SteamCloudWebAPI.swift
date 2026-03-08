//
//  SteamCloudWebAPI.swift
//  JackKit
//
//  Native Steam Cloud sync via ICloudService Web API.
//  Downloads and uploads save files directly — no Wine or Steam client needed.
//
//  Flow:
//    Download: EnumerateUserFiles → HTTP GET each file → write to local save dir
//    Upload:   BeginAppUploadBatch → BeginHTTPUpload → HTTP PUT → CommitHTTPUpload → CompleteAppUploadBatch
//

import Foundation
import CryptoKit
import os.log

public final class SteamCloudWebAPI: @unchecked Sendable {
    public static let shared = SteamCloudWebAPI()

    private static let log = Logger(subsystem: "com.isaacmarovitz.Jack", category: "SteamCloud")
    private static let baseURL = "https://api.steampowered.com/ICloudService"

    private init() {}

    // MARK: - Public types

    public struct CloudFile: Sendable {
        public let filename: String
        public let size: Int
        public let sha: String
        public let downloadURL: String
        public let timestamp: Int
    }

    public struct SyncResult: Sendable {
        public let filesDownloaded: Int
        public let filesUploaded: Int
        public let filesDeleted: Int
    }

    // MARK: - Enumerate files

    /// List all Cloud files for a game.
    public func enumerateFiles(appID: Int) async throws -> [CloudFile] {
        let token = try await SteamSessionManager.shared.getAccessToken()

        let inputJSON = """
            {"appid":\(appID),"extended_details":true,"count":500,"start_index":0}
            """

        let data = try await postAPI(
            endpoint: "EnumerateUserFiles/v1/",
            token: token,
            inputJSON: inputJSON
        )

        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let response = resp?["response"] as? [String: Any],
              let files = response["files"] as? [[String: Any]] else {
            return []
        }

        return files.compactMap { f in
            guard let filename = f["filename"] as? String,
                  let size = f["size"] as? Int,
                  let sha = f["sha_file"] as? String ?? f["sha"] as? String else { return nil }

            let url = f["raw_file_url"] as? String
                ?? f["download_url"] as? String
                ?? Self.buildDownloadURL(from: f)

            return CloudFile(
                filename: filename,
                size: size,
                sha: sha,
                downloadURL: url ?? "",
                timestamp: f["time_modified"] as? Int ?? f["timestamp"] as? Int ?? 0
            )
        }
    }

    /// Build download URL from url_host + url_path if direct URL not provided.
    private static func buildDownloadURL(from file: [String: Any]) -> String? {
        guard let host = file["url_host"] as? String,
              let path = file["url_path"] as? String else { return nil }
        let scheme = (file["use_https"] as? Bool ?? true) ? "https" : "http"
        return "\(scheme)://\(host)\(path)"
    }

    // MARK: - Download (Cloud → Local)

    /// Download all cloud saves for a game to a local directory.
    public func downloadSaves(
        appID: Int,
        to localDir: URL,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> Int {
        onStatus?("Fetching cloud file list...")
        let files = try await enumerateFiles(appID: appID)

        guard !files.isEmpty else {
            Self.log.info("No cloud saves for app \(appID)")
            return 0
        }

        Self.log.info("Found \(files.count) cloud files for app \(appID)")
        let fm = FileManager.default

        var downloaded = 0
        for file in files {
            guard !file.downloadURL.isEmpty,
                  let url = URL(string: file.downloadURL) else { continue }

            onStatus?("Downloading \(file.filename)...")

            let (tempFile, _) = try await URLSession.shared.download(from: url)
            let fileData = try Data(contentsOf: tempFile)
            try? fm.removeItem(at: tempFile)

            // Verify SHA1
            let localSHA = Insecure.SHA1.hash(data: fileData)
                .map { String(format: "%02x", $0) }.joined()
            if !file.sha.isEmpty && localSHA != file.sha.lowercased() {
                Self.log.warning("SHA mismatch for \(file.filename): expected \(file.sha), got \(localSHA)")
            }

            // Write to local dir preserving path
            let destFile = localDir.appending(path: file.filename)
            try fm.createDirectory(at: destFile.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fileData.write(to: destFile)
            downloaded += 1
        }

        Self.log.info("Downloaded \(downloaded) cloud saves for app \(appID)")
        return downloaded
    }

    // MARK: - Upload (Local → Cloud)

    /// Upload local saves to Steam Cloud for a game.
    public func uploadSaves(
        appID: Int,
        from localDir: URL,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localDir.path(percentEncoded: false)) else { return 0 }

        // Collect local files
        var localFiles: [(relativePath: String, data: Data, sha: String)] = []
        if let enumerator = fm.enumerator(at: localDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard attrs?.isRegularFile == true else { continue }

                let relativePath = fileURL.path(percentEncoded: false)
                    .replacingOccurrences(of: localDir.path(percentEncoded: false) + "/", with: "")
                let data = try Data(contentsOf: fileURL)
                let sha = Insecure.SHA1.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
                localFiles.append((relativePath, data, sha))
            }
        }

        guard !localFiles.isEmpty else { return 0 }

        let token = try await SteamSessionManager.shared.getAccessToken()
        let machineName = "Jack-\(ProcessInfo.processInfo.hostName)"

        // Step 1: Begin batch
        onStatus?("Starting cloud upload...")
        let filesToUpload = localFiles.map { f in
            "{\"filename\":\"\(f.relativePath)\",\"file_size\":\(f.data.count),\"file_sha\":\"\(f.sha)\"}"
        }.joined(separator: ",")

        let batchJSON = """
            {"appid":\(appID),"machine_name":"\(machineName)","files_to_upload":[\(filesToUpload)],"files_to_delete":[]}
            """

        let batchData = try await postAPI(
            endpoint: "BeginAppUploadBatch/v1/",
            token: token,
            inputJSON: batchJSON
        )

        let batchResp = try JSONSerialization.jsonObject(with: batchData) as? [String: Any]
        guard let batchInner = batchResp?["response"] as? [String: Any],
              let batchID = batchInner["batch_id"] as? String else {
            Self.log.error("Failed to begin upload batch")
            return 0
        }

        // Step 2: Upload each file
        var uploaded = 0
        for file in localFiles {
            onStatus?("Uploading \(file.relativePath)...")

            // Begin HTTP upload
            let beginJSON = """
                {"appid":\(appID),"file_size":\(file.data.count),"filename":"\(file.relativePath)","file_sha":"\(file.sha)","platforms_to_sync":["all"],"upload_batch_id":"\(batchID)"}
                """

            let beginData = try await postAPI(
                endpoint: "BeginHTTPUpload/v1/",
                token: token,
                inputJSON: beginJSON
            )

            let beginResp = try JSONSerialization.jsonObject(with: beginData) as? [String: Any]
            guard let beginInner = beginResp?["response"] as? [String: Any],
                  let uploadHost = beginInner["url_host"] as? String,
                  let uploadPath = beginInner["url_path"] as? String else {
                Self.log.error("Failed to begin upload for \(file.relativePath)")
                continue
            }

            let useHTTPS = beginInner["use_https"] as? Bool ?? true
            let uploadURL = "\(useHTTPS ? "https" : "http")://\(uploadHost)\(uploadPath)"

            // Parse request headers
            var headers: [String: String] = [:]
            if let reqHeaders = beginInner["request_headers"] as? [[String: Any]] {
                for h in reqHeaders {
                    if let name = h["name"] as? String, let value = h["value"] as? String {
                        headers[name] = value
                    }
                }
            }

            // HTTP PUT the file data
            guard let putURL = URL(string: uploadURL) else { continue }
            var putRequest = URLRequest(url: putURL)
            putRequest.httpMethod = "PUT"
            putRequest.httpBody = file.data
            for (key, value) in headers {
                putRequest.setValue(value, forHTTPHeaderField: key)
            }

            let (_, putResponse) = try await URLSession.shared.data(for: putRequest)
            guard (putResponse as? HTTPURLResponse)?.statusCode == 200 else {
                Self.log.error("PUT failed for \(file.relativePath)")
                continue
            }

            // Commit upload
            let commitJSON = """
                {"appid":\(appID),"filename":"\(file.relativePath)","file_sha":"\(file.sha)","transfer_succeeded":true}
                """

            _ = try? await postAPI(
                endpoint: "CommitHTTPUpload/v1/",
                token: token,
                inputJSON: commitJSON
            )

            uploaded += 1
        }

        // Step 3: Complete batch
        let completeJSON = """
            {"appid":\(appID),"batch_id":"\(batchID)","batch_eresult":1}
            """
        _ = try? await postAPI(
            endpoint: "CompleteAppUploadBatch/v1/",
            token: token,
            inputJSON: completeJSON
        )

        Self.log.info("Uploaded \(uploaded)/\(localFiles.count) files for app \(appID)")
        return uploaded
    }

    // MARK: - Full Sync

    /// Sync cloud saves before game launch: download from Steam Cloud to local save dir.
    public func syncBeforeLaunch(
        appID: Int,
        saveDir: URL,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> SyncResult {
        guard SteamSessionManager.shared.isLoggedIn else {
            return SyncResult(filesDownloaded: 0, filesUploaded: 0, filesDeleted: 0)
        }

        let count = try await downloadSaves(appID: appID, to: saveDir, onStatus: onStatus)
        return SyncResult(filesDownloaded: count, filesUploaded: 0, filesDeleted: 0)
    }

    /// Sync cloud saves after game exit: upload local saves to Steam Cloud.
    public func syncAfterExit(
        appID: Int,
        saveDir: URL,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> SyncResult {
        guard SteamSessionManager.shared.isLoggedIn else {
            return SyncResult(filesDownloaded: 0, filesUploaded: 0, filesDeleted: 0)
        }

        let count = try await uploadSaves(appID: appID, from: saveDir, onStatus: onStatus)
        return SyncResult(filesDownloaded: 0, filesUploaded: count, filesDeleted: 0)
    }

    // MARK: - Goldberg save directory

    /// Returns the Goldberg Emulator save directory for a game in Wine.
    /// Original Goldberg saves to: %APPDATA%/Goldberg SteamEmu Saves/<appID>/remote/
    public static func goldbergSaveDir(bottle: Bottle, appID: Int) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "users")
            .appending(path: "crossover")
            .appending(path: "AppData")
            .appending(path: "Roaming")
            .appending(path: "Goldberg SteamEmu Saves")
            .appending(path: "\(appID)")
            .appending(path: "remote")
    }

    // MARK: - Private: API helpers

    private static let formSafeChars: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    private func postAPI(endpoint: String, token: String, inputJSON: String) async throws -> Data {
        let urlString = "\(Self.baseURL)/\(endpoint)"
        guard let url = URL(string: urlString) else {
            throw CloudError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: Self.formSafeChars) ?? token
        let encodedJSON = inputJSON.addingPercentEncoding(withAllowedCharacters: Self.formSafeChars) ?? inputJSON
        request.httpBody = "access_token=\(encodedToken)&input_json=\(encodedJSON)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            Self.log.error("API \(endpoint) returned \(httpResp.statusCode)")
            throw CloudError.apiError(httpResp.statusCode)
        }

        return data
    }

    // MARK: - Errors

    public enum CloudError: LocalizedError {
        case invalidURL
        case apiError(Int)
        case notLoggedIn

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Steam Cloud API URL"
            case .apiError(let code): return "Steam Cloud API error (HTTP \(code))"
            case .notLoggedIn: return "Not logged in to Steam"
            }
        }
    }
}
