//
//  RosettaView.swift
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

struct RosettaView: View {
    @State var installing: Bool = true
    @State var successful: Bool = true
    @Binding var path: [SetupStage]
    @Binding var showSetup: Bool

    var body: some View {
        VStack {
            Text("Installing Rosetta")
                .font(.title)
                .fontWeight(.bold)
            Text("Rosetta 2 is required for x86_64 translation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Group {
                if installing {
                    ProgressView()
                        .scaleEffect(2)
                } else {
                    if successful {
                        Image(systemName: "checkmark.circle")
                            .resizable()
                            .foregroundStyle(.green)
                            .frame(width: 80, height: 80)
                    } else {
                        VStack {
                            Image(systemName: "xmark.circle")
                                .resizable()
                                .foregroundStyle(.red)
                                .frame(width: 80, height: 80)
                                .padding(.bottom, 20)
                            Text("Failed to install Rosetta")
                                .font(.subheadline)
                        }
                    }
                }
            }
            Spacer()
            HStack {
                if !successful {
                    Button("Quit") {
                        exit(0)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Retry") {
                        installing = true
                        successful = true

                        Task.detached {
                            await checkOrInstall()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 400, height: 200)
        .onAppear {
            Task.detached {
                await checkOrInstall()
            }
        }
    }

    func checkOrInstall() async {
        if Rosetta2.isRosettaInstalled {
            installing = false
            sleep(2)
            proceed()
        } else {
            do {
                successful = try await Rosetta2.installRosetta()
                installing = false
                try await Task.sleep(for: .seconds(2))
                proceed()
            } catch {
                successful = false
                installing = false
            }
        }
    }

    @MainActor
    func proceed() {
        if !JackWineInstaller.isJackWineInstalled() {
            path.append(.whiskyWineDownload)
            return
        }

        let dm = DependencyManager.shared
        if !dm.isPython3Installed || !dm.checkPythonPackages()
            || !SteamCMDService.shared.isInstalled
            || !GPTKInstaller.shared.isInstalled {
            path.append(.dependencies)
            return
        }

        showSetup = false
    }
}

#Preview {
    RosettaView(path: .constant([]), showSetup: .constant(true))
}
