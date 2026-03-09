//
//  WelcomeView.swift
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

struct WelcomeView: View {
    @State var rosettaInstalled: Bool?
    @State var whiskyWineInstalled: Bool?
    @State var python3Installed: Bool?
    @State var pythonPkgsInstalled: Bool?
    @State var steamCMDInstalled: Bool?
    @State var monoInstalled: Bool?
    @State var gptkInstalled: Bool?
    @State var shouldCheckInstallStatus: Bool = false
    @Binding var path: [SetupStage]
    @Binding var showSetup: Bool
    var firstTime: Bool

    private var allInstalled: Bool {
        rosettaInstalled == true
        && whiskyWineInstalled == true
        && python3Installed == true
        && pythonPkgsInstalled == true
        && steamCMDInstalled == true
        && gptkInstalled == true
        // mono is optional
    }

    private var hasChecked: Bool {
        rosettaInstalled != nil && whiskyWineInstalled != nil
        && python3Installed != nil && pythonPkgsInstalled != nil
        && steamCMDInstalled != nil && monoInstalled != nil
        && gptkInstalled != nil
    }

    /// True if anything besides Rosetta/Wine needs installing.
    private var needsDependencyInstall: Bool {
        python3Installed == false || pythonPkgsInstalled == false
        || steamCMDInstalled == false || monoInstalled == false
        || gptkInstalled == false
    }

    var body: some View {
        VStack {
            VStack {
                if firstTime {
                    Text("Welcome to Jack")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Let's get everything set up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Setup")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Check and install required components")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            Spacer()
            Form {
                InstallStatusView(isInstalled: $rosettaInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "Rosetta")
                InstallStatusView(isInstalled: $whiskyWineInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  showUninstall: true,
                                  name: "JackWine")
                InstallStatusView(isInstalled: $python3Installed,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "Python 3")
                InstallStatusView(isInstalled: $pythonPkgsInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "Steam Library")
                InstallStatusView(isInstalled: $steamCMDInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "SteamCMD")
                InstallStatusView(isInstalled: $monoInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "Mono (optional)")
                InstallStatusView(isInstalled: $gptkInstalled,
                                  shouldCheckInstallStatus: $shouldCheckInstallStatus,
                                  name: "GPTK D3DMetal")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .onAppear {
                checkInstallStatus()
            }
            .onChange(of: shouldCheckInstallStatus) {
                checkInstallStatus()
            }
            Spacer()
            HStack {
                if hasChecked {
                    if !allInstalled {
                        Button("Quit") {
                            exit(0)
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    Button(allInstalled ? "Done" : "Install") {
                        if rosettaInstalled == false {
                            path.append(.rosetta)
                            return
                        }

                        if whiskyWineInstalled == false {
                            path.append(.whiskyWineDownload)
                            return
                        }

                        if needsDependencyInstall {
                            path.append(.dependencies)
                            return
                        }

                        showSetup = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 400, height: 390)
    }

    func checkInstallStatus() {
        let dm = DependencyManager.shared
        rosettaInstalled = Rosetta2.isRosettaInstalled
        whiskyWineInstalled = JackWineInstaller.isJackWineInstalled()
        python3Installed = dm.isPython3Installed
        steamCMDInstalled = SteamCMDService.shared.isInstalled

        // Check pip packages in background (runs python)
        Task.detached {
            let pkgs = dm.checkPythonPackages()
            let mono = dm.isMonoInstalled
            let gptk = GPTKInstaller.shared.isInstalled
            await MainActor.run {
                pythonPkgsInstalled = pkgs
                monoInstalled = mono
                gptkInstalled = gptk
            }
        }
    }
}

struct InstallStatusView: View {
    @Binding var isInstalled: Bool?
    @Binding var shouldCheckInstallStatus: Bool
    @State var showUninstall: Bool = false
    @State var name: String
    @State var text: String = "Checking…"

    var body: some View {
        HStack {
            Group {
                if let installed = isInstalled {
                    Circle()
                        .foregroundColor(installed ? .green : (name.contains("optional") ? .yellow : .red))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 10)
            Text("\(name): \(text)")
            Spacer()
            if let installed = isInstalled {
                if installed && showUninstall {
                    Button("Uninstall") {
                        uninstall()
                    }
                }
            }
        }
        .onChange(of: isInstalled) {
            if let installed = isInstalled {
                text = installed ? "Installed" : "Not installed"
            } else {
                text = "Checking…"
            }
        }
    }

    func uninstall() {
        if name == "JackWine" {
            JackWineInstaller.uninstall()
        }

        shouldCheckInstallStatus.toggle()
    }
}
