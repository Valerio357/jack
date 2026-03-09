//
//  SettingsView.swift
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

struct SettingsView: View {
    @AppStorage("SUEnableAutomaticChecks") var whiskyUpdate = true
    @AppStorage("killOnTerminate") var killOnTerminate = true
    @AppStorage("checkJackWineUpdates") var checkJackWineUpdates = true
    @AppStorage("jackDataLocation") var jackDataLocation: URL?
    @AppStorage("steamUserID") var steamUserID = ""
    @AppStorage("steamUsername") var steamUsername = ""
    @Environment(\.dismiss) var dismiss

    // Steam Cloud login (jacksteam.py)
    @State private var cloudUsername = ""
    @State private var cloudPassword = ""
    @State private var cloudGuardCode = ""
    @State private var cloudStatus: LoginStatus = .idle
    @State private var showCloudLogin = false

    // SteamCMD login
    @State private var cmdUsername = ""
    @State private var cmdPassword = ""
    @State private var cmdGuardCode = ""
    @State private var cmdStatus: LoginStatus = .idle
    @State private var showCmdLogin = false
    @State private var steamCMDInstalled = SteamCMDService.shared.isInstalled
    @State private var cmdCredentialsCached = false
    @State private var isInstallingCMD = false

    enum LoginStatus: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Terminate Wine processes when Jack closes", isOn: $killOnTerminate)
                    ActionView(
                        text: "Jack data location",
                        subtitle: BottleData.containerDir.prettyPath(),
                        actionName: "create.browse"
                    ) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        panel.directoryURL = BottleData.containerDir
                        panel.begin { result in
                            if result == .OK, let url = panel.urls.first {
                                jackDataLocation = url
                                BottleData.setCustomDataLocation(url)
                            }
                        }
                    }
                    if jackDataLocation != nil {
                        Button("Restore default location") {
                            jackDataLocation = nil
                            BottleData.setCustomDataLocation(nil)
                        }
                        .foregroundStyle(.red)
                    }
                    LabeledContent("Default bottle path") {
                        Text(BottleData.defaultBottleDir.prettyPath())
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Updates") {
                    Toggle("Automatically check for Jack updates", isOn: $whiskyUpdate)
                    Toggle("Automatically check for JackWine updates", isOn: $checkJackWineUpdates)
                }

                // MARK: - Steam Cloud (jacksteam.py — library, cloud sync)
                Section("Steam Account") {
                    if steamUserID.isEmpty {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Steam ID", value: steamUserID)
                        if !steamUsername.isEmpty {
                            LabeledContent("Username", value: steamUsername)
                        }
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.jackSuccess)
                            .font(.caption)
                    }

                    if steamUserID.isEmpty || showCloudLogin {
                        loginForm(
                            username: $cloudUsername,
                            password: $cloudPassword,
                            guardCode: $cloudGuardCode,
                            status: cloudStatus,
                            action: cloudLogin,
                            label: "Sign In"
                        )
                    }

                    if !steamUserID.isEmpty {
                        HStack {
                            Button("Reconnect") {
                                showCloudLogin.toggle()
                                cloudUsername = steamUsername
                                cloudStatus = .idle
                            }
                            Spacer()
                            Button("Disconnect") {
                                SteamSessionManager.shared.logout()
                                steamUserID = ""
                                steamUsername = ""
                                showCloudLogin = false
                                cloudStatus = .idle
                            }
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Used for game library, cloud saves, and online features.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - SteamCMD (game downloads)
                Section("SteamCMD") {
                    HStack {
                        Text("Status")
                        Spacer()
                        if steamCMDInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.jackSuccess)
                                .font(.caption)
                        } else if isInstallingCMD {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Install SteamCMD") {
                                installSteamCMD()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }

                    if steamCMDInstalled {
                        HStack {
                            Text("Credentials")
                            Spacer()
                            if cmdCredentialsCached {
                                Label("Cached", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.jackSuccess)
                                    .font(.caption)
                            } else {
                                Text("Not cached")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !cmdCredentialsCached || showCmdLogin {
                            loginForm(
                                username: $cmdUsername,
                                password: $cmdPassword,
                                guardCode: $cmdGuardCode,
                                status: cmdStatus,
                                action: cmdLogin,
                                label: "Cache Credentials"
                            )
                        }

                        if cmdCredentialsCached {
                            Button("Re-authenticate") {
                                showCmdLogin.toggle()
                                cmdUsername = steamUsername.isEmpty ? cloudUsername : steamUsername
                                cmdStatus = .idle
                            }
                        }
                    }

                    Text("Used for downloading games. Login once to cache credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 450, height: 700)
        .onAppear {
            checkCmdCredentials()
        }
    }

    // MARK: - Shared login form

    @ViewBuilder
    private func loginForm(
        username: Binding<String>,
        password: Binding<String>,
        guardCode: Binding<String>,
        status: LoginStatus,
        action: @escaping () -> Void,
        label: String
    ) -> some View {
        VStack(spacing: 8) {
            TextField("Username", text: username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)

            SecureField("Password", text: password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)

            TextField("Steam Guard Code", text: guardCode)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(label) {
                    action()
                }
                .disabled(status == .testing
                          || username.wrappedValue.isEmpty
                          || password.wrappedValue.isEmpty)
                .buttonStyle(.borderedProminent)

                Spacer()

                switch status {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                case .success:
                    Label("OK", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.jackSuccess)
                        .font(.caption)
                case .failed(let msg):
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func installSteamCMD() {
        isInstallingCMD = true
        Task {
            do {
                try await SteamCMDService.shared.ensureInstalled()
                steamCMDInstalled = true
            } catch {
                cmdStatus = .failed(error.localizedDescription)
            }
            isInstallingCMD = false
        }
    }

    private func checkCmdCredentials() {
        // Quick check: try SteamCMD login with just username (cached creds)
        guard steamCMDInstalled, !steamUsername.isEmpty else { return }
        Task {
            do {
                _ = try await SteamCMDService.shared.login(username: steamUsername)
                cmdCredentialsCached = true
            } catch {
                cmdCredentialsCached = false
            }
        }
    }

    // MARK: - Steam Cloud login (jacksteam.py)

    private func cloudLogin() {
        cloudStatus = .testing
        let user = cloudUsername
        let pw = cloudPassword
        let code = cloudGuardCode

        Task {
            do {
                let result = try await SteamNativeService.shared.login(
                    username: user,
                    password: pw,
                    twoFactorCode: code.isEmpty ? nil : code
                )

                SteamSessionManager.shared.saveSession(result: result)
                SteamSessionManager.shared.savePassword(pw)
                steamUserID = result.steamID64
                steamUsername = result.accountName.isEmpty ? user : result.accountName

                cloudStatus = .success
                showCloudLogin = false
                cloudPassword = ""
                cloudGuardCode = ""

                // Pre-fill SteamCMD username
                if cmdUsername.isEmpty {
                    cmdUsername = steamUsername
                }
            } catch let error as SteamNativeService.SteamNativeError {
                switch error {
                case .loginFailed(let msg):
                    if msg.contains("2FA") || msg.contains("code required") {
                        cloudStatus = .failed("Enter your Steam Guard code and try again.")
                    } else {
                        cloudStatus = .failed(msg)
                    }
                default:
                    cloudStatus = .failed(error.localizedDescription)
                }
            } catch {
                cloudStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - SteamCMD login

    private func cmdLogin() {
        cmdStatus = .testing
        let user = cmdUsername
        let pw = cmdPassword
        let code = cmdGuardCode

        Task {
            do {
                try await SteamCMDService.shared.ensureInstalled()
                _ = try await SteamCMDService.shared.login(
                    username: user,
                    password: pw,
                    steamGuardCode: code.isEmpty ? nil : code
                )

                cmdStatus = .success
                cmdCredentialsCached = true
                showCmdLogin = false
                cmdPassword = ""
                cmdGuardCode = ""

                // Also save password as fallback
                SteamSessionManager.shared.savePassword(pw)
            } catch let error as SteamCMDError {
                cmdStatus = .failed(error.localizedDescription)
            } catch {
                cmdStatus = .failed(error.localizedDescription)
            }
        }
    }
}

#Preview {
    SettingsView()
}
