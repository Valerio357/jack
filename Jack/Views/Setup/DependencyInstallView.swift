//
//  DependencyInstallView.swift
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

struct DependencyInstallView: View {
    @Binding var path: [SetupStage]
    @Binding var showSetup: Bool

    @State private var currentStep = ""
    @State private var isInstalling = true
    @State private var success = true
    @State private var errorMessage = ""

    var body: some View {
        VStack {
            Text("Installing Dependencies")
                .font(.title)
                .fontWeight(.bold)
            Text("This may take a minute…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Group {
                if isInstalling {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(2)
                        Text(currentStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if success {
                    Image(systemName: "checkmark.circle")
                        .resizable()
                        .foregroundStyle(.green)
                        .frame(width: 80, height: 80)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "xmark.circle")
                            .resizable()
                            .foregroundStyle(.red)
                            .frame(width: 80, height: 80)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            Spacer()
            HStack {
                if !isInstalling {
                    if !success {
                        Button("Quit") {
                            exit(0)
                        }
                        .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Retry") {
                            isInstalling = true
                            success = true
                            errorMessage = ""
                            Task { await installAll() }
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Spacer()
                        Button("Continue") {
                            showSetup = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .frame(width: 400, height: 280)
        .onAppear {
            Task { await installAll() }
        }
    }

    private func installAll() async {
        let dm = DependencyManager.shared

        do {
            // 1. Python 3 (if missing, try Homebrew)
            if !dm.isPython3Installed {
                if dm.isHomebrewInstalled {
                    currentStep = "Installing Python 3.10…"
                    try await dm.installPython3()
                } else {
                    throw DependencyManager.DependencyError.pythonNotFound
                }
            }

            // 2. Python packages (steam, gevent)
            if !dm.checkPythonPackages() {
                currentStep = "Installing Python packages (steam, gevent)…"
                try await dm.installPythonPackages()
            }

            // 3. SteamCMD
            if !SteamCMDService.shared.isInstalled {
                currentStep = "Installing SteamCMD…"
                try await dm.installSteamCMD()
            }

            // 4. Mono (optional — don't fail if it can't be installed)
            if !dm.isMonoInstalled && dm.isHomebrewInstalled {
                currentStep = "Installing Mono…"
                do {
                    try await dm.installMono()
                } catch {
                    // Non-critical — Steamless DRM stripping won't work but games may not need it
                }
            }

            isInstalling = false
            success = true

            // Auto-proceed after short delay
            try? await Task.sleep(for: .seconds(1.5))
            showSetup = false

        } catch {
            isInstalling = false
            success = false
            errorMessage = error.localizedDescription
        }
    }
}
