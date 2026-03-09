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
    @AppStorage("steamUsername") private var steamUsername = ""
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0

    private let totalSteps = 3

    var body: some View {
        ZStack {
            Color.jackBackground.ignoresSafeArea()

            ZStack {
                WelcomeStep(onNext: { advance() })
                    .opacity(currentStep == 0 ? 1 : 0)
                    .offset(x: currentStep == 0 ? 0 : (currentStep > 0 ? -40 : 40))

                SteamLoginStep(onNext: { advance() })
                    .opacity(currentStep == 1 ? 1 : 0)
                    .offset(x: currentStep == 1 ? 0 : (currentStep > 1 ? -40 : 40))

                ReadyStep(onFinish: {
                    hasCompletedOnboarding = true
                    dismiss()
                    // Initialize Wine prefix in background — don't block onboarding
                    Task.detached(priority: .background) {
                        if let bottle = try? await BottleVM.shared.createSharedSteamBottle() {
                            _ = try? await Wine.runWine(["wineboot", "-u"], bottle: bottle)
                        }
                    }
                })
                    .opacity(currentStep == 2 ? 1 : 0)
                    .offset(x: currentStep == 2 ? 0 : 40)
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
                Text("Welcome to Jack")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Jack brings your Steam library to Mac\nwith optimised Wine compatibility.")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingButton(label: "Get Started", isPrimary: true, action: onNext)
        }
        .padding(40)
    }
}

// MARK: - Step 2: Steam Login (detect running Steam session)

private struct SteamLoginStep: View {
    let onNext: () -> Void

    @AppStorage("steamUserID") private var steamUserID = ""
    @AppStorage("steamUsername") private var steamUsername = ""
    @State private var isDetecting = false
    @State private var errorMessage: String?
    @State private var loginSuccess = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.jackAccent)

            VStack(spacing: 8) {
                Text("Connect to Steam")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Make sure Steam is running and you're logged in.\nJack will detect your session automatically.")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            if isDetecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Color.jackAccent)
                    Text("Detecting Steam session…")
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
                Label("Connected!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.jackSuccess)
                    .font(.jackCaption)
            }

            Spacer()

            HStack(spacing: 12) {
                OnboardingButton(label: "Skip", isPrimary: false) {
                    onNext()
                }

                OnboardingButton(label: "Detect Steam", isPrimary: true) {
                    detectSteam()
                }
                .disabled(isDetecting)
            }
        }
        .padding(40)
    }

    private func detectSteam() {
        isDetecting = true
        errorMessage = nil
        loginSuccess = false

        Task {
            let running = await SteamNativeService.shared.isSteamRunning()
            if !running {
                NSWorkspace.shared.open(URL(string: "steam://")!)
                try? await Task.sleep(for: .seconds(4))
            }

            do {
                let (steamID, name) = try await SteamNativeService.shared.getCurrentUser()
                SteamSessionManager.shared.saveSession(result: SteamLoginResult(
                    steamID64: steamID,
                    accessToken: "",
                    refreshToken: "",
                    accountName: name
                ))
                steamUserID = steamID
                steamUsername = name.isEmpty ? steamUsername : name
                loginSuccess = true
                try? await Task.sleep(for: .seconds(1))
                onNext()
            } catch {
                errorMessage = "Steam is not running or not logged in.\nOpen Steam and sign in, then try again."
            }
            isDetecting = false
        }
    }
}

// MARK: - Step 3: Ready

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
                Text("You're all set!")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Your Steam library is ready to go.\nHappy gaming!")
                    .font(.jackBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingButton(label: "Open Library", isPrimary: true, action: onFinish)
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
