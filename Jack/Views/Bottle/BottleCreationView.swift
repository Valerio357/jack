//
//  BottleCreationView.swift
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

struct BottleCreationView: View {
    @Binding var newlyCreatedBottleURL: URL?

    @State private var newBottleName: String = ""
    @State private var newBottleVersion: WinVersion = .win10
    @State private var nameValid: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("create.name", text: $newBottleName)
                    .onChange(of: newBottleName) { _, name in
                        nameValid = !name.isEmpty
                    }

                Picker("create.win", selection: $newBottleVersion) {
                    ForEach(WinVersion.allCases.reversed(), id: \.self) {
                        Text($0.pretty())
                    }
                }

                LabeledContent("create.path") {
                    Text(BottleData.defaultBottleDir.prettyPath())
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("create.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("create.cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("create.create") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValid)
                }
            }
            .onSubmit {
                submit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: ViewWidth.small)
    }

    func submit() {
        newlyCreatedBottleURL = BottleVM.shared.createNewBottle(bottleName: newBottleName,
                                                                winVersion: newBottleVersion,
                                                                bottleURL: BottleData.defaultBottleDir)
        dismiss()
    }
}

#Preview {
    BottleCreationView(newlyCreatedBottleURL: .constant(nil))
}
