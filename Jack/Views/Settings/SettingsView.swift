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
    @AppStorage("defaultBottleLocation") var defaultBottleLocation = BottleData.defaultBottleDir
    @AppStorage("steamUserID") var steamUserID = ""
    @AppStorage("steamUsername") var steamUsername = ""
    @Environment(\.dismiss) var dismiss

    @State private var steamPassword = ""
    @State private var steamGuardCode = ""
    @State private var loginStatus: LoginTestStatus = .idle
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
                        text: "Default bottle path",
                        subtitle: defaultBottleLocation.prettyPath(),
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
                                defaultBottleLocation = url
                            }
                        }
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
                    }

                    TextField("Steam Username", text: $steamUsername)
                        .textContentType(.username)

                    SecureField("Password", text: $steamPassword)
                        .textContentType(.password)

                    TextField("Steam Guard Code (5 characters)", text: $steamGuardCode)
                        .textContentType(.oneTimeCode)

                    HStack {
                        Button(steamUsername.isEmpty ? "Sign In" : "Test Login") {
                            testLogin()
                        }
                        .disabled(steamUsername.isEmpty || steamPassword.isEmpty || steamGuardCode.isEmpty || loginStatus == .testing)

                        Spacer()

                        switch loginStatus {
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

                    if !steamUserID.isEmpty {
                        Button("Disconnect account") {
                            steamUserID = ""
                            steamUsername = ""
                        }
                        .foregroundStyle(.red)
                    }

                    Text("SteamCMD downloads games and loads your library. After the first login, credentials are saved automatically.")
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

    private func testLogin() {
        loginStatus = .testing
        let username = steamUsername
        let password = steamPassword
        let code = steamGuardCode

        Task {
            do {
                try await SteamCMDService.shared.ensureInstalled()
                steamCMDInstalled = true
                let result = try await SteamCMDService.shared.login(
                    username: username,
                    password: password,
                    steamGuardCode: code
                )
                if !result.steamID64.isEmpty {
                    steamUserID = result.steamID64
                }
                loginStatus = .success
                steamPassword = ""
                steamGuardCode = ""
            } catch {
                loginStatus = .failed(error.localizedDescription)
            }
        }
    }
}

#Preview {
    SettingsView()
}
