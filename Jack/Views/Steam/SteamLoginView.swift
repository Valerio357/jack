//
//  SteamLoginView.swift
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

struct SteamLoginView: View {
    @AppStorage("steamUserID") private var steamUserID = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.jackBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                Image("JackLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .onAppear {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                            logoScale = 1.0
                            logoOpacity = 1.0
                        }
                    }

                VStack(spacing: 8) {
                    Text("Jack")
                        .font(.system(size: 36, weight: .bold, design: .default))
                        .foregroundStyle(.white)

                    Text("Porta i tuoi giochi Steam su Mac")
                        .font(.jackBody)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                Button {
                    login()
                } label: {
                    HStack(spacing: 8) {
                        if isLoggingIn {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.fill")
                        }
                        Text(isLoggingIn ? "Signing in…" : "Accedi con Steam")
                            .fontWeight(.semibold)
                    }
                    .frame(minWidth: 200, minHeight: 44)
                    .background(Color.jackAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isLoggingIn)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.jackCaption)
                        .foregroundStyle(Color.jackError)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(32)
        }
    }

    private func login() {
        isLoggingIn = true
        errorMessage = nil
        Task {
            defer { isLoggingIn = false }
            do {
                steamUserID = try await SteamAuthService.shared.login()
            } catch SteamAuthError.cancelled {
                // nothing
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SteamLoginView()
        .frame(width: 480, height: 500)
}
