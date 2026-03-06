//
//  SteamLibraryView.swift
//  Jack
//

import SwiftUI
import JackKit
import UniformTypeIdentifiers

// MARK: - Filter

enum GameFilter: String, CaseIterable {
    case all = "Tutti"
    case compatible = "Compatibili"
    case installed = "Installati"
}

// MARK: - Game State

enum GameInstallState: Equatable {
    case notInstalled
    case preparing
    case downloading(progress: Double)
    case installed
}

// MARK: - ViewModel

@MainActor
final class SteamLibraryViewModel: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var summaries: [Int: ProtonDBSummary] = [:]
    @Published var gameSizesGB: [Int: Double] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var filter: GameFilter = .all
    @Published var searchText = ""
    @Published var selectedGame: SteamGame?

    // Per-game installation states
    @Published var installStates: [Int: GameInstallState] = [:]
    // Per-game SteamCMD output log
    @Published var installLogs: [Int: String] = [:]

    var filtered: [SteamGame] {
        let base: [SteamGame]
        switch filter {
        case .all:
            base = games
        case .compatible:
            base = games.filter { (summaries[$0.appid]?.tier.isPlayable) == true }
        case .installed:
            base = games.filter {
                if case .installed = installStates[$0.appid] { return true }
                return false
            }
        }
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func loadGames(steamID64: String, username: String) async {
        guard !username.isEmpty else {
            errorMessage = "Configura le credenziali Steam nelle Impostazioni."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            self.games = try await SteamAPIClient.getOwnedGames(steamID64: steamID64, username: username)
            self.isLoading = false
            if self.games.isEmpty {
                errorMessage = "Nessun gioco trovato. Assicurati che la tua libreria Steam sia pubblica."
            } else {
                await checkAllGamesInstalled()
                await loadSummaries()
                prefetchInstalledSizes()
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    func checkAllGamesInstalled() async {
        var states: [Int: GameInstallState] = [:]
        for game in games {
            let dir = SteamCMDService.gameInstallDir(appID: game.appid)
            // A directory existing isn't enough — we create it before SteamCMD runs.
            // Only mark installed if an actual exe is present.
            let exe = SteamCMDService.findGameExecutable(in: dir)
            states[game.appid] = (exe != nil) ? .installed : .notInstalled
        }
        self.installStates = states
    }

    private func loadSummaries() async {
        let allGames = self.games
        Task.detached(priority: .background) {
            let batchSize = 10
            var index = 0
            while index < allGames.count {
                let nextIndex = min(index + batchSize, allGames.count)
                let batch = allGames[index..<nextIndex]
                await withTaskGroup(of: Void.self) { group in
                    for game in batch {
                        group.addTask {
                            let s = await ProtonDBClient.summary(for: game.appid)
                            await MainActor.run { self.summaries[game.appid] = s }
                        }
                    }
                }
                index = nextIndex
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func fetchSizeForSelectedGame() async {
        guard let game = selectedGame else { return }
        let appID = game.appid

        // Installed → real disk size (accurate, no API needed)
        if case .installed = (installStates[appID] ?? .notInstalled) {
            let dir = SteamCMDService.gameInstallDir(appID: appID)
            let size = await Task.detached(priority: .background) {
                SteamLibraryViewModel.dirSizeGB(dir)
            }.value
            self.gameSizesGB[appID] = size
            return
        }

        if gameSizesGB[appID] != nil { return }
        let size = await SteamAPIClient.getGameSizeGB(appID: appID)
        self.gameSizesGB[appID] = size  // nil = "N/D" (not "Sconosciuta")
    }

    /// Pre-calculate disk sizes for already-installed games immediately.
    private func prefetchInstalledSizes() {
        Task.detached(priority: .background) {
            for game in await self.games {
                let appID = game.appid
                if case .installed = await (self.installStates[appID] ?? .notInstalled) {
                    let size = SteamLibraryViewModel.dirSizeGB(SteamCMDService.gameInstallDir(appID: appID))
                    await MainActor.run { self.gameSizesGB[appID] = size }
                }
            }
        }
    }

    nonisolated static func dirSizeGB(_ url: URL) -> Double {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? URL {
            let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true, let s = vals?.fileSize { total += UInt64(s) }
        }
        return Double(total) / (1024 * 1024 * 1024)
    }
}

// MARK: - Main view

struct SteamLibraryView: View {
    let bottle: Bottle

    @AppStorage("steamUserID") private var steamUserID = ""
    @AppStorage("steamUsername") private var steamUsername = ""
    @StateObject private var viewModel = SteamLibraryViewModel()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("Cerca o Steam ID…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .tint(Color.jackAccent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                HStack(spacing: 8) {
                    ForEach(GameFilter.allCases, id: \.self) { f in
                        FilterPill(title: f.rawValue, isSelected: viewModel.filter == f) {
                            viewModel.filter = f
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Divider().opacity(0.1)

                ZStack {
                    if viewModel.isLoading && viewModel.games.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView().tint(Color.jackAccent)
                            Text("Ricezione dati da Steam...").font(.jackCaption).foregroundStyle(.secondary)
                        }
                    } else if let err = viewModel.errorMessage {
                        VStack(spacing: 12) {
                            Text(err).font(.jackCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Riprova") {
                                Task { await viewModel.loadGames(steamID64: steamUserID, username: steamUsername) }
                            }.buttonStyle(.bordered)
                        }.padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(viewModel.filtered) { game in
                                    GameListRow(
                                        game: game,
                                        summary: viewModel.summaries[game.appid],
                                        isSelected: viewModel.selectedGame?.appid == game.appid,
                                        installState: viewModel.installStates[game.appid] ?? .notInstalled
                                    ) {
                                        viewModel.selectedGame = game
                                        Task { await viewModel.fetchSizeForSelectedGame() }
                                    }
                                }
                            }
                            .padding(10)
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
            .background(Color.jackBackground)

            if let game = viewModel.selectedGame {
                GameDetailPanel(
                    game: game,
                    summary: viewModel.summaries[game.appid] ?? .unknown,
                    gameSizeGB: viewModel.gameSizesGB[game.appid],
                    steamUsername: steamUsername,
                    installState: Binding(
                        get: { viewModel.installStates[game.appid] ?? .notInstalled },
                        set: { viewModel.installStates[game.appid] = $0 }
                    ),
                    installLog: Binding(
                        get: { viewModel.installLogs[game.appid] ?? "" },
                        set: { viewModel.installLogs[game.appid] = $0 }
                    ),
                    bottle: bottle
                )
            } else {
                emptyDetailView
            }
        }
        .task {
            await viewModel.loadGames(steamID64: steamUserID, username: steamUsername)
        }
    }

    private var emptyDetailView: some View {
        ZStack {
            Color.jackBackground
            VStack(spacing: 16) {
                Image("JackLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .opacity(0.15)
                Text("Seleziona un gioco per iniziare")
                    .foregroundStyle(.white.opacity(0.2))
                    .font(.jackHeadline)
            }
        }
    }
}

// MARK: - Subviews

struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? Color.jackAccent : Color.white.opacity(0.08))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct GameListRow: View {
    let game: SteamGame
    let summary: ProtonDBSummary?
    let isSelected: Bool
    let installState: GameInstallState
    let onTap: () -> Void

    @State private var isHovered = false
    private var tier: CompatibilityTier { summary?.tier ?? .unknown }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AsyncImage(url: game.iconURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.05)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(tier.jackColor)
                            .frame(width: 8, height: 8)
                        Text(tier.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tier.jackColor)

                        if case .installed = installState {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.jackSuccess)
                        } else if case .downloading = installState {
                            ProgressView().controlSize(.mini).tint(Color.jackAccent)
                        }
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.jackAccent.opacity(0.2) : (isHovered ? Color.jackCardHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.jackAccent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct GameDetailPanel: View {
    let game: SteamGame
    let summary: ProtonDBSummary
    let gameSizeGB: Double?
    let steamUsername: String
    @Binding var installState: GameInstallState
    @Binding var installLog: String
    @ObservedObject var bottle: Bottle

    @AppStorage("steamUserID") private var steamUserID = ""
    @State private var launchError: String?
    @State private var windowedMode: Bool = false
    @State private var goldbergEnabled: Bool = false
    @State private var showUninstallConfirm: Bool = false
    @State private var backupStatus: String? = nil
    @State private var cloudSyncStatus: String? = nil

    var body: some View {
        ZStack {
            Color.jackBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AsyncImage(url: game.capsulePortraitURL ?? game.headerURL) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.white.opacity(0.05))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .clipped()
                    .overlay(
                        LinearGradient(colors: [.clear, .jackBackground], startPoint: .top, endPoint: .bottom)
                            .frame(height: 100),
                        alignment: .bottom
                    )

                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(game.name)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)

                            HStack(spacing: 8) {
                                StarRatingView(rating: summary.stars)
                                Text("\(summary.totalReports) reports")
                                    .font(.jackCaption)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }

                        // ── Info card ───────────────────────────────────
                        DetailCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Compatibilità ProtonDB")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.4))
                                            .textCase(.uppercase)
                                        Text(summary.tier.displayName)
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(summary.tier.jackColor)
                                        Text("\(summary.totalReports) report · \(Int(summary.stars * 10) / 10 == 0 ? "" : String(format: "%.1f", summary.stars))★")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                    Spacer()
                                    CompatBadgeLarge(tier: summary.tier)
                                }
                                Divider().background(Color.white.opacity(0.08))
                                HStack(spacing: 0) {
                                    MetadataLabel(title: "Dimensione", value: formattedSize)
                                    MetadataLabel(title: "Playtime", value: "\(game.playtimeHours)h")
                                    MetadataLabel(title: "Anti-cheat", value: "Nessuno")
                                }
                            }
                        }

                        // ── Opzioni di lancio ────────────────────────────
                        DetailCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("OPZIONI DI LANCIO")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.35))

                                rendererPicker

                                Divider().background(Color.white.opacity(0.06))

                                Toggle(isOn: $windowedMode) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "macwindow")
                                            .foregroundStyle(.white.opacity(0.6))
                                        Text("Modalità finestra")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("· fix schermo nero")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                }
                                .toggleStyle(.switch).tint(Color.jackAccent)
                                .onChange(of: windowedMode) { _, v in
                                    UserDefaults.standard.set(v, forKey: "windowed_\(game.appid)")
                                }

                                Toggle(isOn: $goldbergEnabled) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "shield.checkered")
                                            .foregroundStyle(Color.jackAccent)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Goldberg DRM Bypass")
                                                .font(.system(size: 12, weight: .medium))
                                            Text("Per giochi con DRM Steam (es. Dark Souls). Emula steam_api localmente.")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.3))
                                        }
                                    }
                                }
                                .toggleStyle(.switch).tint(Color.jackAccent)
                                .onChange(of: goldbergEnabled) { newValue in
                                    UserDefaults.standard.set(newValue, forKey: "goldberg_\(game.appid)")
                                }
                            }
                        }

                        // ── Salvataggi ───────────────────────────────────
                        if case .installed = installState {
                            savesCard
                        }

                        // ── Azioni ───────────────────────────────────────
                        VStack(spacing: 10) {
                            if case .downloading(let p) = installState {
                                downloadProgress(progress: p)
                            }

                            actionButton

                            if showCancelButton { cancelBtn }

                            if steamUsername.isEmpty && installState == .notInstalled {
                                Text("Configura lo username Steam nelle Impostazioni.")
                                    .font(.jackCaption)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .multilineTextAlignment(.center)
                            }

                            if let err = launchError {
                                Text(err)
                                    .font(.jackCaption)
                                    .foregroundStyle(Color.jackError)
                                    .multilineTextAlignment(.center)
                            }

                            if case .installed = installState { uninstallButton }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .onAppear {
            windowedMode = UserDefaults.standard.bool(forKey: "windowed_\(game.appid)")
            goldbergEnabled = UserDefaults.standard.bool(forKey: "goldberg_\(game.appid)")
        }
        .confirmationDialog(
            "Disinstallare \(game.name)?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Disinstalla", role: .destructive) { uninstallGame() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("I file di gioco verranno eliminati. Non potrai giocare senza reinstallare.")
        }
    }

    private var rendererPicker: some View {
        let dxvkBinding = Binding<Bool>(
            get: { bottle.settings.dxvk },
            set: { bottle.settings.dxvk = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text("RENDERER")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))

            Picker("Renderer", selection: dxvkBinding) {
                Label("WineD3D", systemImage: "cpu").tag(false)
                Label("Vulkan (DXVK)", systemImage: "bolt.fill").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(bottle.settings.dxvk
                 ? "Vulkan/Metal via DXVK. Consigliato per DirectX 9/10/11."
                 : "WineD3D software renderer. Più compatibile, meno performante.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var windowedToggle: some View { EmptyView() }

    private var uninstallButton: some View {
        Button(role: .destructive) {
            showUninstallConfirm = true
        } label: {
            Label("Disinstalla gioco", systemImage: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func uninstallGame() {
        let gameDir = SteamCMDService.gameInstallDir(appID: game.appid)
        // Restore original DLLs and exe before deleting (cleanup)
        if let exeURL = SteamCMDService.findGameExecutable(in: gameDir) {
            GoldbergService.shared.remove(from: exeURL.deletingLastPathComponent())
            SteamlessService.shared.restore(exe: exeURL)
        }
        try? FileManager.default.removeItem(at: gameDir)
        // Clear per-game prefs
        UserDefaults.standard.removeObject(forKey: "windowed_\(game.appid)")
        UserDefaults.standard.removeObject(forKey: "goldberg_\(game.appid)")
        installState = .notInstalled
    }

    private var goldbergToggle: some View { EmptyView() }

    private var formattedSize: String {
        guard let size = gameSizeGB else { return "N/D" }
        if size == 0.0 { return "N/D" }
        if size < 1.0 { return String(format: "%.0f MB", size * 1024) }
        return String(format: "%.1f GB", size)
    }

    // MARK: - Saves card

    private var savesCard: some View {
        let cloudCount = SteamCloudSyncService.shared.cloudSaveFileCount(
            appID: game.appid, steamID: steamUserID
        )
        let steamInstalled = SteamCloudSyncService.shared.isSteamMacInstalled

        return DetailCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("SALVATAGGI")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    // Steam Mac indicator
                    if steamInstalled {
                        Label(cloudCount > 0 ? "\(cloudCount) file su Steam Mac" : "Steam Mac",
                              systemImage: "checkmark.icloud")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(cloudCount > 0 ? Color.jackSuccess : .white.opacity(0.3))
                    } else {
                        Label("Steam Mac non trovato", systemImage: "xmark.icloud")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }

                // Local save directory
                let saveDir = savesDirectory
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(size: 12))
                    Text(saveDir?.lastPathComponent ?? "Nessun save locale")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(saveDir != nil ? 0.5 : 0.25))
                        .lineLimit(1)
                    Spacer()
                    if let dir = saveDir {
                        Button { NSWorkspace.shared.open(dir) } label: {
                            Text("Apri").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.jackAccent)
                        }.buttonStyle(.plain)
                    }
                }

                Divider().background(Color.white.opacity(0.06))

                // Sync buttons
                HStack(spacing: 8) {
                    if steamInstalled && cloudCount > 0 {
                        Button {
                            manualSyncFromCloud()
                        } label: {
                            Label("↓ Da Steam", systemImage: "icloud.and.arrow.down")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(Color.jackAccent.opacity(0.15))
                                .foregroundStyle(Color.jackAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }

                    Button { backupSaves() } label: {
                        Label("Backup", systemImage: "externaldrive.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(Color.white.opacity(0.07))
                            .foregroundStyle(.white.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(saveDir == nil)

                    Button { restoreSaves() } label: {
                        Label("Ripristina", systemImage: "externaldrive.badge.minus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(Color.white.opacity(0.07))
                            .foregroundStyle(.white.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasBackup)
                }

                // Status messages
                if let sync = cloudSyncStatus {
                    Text(sync).font(.system(size: 11)).foregroundStyle(Color.jackSuccess)
                }
                if let backup = backupStatus {
                    Text(backup).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }

                if !steamInstalled && !goldbergEnabled {
                    Text("Abilita Goldberg per usare save locali indipendenti da Steam.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    private func manualSyncFromCloud() {
        guard let exeURL = SteamCMDService.findGameExecutable(
            in: SteamCMDService.gameInstallDir(appID: game.appid)
        ) else {
            cloudSyncStatus = "⚠ Gioco non installato"
            return
        }
        let exeDir = exeURL.deletingLastPathComponent()
        let syncID = steamUserID
        let syncAppID = game.appid
        Task {
            do {
                let result = try SteamCloudSyncService.shared.syncToLocal(
                    appID: syncAppID, steamID: syncID, exeDir: exeDir
                )
                cloudSyncStatus = result.fileCount > 0
                    ? "✓ Importati \(result.fileCount) file da Steam Mac"
                    : "Nessun file trovato in Steam Mac"
            } catch {
                cloudSyncStatus = "⚠ \(error.localizedDescription)"
            }
        }
    }

    // Find save directory: userdata inside bottle (Steam standard) or Goldberg local
    private var savesDirectory: URL? {
        // 1. Goldberg local saves (if active)
        let gameDir = SteamCMDService.gameInstallDir(appID: game.appid)
        if let exeURL = SteamCMDService.findGameExecutable(in: gameDir) {
            let goldbergSaves = exeURL.deletingLastPathComponent()
                .appending(path: "steam_settings")
                .appending(path: "USERDATA")
            if FileManager.default.fileExists(atPath: goldbergSaves.path(percentEncoded: false)) {
                return goldbergSaves
            }
        }
        // 2. Standard Steam userdata in Wine bottle
        if !steamUserID.isEmpty, let id64 = Int64(steamUserID) {
            let steamID3 = id64 - 76561197960265728
            let udPath = bottle.url
                .appending(path: "drive_c")
                .appending(path: "Program Files (x86)")
                .appending(path: "Steam")
                .appending(path: "userdata")
                .appending(path: "\(steamID3)")
                .appending(path: "\(game.appid)")
                .appending(path: "remote")
            if FileManager.default.fileExists(atPath: udPath.path(percentEncoded: false)) {
                return udPath
            }
        }
        return nil
    }

    private var backupDir: URL {
        BottleData.steamCMDDir
            .appending(path: "saves")
            .appending(path: "\(game.appid)")
    }

    private var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupDir.path(percentEncoded: false))
    }

    private func backupSaves() {
        guard let src = savesDirectory else { return }
        let dest = backupDir
        Task {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: src, to: dest)
                let fmt = DateFormatter()
                fmt.dateStyle = .short; fmt.timeStyle = .short
                backupStatus = "Backup: \(fmt.string(from: Date()))"
            } catch {
                backupStatus = "Errore backup: \(error.localizedDescription)"
            }
        }
    }

    private func restoreSaves() {
        guard let dest = savesDirectory else { return }
        let src = backupDir
        Task {
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: src, to: dest)
                backupStatus = "Ripristino completato ✓"
            } catch {
                backupStatus = "Errore ripristino: \(error.localizedDescription)"
            }
        }
    }

    private var showCancelButton: Bool {
        switch installState {
        case .preparing, .downloading: return true
        default: return false
        }
    }

    private var cancelBtn: some View {
        Button {
            // Kill the SteamCMD process, not just update UI state
            SteamCMDService.shared.cancelCurrentInstall()
            installState = .notInstalled
            installLog = ""
        } label: {
            Text("Annulla download")
                .font(.jackCaption)
                .foregroundStyle(.red.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func downloadProgress(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Download via SteamCMD")
                    .font(.jackCaption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.jackCaption.bold())
                    .foregroundStyle(Color.jackAccent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.jackAccent)
                        .frame(width: geo.size.width * CGFloat(progress), height: 8)

                    Image(systemName: "hare.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .offset(x: (geo.size.width * CGFloat(progress)) - 10, y: -12)
                        .shadow(radius: 2)
                }
            }
            .frame(height: 20)

            if !installLog.isEmpty {
                Text(lastLogLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private var lastLogLine: String {
        let lines = installLog.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.last ?? ""
    }

    private var actionButton: some View {
        Button {
            switch installState {
            case .installed:
                launchGame()
            case .notInstalled:
                installGame()
            default:
                break
            }
        } label: {
            HStack {
                switch installState {
                case .preparing:
                    ProgressView().tint(.white).controlSize(.small)
                    Text("Preparazione SteamCMD...")
                case .downloading:
                    Text("Download in corso...")
                case .installed:
                    Image(systemName: "play.fill")
                    Text("Gioca")
                case .notInstalled:
                    Image(systemName: "arrow.down.circle.fill")
                    Text(steamUsername.isEmpty ? "Configura Steam prima" : "Installa Gioco")
                }
            }
            .fontWeight(.bold)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.jackAccent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.jackAccent.opacity(0.3), radius: 10)
        }
        .buttonStyle(.plain)
        .disabled({
            switch installState {
            case .preparing, .downloading: return true
            case .notInstalled: return steamUsername.isEmpty
            default: return false
            }
        }())
    }

    private func installGame() {
        guard !steamUsername.isEmpty else { return }
        installState = .preparing
        installLog = ""
        launchError = nil
        let appID = game.appid
        let username = steamUsername
        // Per-appID directory avoids any name-matching complexity
        let installDir = SteamCMDService.gameInstallDir(appID: appID)
        let expectedBytes: Double = {
            let size = gameSizeGB ?? 5.0
            return (size > 0 ? size : 5.0) * 1024 * 1024 * 1024
        }()

        Task {
            do {
                // Ensure SteamCMD is installed
                try await SteamCMDService.shared.ensureInstalled()
                installState = .downloading(progress: 0.01)

                try await SteamCMDService.shared.installGame(
                    appID: appID,
                    username: username,
                    installDir: installDir
                ) { line in
                    Task { @MainActor in
                        installLog += line

                        // Parse SteamCMD progress from output
                        // SteamCMD outputs lines like "Update state (0x61) downloading, progress: 45.23 (123456789 / 273456789)"
                        if let range = line.range(of: "progress:") {
                            let after = line[range.upperBound...]
                            let parts = after.trimmingCharacters(in: .whitespaces)
                                .components(separatedBy: "(")
                            if parts.count > 1 {
                                let byteParts = parts[1].replacingOccurrences(of: ")", with: "")
                                    .components(separatedBy: "/")
                                if byteParts.count == 2,
                                   let current = Double(byteParts[0].trimmingCharacters(in: .whitespaces)),
                                   let total = Double(byteParts[1].trimmingCharacters(in: .whitespaces)),
                                   total > 0 {
                                    let p = min(0.99, max(0.01, current / total))
                                    installState = .downloading(progress: p)
                                    return
                                }
                            }
                            // Fallback: use percentage from "progress: XX.XX"
                            if let pct = Double(parts[0].trimmingCharacters(in: .whitespaces)) {
                                let p = min(0.99, max(0.01, pct / 100.0))
                                installState = .downloading(progress: p)
                            }
                        }
                    }
                }

                installState = .installed
            } catch {
                print("SteamCMD install failed: \(error)")
                installState = .notInstalled
                installLog += "\nErrore: \(error.localizedDescription)"
            }
        }
    }

    private func launchGame() {
        launchError = nil
        let appID = game.appid
        let username = steamUsername
        Task {
            let installDir = SteamCMDService.gameInstallDir(appID: appID)

            guard let exeURL = SteamCMDService.findGameExecutable(in: installDir) else {
                launchError = "Eseguibile non trovato. Prova a reinstallare il gioco."
                installState = .notInstalled
                return
            }

            let exeDir = exeURL.deletingLastPathComponent()

            // --- Goldberg Steam Emulator (DRM bypass) ---
            if goldbergEnabled {
                do {
                    try await GoldbergService.shared.ensureInstalled()
                    try GoldbergService.shared.apply(
                        to: exeDir, appID: appID,
                        username: username.isEmpty ? "Player" : username,
                        steamID: UserDefaults.standard.string(forKey: "steamUserID") ?? ""
                    )
                } catch {
                    launchError = "Goldberg: \(error.localizedDescription)"
                    return
                }

                // Strip SteamStub DRM from exe (Goldberg only replaces the API layer,
                // SteamStub is a separate DRM wrapper on the exe itself)
                do {
                    try await SteamlessService.shared.stripIfNeeded(exe: exeURL)
                } catch {
                    launchError = "Steamless: \(error.localizedDescription)"
                    return
                }
            } else {
                // Restore originals if Goldberg was previously active
                GoldbergService.shared.remove(from: exeDir)
                SteamlessService.shared.restore(exe: exeURL)
                // Write steam_appid.txt for games with light DRM
                try? "\(appID)\n".write(
                    to: exeDir.appending(path: "steam_appid.txt"),
                    atomically: true, encoding: .utf8
                )
            }

            // --- Wine prefix init ---
            let system32 = bottle.url
                .appending(path: "drive_c").appending(path: "windows").appending(path: "system32")
            if !FileManager.default.fileExists(atPath: system32.path(percentEncoded: false)) {
                do {
                    _ = try await Wine.runWine(["wineboot", "-u"], bottle: bottle)
                } catch {
                    launchError = "Inizializzazione Wine fallita: \(error.localizedDescription)"
                    return
                }
            }

            // --- Install _CommonRedist (vcredist, DirectX) on first launch ---
            let redistMarker = installDir.appending(path: ".redist_installed")
            if !FileManager.default.fileExists(atPath: redistMarker.path(percentEncoded: false)) {
                let redistDir = installDir.appending(path: "_CommonRedist")
                if FileManager.default.fileExists(atPath: redistDir.path(percentEncoded: false)) {
                    // Collect vcredist exe paths synchronously, then run via Wine
                    let vcredistDir = redistDir.appending(path: "vcredist")
                    var vcExes: [URL] = []
                    if let vcEnum = FileManager.default.enumerator(at: vcredistDir, includingPropertiesForKeys: nil) {
                        while let file = vcEnum.nextObject() as? URL {
                            if file.lastPathComponent.lowercased().hasSuffix(".exe") {
                                vcExes.append(file)
                            }
                        }
                    }
                    for vcExe in vcExes {
                        _ = try? await Wine.runWine(
                            [vcExe.path(percentEncoded: false), "/q", "/norestart"],
                            bottle: bottle
                        )
                    }
                    // DirectX DXSETUP.exe (run silently)
                    let dxSetup = redistDir.appending(path: "DirectX").appending(path: "Jun2010").appending(path: "DXSETUP.exe")
                    if FileManager.default.fileExists(atPath: dxSetup.path(percentEncoded: false)) {
                        _ = try? await Wine.runWine(
                            [dxSetup.path(percentEncoded: false), "/silent"],
                            bottle: bottle
                        )
                    }
                    // Mark as done so we don't re-run every launch
                    try? "".write(to: redistMarker, atomically: true, encoding: .utf8)
                }
            }

            // --- DXVK ---
            if bottle.settings.dxvk {
                do {
                    try Wine.enableDXVK(bottle: bottle)
                } catch {
                    launchError = "DXVK non disponibile: \(error.localizedDescription). Prova WineD3D."
                    return
                }
            }

            // --- Virtual desktop (fix schermo nero) ---
            if windowedMode {
                _ = try? await Wine.runWine([
                    "reg", "add", "HKCU\\Software\\Wine\\Explorer",
                    "/v", "Desktop", "/t", "REG_SZ", "/d", "Default", "/f"
                ], bottle: bottle)
                _ = try? await Wine.runWine([
                    "reg", "add", "HKCU\\Software\\Wine\\Explorer\\Desktops",
                    "/v", "Default", "/t", "REG_SZ", "/d", "1280x720", "/f"
                ], bottle: bottle)
            } else {
                _ = try? await Wine.runWine([
                    "reg", "delete", "HKCU\\Software\\Wine\\Explorer",
                    "/v", "Desktop", "/f"
                ], bottle: bottle)
            }

            // --- Steam Cloud sync: Mac Steam → Goldberg (before launch) ---
            if goldbergEnabled && SteamCloudSyncService.shared.isSteamMacInstalled {
                let syncID = steamUserID
                let syncAppID = appID
                do {
                    let result = try SteamCloudSyncService.shared.syncToLocal(
                        appID: syncAppID, steamID: syncID, exeDir: exeDir
                    )
                    if result.fileCount > 0 {
                        cloudSyncStatus = "↓ Sync da Steam Mac: \(result.fileCount) file importati"
                    }
                } catch {
                    cloudSyncStatus = "⚠ Sync fallito: \(error.localizedDescription)"
                }
            }

            // --- Auto-backup saves before launch ---
            if let saveDir = savesDirectory {
                let dest = backupDir
                Task.detached {
                    let fm = FileManager.default
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path(percentEncoded: false)) { try? fm.removeItem(at: dest) }
                    try? fm.copyItem(at: saveDir, to: dest)
                }
            }

            // --- Goldberg: remove steam:// protocol handler to prevent game from relaunching via steam.exe ---
            if goldbergEnabled {
                _ = try? await Wine.runWine([
                    "reg", "delete", "HKCU\\Software\\Classes\\steam", "/f"
                ], bottle: bottle)
                _ = try? await Wine.runWine([
                    "reg", "delete", "HKCU\\Software\\Classes\\steamlink", "/f"
                ], bottle: bottle)
                // Remove TempAppCmdLine that points to steam.exe
                _ = try? await Wine.runWine([
                    "reg", "delete", "HKLM\\Software\\Valve\\Steam", "/v", "TempAppCmdLine", "/f"
                ], bottle: bottle)
                _ = try? await Wine.runWine([
                    "reg", "delete", "HKLM\\Software\\Wow6432Node\\Valve\\Steam", "/v", "TempAppCmdLine", "/f"
                ], bottle: bottle)
            }

            // --- Launch ---
            let steamEnv: [String: String] = [
                "SteamAppId": "\(appID)",
                "SteamGameId": "\(appID)"
            ]

            do {
                for await _ in try Wine.runWineProcess(
                    args: [exeURL.path(percentEncoded: false)],
                    bottle: bottle,
                    workingDirectory: exeDir,
                    environment: steamEnv
                ) { }
            } catch {
                launchError = "Errore avvio: \(error.localizedDescription)"
                return
            }

            // --- Steam Cloud sync: Goldberg → Mac Steam (after exit) ---
            if goldbergEnabled && SteamCloudSyncService.shared.isSteamMacInstalled {
                let syncID = steamUserID
                let syncAppID = appID
                let syncDir = exeDir
                Task.detached {
                    let result = try? SteamCloudSyncService.shared.syncToCloud(
                        appID: syncAppID, steamID: syncID, exeDir: syncDir
                    )
                    if let count = result?.fileCount, count > 0 {
                        await MainActor.run {
                            self.cloudSyncStatus = "↑ Sync verso Steam Mac: \(count) file salvati"
                        }
                    }
                }
            }
        }
    }

}

struct MetadataLabel: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.3)).textCase(.uppercase)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(18)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct CompatBadgeLarge: View {
    let tier: CompatibilityTier
    var icon: String {
        switch tier {
        case .platinum, .gold: return "checkmark.circle.fill"
        case .silver, .bronze: return "exclamationmark.circle.fill"
        case .borked: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 32))
            .foregroundStyle(tier.jackColor)
    }
}

struct StarRatingView: View {
    let rating: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: Double(star) <= rating ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(Double(star) <= rating ? Color.jackWarning : Color.white.opacity(0.2))
            }
        }
    }
}
