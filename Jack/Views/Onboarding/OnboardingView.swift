//
//  OnboardingView.swift
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

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("steamUserID") private var steamUserID = ""
    @AppStorage("steamAPIKey") private var steamAPIKey = ""
    @AppStorage("steamUsername") private var steamUsername = ""
    @State private var currentStep = 0

    private let totalSteps = 5

    var body: some View {
        ZStack {
            Color.jackBackground.ignoresSafeArea()

            ZStack {
                WelcomeStep(onNext: { advance() })
                    .opacity(currentStep == 0 ? 1 : 0)
                    .offset(x: currentStep == 0 ? 0 : (currentStep > 0 ? -40 : 40))

                ConnectSteamStep(onNext: { advance() })
                    .opacity(currentStep == 1 ? 1 : 0)
                    .offset(x: currentStep == 1 ? 0 : (currentStep > 1 ? -40 : 40))

                APIKeyStep(onNext: { advance() })
                    .opacity(currentStep == 2 ? 1 : 0)
                    .offset(x: currentStep == 2 ? 0 : (currentStep > 2 ? -40 : 40))

                SteamCredentialsStep(onNext: { advance() })
                    .opacity(currentStep == 3 ? 1 : 0)
                    .offset(x: currentStep == 3 ? 0 : (currentStep > 3 ? -40 : 40))

                ReadyStep(onFinish: {
                    Task {
                        if let bottle = try? await BottleVM.shared.createSharedSteamBottle() {
                            // Initialize Wine prefix now so games launch without delay later
                            _ = try? await Wine.runWine(["wineboot", "-u"], bottle: bottle)
                        }
                        hasCompletedOnboarding = true
                    }
                })
                    .opacity(currentStep == 4 ? 1 : 0)
                    .offset(x: currentStep == 4 ? 0 : 40)
            }
            .animation(.easeInOut(duration: 0.35), value: currentStep)

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { index in
                        Circle()
                            .fill(index == currentStep ? Color.jackAccent : Color.white.opacity(0.3))
                            .frame(width: 7, height: 7)
                            .animation(.easeInOut(duration: 0.2), value: currentStep)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .frame(width: 480, height: 520)
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.35)) {
            currentStep = min(currentStep + 1, totalSteps - 1)
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void

    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image("JackLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .scaleEffect(logoScale)
                .opacity(logoOpacity)
                .onAppear {
                    withAnimation(.spring(response: 0.65, dampingFraction: 0.65)) {
                        logoScale = 1.0
                        logoOpacity = 1.0
                    }
                }

            VStack(spacing: 10) {
                Text("Benvenuto su Jack")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Jack porta i tuoi giochi Steam su Mac\ncon compatibilità Wine ottimizzata.")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingButton(label: "Inizia", isPrimary: true, action: onNext)
        }
        .padding(40)
    }
}

// MARK: - Step 2: Connect Steam

private struct ConnectSteamStep: View {
    let onNext: () -> Void

    @AppStorage("steamUserID") private var steamUserID = ""
    @State private var isLoggingIn = false
    @State private var manualID = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.jackAccent)

            VStack(spacing: 8) {
                Text("Connetti Steam")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Accedi per caricare la tua libreria.")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Button {
                loginWithSteam()
            } label: {
                HStack(spacing: 8) {
                    if isLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "person.badge.key.fill")
                    }
                    Text(isLoggingIn ? "Apertura Steam…" : "Accedi con Steam")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.jackAccent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(isLoggingIn)

            HStack {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                Text("oppure")
                    .font(.jackCaption)
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize()
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }

            HStack(spacing: 8) {
                TextField("Steam ID (es. 76561198...)", text: $manualID)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.jackCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .tint(Color.jackAccent)

                Button("Usa") {
                    if !manualID.isEmpty {
                        steamUserID = manualID
                        onNext()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(manualID.isEmpty)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.jackCaption)
                    .foregroundStyle(Color.jackError)
            }

            Spacer()

            if !steamUserID.isEmpty {
                OnboardingButton(label: "Continua", isPrimary: true, action: onNext)
            }
        }
        .padding(40)
    }

    private func loginWithSteam() {
        isLoggingIn = true
        errorMessage = nil
        Task {
            defer { isLoggingIn = false }
            do {
                steamUserID = try await SteamAuthService.shared.login()
                onNext()
            } catch SteamAuthError.cancelled {
                // nothing
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Step 3: API Key

private struct APIKeyStep: View {
    let onNext: () -> Void

    @AppStorage("steamAPIKey") private var steamAPIKey = ""
    @State private var manualKey = ""
    @Environment(\.openURL) var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.jackAccent)

            VStack(spacing: 8) {
                Text("Steam API Key")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Necessaria per scaricare la lista dei tuoi giochi.")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                SecureField("Incolla qui la tua API Key", text: $manualKey)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.jackCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .tint(Color.jackAccent)

                Button("Come ottengo una API Key?") {
                    if let url = URL(string: "https://steamcommunity.com/dev/apikey") {
                        openURL(url)
                    }
                }
                .font(.jackCaption)
                .foregroundStyle(Color.jackAccent)
                .buttonStyle(.plain)
            }

            Spacer()

            OnboardingButton(label: "Continua", isPrimary: true) {
                if !manualKey.isEmpty {
                    steamAPIKey = manualKey
                    onNext()
                }
            }
            .disabled(manualKey.isEmpty)
        }
        .padding(40)
        .onAppear {
            manualKey = steamAPIKey
        }
    }
}

