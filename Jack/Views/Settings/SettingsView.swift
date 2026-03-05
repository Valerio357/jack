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
    @AppStorage("steamAPIKey") var steamAPIKey = ""
    @AppStorage("steamUsername") var steamUsername = ""
    @Environment(\.openURL) var openURL
    @Environment(\.dismiss) var dismiss

    @State private var steamPassword = ""
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
                    Toggle("Termina i processi Wine quando Jack chiude", isOn: $killOnTerminate)
                    ActionView(
                        text: "Percorso bottiglie predefinito",
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
                    Toggle("Controlla automaticamente aggiornamenti di Jack", isOn: $whiskyUpdate)
                    Toggle("Controlla automaticamente aggiornamenti di JackWine", isOn: $checkJackWineUpdates)
                }
                Section("Steam") {
                    if steamUserID.isEmpty {
                        Text("Non connesso")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Steam ID", value: steamUserID)
                        Button("Scollega account") {
                            steamUserID = ""
                            steamAPIKey = ""
                            steamUsername = ""
                        }
                        .foregroundStyle(.red)
                    }
                    SecureField("API Key", text: $steamAPIKey)
                        .textContentType(.password)
                    Button("Ottieni API Key…") {
                        if let url = URL(string: "https://steamcommunity.com/dev/apikey") {
                            openURL(url)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
                Section("SteamCMD") {
                    HStack {
                        Text("Stato")
                        Spacer()
                        if steamCMDInstalled {
                            Label("Installato", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.jackSuccess)
                                .font(.caption)
                        } else if isInstallingCMD {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Download…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Installa SteamCMD") {
                                installSteamCMD()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }

                    TextField("Username Steam", text: $steamUsername)
                        .textContentType(.username)

                    SecureField("Password (solo per primo login)", text: $steamPassword)
                        .textContentType(.password)

                    HStack {
                        Button("Testa Login") {
                            testLogin()
                        }
                        .disabled(steamUsername.isEmpty || loginStatus == .testing)

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
                                .lineLimit(2)
                        }
                    }

                    Text("SteamCMD scarica i giochi Windows senza bisogno di Steam per Windows. Dopo il primo login le credenziali vengono salvate automaticamente.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Impostazioni")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 450, height: 600)
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
        let password = steamPassword.isEmpty ? nil : steamPassword

        Task {
            do {
                try await SteamCMDService.shared.ensureInstalled()
                steamCMDInstalled = true
                try await SteamCMDService.shared.login(username: username, password: password)
                loginStatus = .success
                steamPassword = ""
            } catch {
                loginStatus = .failed(error.localizedDescription)
            }
        }
    }
}

#Preview {
    SettingsView()
}
