//
//  ContentView.swift
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
import UniformTypeIdentifiers
import JackKit
import SemanticVersion

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var showSetup: Bool

    @State private var showBottleCreation: Bool = false
    @State private var newlyCreatedBottleURL: URL?
    @State private var showOnboarding: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        ZStack {
            Color.jackBackground.ignoresSafeArea()

            if let defaultBottle = defaultBottle {
                SteamLibraryView(bottle: defaultBottle)
            } else {
                noBottleView
            }
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showBottleCreation) {
            BottleCreationView(newlyCreatedBottleURL: $newlyCreatedBottleURL)
        }
        .sheet(isPresented: $showSetup) {
            SetupView(showSetup: $showSetup, firstTime: false)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .padding()
                .background(Color.jackBackground)
        }
        .task {
            bottleVM.loadBottles()
            if !hasCompletedOnboarding {
                showOnboarding = true
            }

            // Check all dependencies
            let wineBin = JackWineInstaller.binFolder.appending(path: "wine64")
            let dm = DependencyManager.shared
            if !FileManager.default.fileExists(atPath: wineBin.path(percentEncoded: false))
                || !dm.isPython3Installed
                || !dm.checkPythonPackages()
                || !SteamCMDService.shared.isInstalled
                || !GPTKInstaller.shared.isInstalled {
                showSetup = true
            }
        }
    }

    private var defaultBottle: Bottle? {
        // Find a bottle named "Jack" or just the first available one
        bottleVM.bottles.first(where: { $0.settings.name == "Jack" }) ?? bottleVM.bottles.first
    }

    private var noBottleView: some View {
        VStack(spacing: 20) {
            Image("JackLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .opacity(0.5)

            Text("Initial Setup")
                .font(.jackTitle)

            Text("Jack needs a Bottle to run Steam.")
                .font(.jackBody)
                .foregroundStyle(.white.opacity(0.6))

            Button {
                showBottleCreation.toggle()
            } label: {
                Text("Create Jack Bottle")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.jackAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    ContentView(showSetup: .constant(false))
        .environmentObject(BottleVM.shared)
}
