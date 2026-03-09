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

    // Login form fields
    @State private var username = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var needs2FA = false

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

                    Text("Sign in with your Steam account")
                        .font(.jackBody)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                // Login form
                VStack(spacing: 12) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .frame(maxWidth: 280)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .frame(maxWidth: 280)

                    TextField("Steam Guard Code", text: $twoFactorCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

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
                            Text(isLoggingIn ? "Signing in…" : "Sign in")
                                .fontWeight(.semibold)
                        }
                        .frame(minWidth: 200, minHeight: 44)
                        .background(Color.jackAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
                }

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
        let pw = password
        let code = twoFactorCode
        let user = username
        Task {
            defer { isLoggingIn = false }

            do {
                // Step 1: SteamCMD login first to cache credentials (uses the 2FA code)
                do {
                    try await SteamCMDService.shared.ensureInstalled()
                    _ = try await SteamCMDService.shared.login(
                        username: user,
                        password: pw,
                        steamGuardCode: code.isEmpty ? nil : code
                    )
                } catch {
                    // Non-critical
                }

                // Step 2: jacksteam.py login (Web API auth — gets its own 2FA validation)
                let result = try await SteamNativeService.shared.login(
                    username: user,
                    password: pw,
                    twoFactorCode: code.isEmpty ? nil : code
                )

                let session = SteamSessionManager.shared
                session.saveSession(result: result)
                session.savePassword(pw)
                steamUserID = result.steamID64

                // Clear sensitive fields
                password = ""
                twoFactorCode = ""
            } catch let error as SteamNativeService.SteamNativeError {
                switch error {
                case .loginFailed(let msg):
                    if msg.contains("2FA") || msg.contains("code required") {
                        needs2FA = true
                        errorMessage = "Enter your Steam Guard code and try again."
                    } else {
                        errorMessage = msg
                    }
                default:
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SteamLoginView()
        .frame(width: 480, height: 600)
}
