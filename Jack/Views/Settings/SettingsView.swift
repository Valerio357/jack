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

    @State private var steamPassword = ""
    @State private var steamGuardCode = ""
    @State private var loginStatus: LoginTestStatus = .idle
    @State private var loginStatusText = ""
    @State private var guardType: SteamGuardType?
    @State private var steamCMDInstalled = SteamCMDService.shared.isInstalled
    @State private var isInstallingCMD = false

    enum LoginTestStatus: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.general") {
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
                Section("settings.updates") {
                    Toggle("Automatically check for Jack updates", isOn: $whiskyUpdate)
                    Toggle("Automatically check for JackWine updates", isOn: $checkJackWineUpdates)
                }
                Section("Steam") {
                    if steamUserID.isEmpty {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Steam ID", value: steamUserID)
                        if !steamUsername.isEmpty {
                            LabeledContent("Account", value: steamUsername)
                        }
                    }

                    if steamUserID.isEmpty || loginStatus == .failed("") || loginStatus != .idle {
                        TextField("Steam Username", text: $steamUsername)
                            .textContentType(.username)

                        SecureField("Password", text: $steamPassword)
                            .textContentType(.password)

                        if guardType != nil {
                            TextField("Steam Guard Code", text: $steamGuardCode)
                                .textContentType(.oneTimeCode)
                        }
                    }

                    HStack {
                        if steamUserID.isEmpty {
                            Button("Sign In") {
                                nativeLogin()
                            }
                            .disabled(steamUsername.isEmpty || steamPassword.isEmpty || loginStatus == .testing)
                        }

                        Spacer()

                        switch loginStatus {
                        case .idle:
                            EmptyView()
                        case .testing:
                            ProgressView().controlSize(.small)
                            Text(loginStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                    if !steamUserID.isEmpty {
                        Button("Disconnect account") {
                            SteamSessionManager.shared.logout()
                            steamUserID = ""
                            steamUsername = ""
                        }
                        .foregroundStyle(.red)
                    }

                    Text("Native Steam login. No Wine needed for authentication.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .frame(width: 450, height: 550)
    }

    private func installSteamCMD() {
        isInstallingCMD = true
        Task {
            do {
                try await SteamCMDService.shared.ensureInstalled()
                steamCMDInstalled = true
            } catch {
                loginStatus = .failed(error.localizedDescription)
            }
            isInstallingCMD = false
        }
    }

    private func nativeLogin() {
        loginStatus = .testing
        loginStatusText = "Connecting…"
        let username = steamUsername
        let password = steamPassword
        let code = steamGuardCode

        Task {
            do {
                let auth = SteamNativeAuth.shared

                // If we have a guard code, submit it first
                if let gt = guardType, !code.isEmpty {
                    loginStatusText = "Submitting Steam Guard code…"
                    try await auth.submitGuardCode(code, type: gt)
                    steamGuardCode = ""
                }

                // Begin login if no pending session
                if guardType == nil {
                    loginStatusText = "Authenticating…"
                    let gt = try await auth.beginLogin(accountName: username, password: password)
                    guardType = gt

                    switch gt {
                    case .none:
                        break // No guard needed
                    case .deviceConfirmation:
                        loginStatusText = "Approve on your Steam mobile app…"
                    case .deviceCode:
                        loginStatusText = "Enter authenticator code"
                        loginStatus = .failed("Enter your Steam Guard code and press Sign In again.")
                        return
                    case .emailCode(let domain):
                        loginStatusText = "Enter code from email (\(domain))"
                        loginStatus = .failed("Enter the code sent to \(domain) and press Sign In again.")
                        return
                    case .emailConfirmation(let domain):
                        loginStatusText = "Confirm via email (\(domain))…"
                    }
                }

                // Poll for result
                loginStatusText = "Waiting for approval…"
                let result = try await auth.pollForResult()

                // Save session
                SteamSessionManager.shared.saveSession(result: result)
                steamUserID = result.steamID64
                steamUsername = result.accountName.isEmpty ? username : result.accountName

                // Also install SteamCMD for game downloads
                try? await SteamCMDService.shared.ensureInstalled()
                steamCMDInstalled = SteamCMDService.shared.isInstalled

                loginStatus = .success
                steamPassword = ""
                steamGuardCode = ""
                guardType = nil
                loginStatusText = ""
            } catch {
                guardType = nil
                loginStatus = .failed(error.localizedDescription)
                loginStatusText = ""
            }
        }
    }
}

#Preview {
    SettingsView()
}
