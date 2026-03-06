//
//  BottleView.swift
//  Barrel
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

enum BottleStage {
    case config
}

struct BottleView: View {
    @ObservedObject var bottle: Bottle
    @State private var path = NavigationPath()
    @AppStorage("steamUsername") private var steamUsername = ""

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Programs") {
                    if steamUsername.isEmpty {
                        SteamLoginView()
                    } else {
                        SteamLibraryView(bottle: bottle)
                    }
                }

                Section {
                    NavigationLink(value: BottleStage.config) {
                        Label("tab.config", systemImage: "gearshape")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(bottle.settings.name)
            .disabled(!bottle.isAvailable)
            .onChange(of: bottle.settings) { _, _ in
                BottleVM.shared.bottles = BottleVM.shared.bottles
            }
            .navigationDestination(for: BottleStage.self) { stage in
                switch stage {
                case .config:
                    ConfigView(bottle: bottle)
                }
            }
        }
    }
}
