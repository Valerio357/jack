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

    func loadGames(steamID: String, apiKey: String) async {
        guard !steamID.isEmpty else { return }
        guard !apiKey.isEmpty else {
            errorMessage = "Aggiungi la Steam API Key nelle Impostazioni."
            return
        }

        isLoading = true
        errorMessage = nil

        let task = Task.detached(priority: .userInitiated) {
            return try await SteamAPIClient.getOwnedGames(steamID: steamID, apiKey: apiKey)
        }

        do {
            self.games = try await task.value
            self.isLoading = false
            if !self.games.isEmpty {
                await checkAllGamesInstalled()
                await loadSummaries()
            }
        } catch {
            self.errorMessage = "Errore API: \(error.localizedDescription)"
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
        if gameSizesGB[game.appid] != nil { return }

        let size = await SteamAPIClient.getGameSizeGB(appID: game.appid)
        self.gameSizesGB[game.appid] = size ?? 0.0
    }
}

// MARK: - Main view

struct SteamLibraryView: View {
    let bottle: Bottle

    @AppStorage("steamUserID") private var steamUserID = ""
    @AppStorage("steamAPIKey") private var steamAPIKey = ""
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
                                Task { await viewModel.loadGames(steamID: steamUserID, apiKey: steamAPIKey) }
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
            await viewModel.loadGames(steamID: steamUserID, apiKey: steamAPIKey)
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

    @State private var launchError: String?
    @State private var windowedMode: Bool = false
    @State private var goldbergEnabled: Bool = false
    @State private var showUninstallConfirm: Bool = false

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

                        DetailCard {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Compatibilità ProtonDB")
                                            .font(.jackCaption)
                                            .foregroundStyle(.white.opacity(0.5))
                                        Text(summary.tier.displayName)
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(summary.tier.jackColor)
                                    }
                                    Spacer()
                                    CompatBadgeLarge(tier: summary.tier)
                                }

                                Divider().background(Color.white.opacity(0.1))

                                Grid(alignment: .leading, verticalSpacing: 12) {
                                    GridRow {
                                        MetadataLabel(title: "DirectX", value: "11/12")
                                        MetadataLabel(title: "Anti-cheat", value: "Nessuno")
                                    }
                                    GridRow {
                                        MetadataLabel(title: "Dimensione", value: formattedSize)
                                        MetadataLabel(title: "Playtime", value: "\(game.playtimeHours)h")
                                    }
                                }
                            }
                        }

                        VStack(spacing: 16) {
                            if case .downloading(let p) = installState {
                                downloadProgress(progress: p)
                            }

                            rendererPicker
                            windowedToggle
                            goldbergToggle

                            actionButton

                            if showCancelButton {
                                cancelBtn
                            }

                            if steamUsername.isEmpty && installState == .notInstalled {
                                Text("Configura lo username Steam nelle Impostazioni per installare giochi.")
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

                            if case .installed = installState {
                                uninstallButton
                            }
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

    private var windowedToggle: some View {
        Toggle(isOn: $windowedMode) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Modalità finestra", systemImage: "macwindow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Fix schermo nero. Usa una finestra macOS invece del fullscreen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .toggleStyle(.switch)
        .tint(Color.jackAccent)
        .onChange(of: windowedMode) { _, value in
            UserDefaults.standard.set(value, forKey: "windowed_\(game.appid)")
        }
    }

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
        // Restore original DLLs before deleting (cleanup)
        if let exeURL = SteamCMDService.findGameExecutable(in: gameDir) {
            GoldbergService.shared.remove(from: exeURL.deletingLastPathComponent())
        }
        try? FileManager.default.removeItem(at: gameDir)
        // Clear per-game prefs
        UserDefaults.standard.removeObject(forKey: "windowed_\(game.appid)")
        UserDefaults.standard.removeObject(forKey: "goldberg_\(game.appid)")
        installState = .notInstalled
    }

    private var goldbergToggle: some View {
        Toggle(isOn: $goldbergEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Modalità offline (Goldberg)", systemImage: "person.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Sostituisce steam_api.dll con Goldberg Emu. Fix DRM per giochi posseduti.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .toggleStyle(.switch)
        .tint(Color.jackAccent)
        .onChange(of: goldbergEnabled) { _, value in
            UserDefaults.standard.set(value, forKey: "goldberg_\(game.appid)")
        }
    }

    private var formattedSize: String {
        guard let size = gameSizeGB else { return "Recupero…" }
        if size == 0.0 { return "Sconosciuta" }
        return "\(Int(size)) GB"
    }

    private var showCancelButton: Bool {
        switch installState {
        case .preparing, .downloading: return true
        default: return false
        }
    }

    private var cancelBtn: some View {
        Button {
            installState = .notInstalled
        } label: {
            Text("Annulla")
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

            // --- Goldberg Steam Emulator ---
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
            } else {
                // Restore originals if Goldberg was previously active
                GoldbergService.shared.remove(from: exeDir)
                // Fallback: write plain steam_appid.txt for soft DRM
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

            // --- Launch ---
            let start = Date()
            do {
                for await _ in try Wine.runWineProcess(
                    args: [exeURL.path(percentEncoded: false)],
                    bottle: bottle,
                    workingDirectory: exeDir
                ) { }
            } catch {
                launchError = "Errore avvio: \(error.localizedDescription)"
                return
            }

            // If the game exited in under 5 seconds it almost certainly hit a DRM check
            let duration = Date().timeIntervalSince(start)
            if duration < 5 {
                launchError = "Il gioco si è chiuso subito (\(Int(duration))s). Probabile causa: DRM Steam. Alcuni giochi richiedono Steam in esecuzione."
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