// MARK: - Step 4: Steam Credentials (for SteamCMD)

private struct SteamCredentialsStep: View {
    let onNext: () -> Void

    @AppStorage("steamUsername") private var steamUsername = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var loginSuccess = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.jackAccent)

            VStack(spacing: 8) {
                Text("Credenziali Steam")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Per scaricare i giochi, Jack usa SteamCMD.\nInserisci le tue credenziali Steam.")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("Username Steam", text: $username)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.jackCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .tint(Color.jackAccent)
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.jackCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .tint(Color.jackAccent)
                    .textContentType(.password)
            }

            if isTesting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Color.jackAccent)
                    Text("Configurazione SteamCMD...")
                        .font(.jackCaption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.jackCaption)
                    .foregroundStyle(Color.jackError)
                    .multilineTextAlignment(.center)
            }

            if loginSuccess {
                Label("Login riuscito!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.jackSuccess)
                    .font(.jackCaption)
            }

            Text("La password viene inviata solo a SteamCMD e non viene salvata da Jack.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 12) {
                OnboardingButton(label: "Salta", isPrimary: false) {
                    if !username.isEmpty {
                        steamUsername = username
                    }
                    onNext()
                }

                OnboardingButton(label: "Testa e Continua", isPrimary: true) {
                    testAndContinue()
                }
                .disabled(username.isEmpty || password.isEmpty || isTesting)
            }
        }
        .padding(40)
        .onAppear {
            username = steamUsername
        }
    }

    private func testAndContinue() {
        isTesting = true
        errorMessage = nil
        loginSuccess = false

        Task {
            do {
                try await SteamCMDService.shared.ensureInstalled()
                try await SteamCMDService.shared.login(username: username, password: password)
                steamUsername = username
                loginSuccess = true
                try? await Task.sleep(for: .seconds(1))
                onNext()
            } catch {
                errorMessage = error.localizedDescription
            }
            isTesting = false
        }
    }
}

// MARK: - Step 5: Ready

private struct ReadyStep: View {
    let onFinish: () -> Void

    @State private var showCheck = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.jackAccent.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.jackAccent)
                    .scaleEffect(showCheck ? 1.0 : 0.3)
                    .opacity(showCheck ? 1 : 0)
                    .onAppear {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                            showCheck = true
                        }
                    }
            }

            VStack(spacing: 8) {
                Text("Sei pronto!")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("La tua libreria Steam sta per apparire.\nBuona sessione!")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingButton(label: "Apri la libreria", isPrimary: true, action: onFinish)
        }
        .padding(40)
    }
}

// MARK: - Shared button

private struct OnboardingButton: View {
    let label: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isPrimary ? Color.jackAccent : Color.white.opacity(0.1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingView()
}
