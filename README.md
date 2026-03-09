<div align="center">

  # Jack 🐇
  *Your Steam library on Mac, without compromise*

</div>

Jack is a macOS gaming launcher that brings your Steam library to Mac via Wine, with automatic game downloads, ProtonDB compatibility ratings, Steam Cloud sync, and dual Wine engine support (CrossOver + Apple GPTK with D3DMetal).

---

## Based on Whisky

Jack is a fork of [Whisky](https://github.com/Whisky-App/Whisky), the open source Wine launcher for macOS written in native SwiftUI. The original Whisky codebase is the foundation on which Jack's Steam-first experience is built.

> Jack is distributed under the GNU GPL v3 license. Jack inherits the same license and respects the terms of the original project.

---

## Features

- **Dual Wine engines** — CrossOver Wine (WineD3D/DXVK) and Apple GPTK (D3DMetal), switchable per game
- **Apple D3DMetal** — DirectX 11/12 to Metal translation via Game Porting Toolkit 3.0 for best UE4/UE5 compatibility
- **Integrated Steam login** — username, password and Steam Guard, no Steam.app dependency (direct CM network connection via Python)
- **Automatic game library** — owned games loaded via Steam licenses API, with ProtonDB Platinum/Gold/Silver/Bronze badges
- **Direct download** — install Windows games via SteamCMD, no Steam client required
- **Steam Cloud sync** — automatic save upload/download before and after each session
- **Goldberg DRM bypass** — emulates steam_api locally + SteamStub DRM stripping via Steamless
- **Guided onboarding** — setup wizard installs all dependencies (Rosetta, Wine, GPTK, Python, SteamCMD) automatically
- **Per-game launch options** — Wine engine, renderer (WineD3D/DXVK), windowed mode, all configurable from the game page

---

## Architecture

```
Jack/                  Main app (SwiftUI, macOS)
├── Views/Steam/       Steam library, game detail, cloud sync UI
├── Views/Setup/       Onboarding wizard, dependency installer
├── Views/Bottle/      Bottle configuration (Wine settings, DXVK, Metal)
│
JackKit/               Swift framework
├── Wine/              Wine.swift (dual engine launcher), GPTKInstaller.swift
├── JackWine/          CrossOver Wine installer
├── Steam/             SteamNativeService, SteamSessionManager, SteamCloudWebAPI
├── Jack/              Bottle, BottleSettings (WineEngine enum), BottleData
├── Utils/             DependencyManager, GoldbergService, SteamlessService
│
JackCloudSync/         Python CLI (jacksteam.py) — Steam CM network operations
JackCmd/               CLI companion
JackThumbnail/         Quick Look extension
```

### Wine Engine Stack

| Engine | Translation Path | Best For |
|--------|-----------------|----------|
| **GPTK (D3DMetal)** | DirectX to Metal (Apple D3DMetal 3.0) | UE4/UE5, DX11/DX12 games |
| **CrossOver + DXVK** | DirectX to Vulkan to MoltenVK to Metal | DX9/DX10/DX11, older titles |
| **CrossOver + WineD3D** | DirectX to OpenGL to Metal | Maximum compatibility, lower performance |

### Steam Integration (No Steam.app Required)

Jack connects directly to the Steam network via `jacksteam.py` (Python, using the `steam` library):
- **Authentication**: Login with username/password/2FA, session persisted via Keychain
- **Library**: Fetches owned app IDs from Steam licenses via CM network
- **Cloud Sync**: Downloads/uploads save files via Steam Cloud Web API
- **Game Download**: SteamCMD for game content delivery

---

## System Requirements

- CPU: Apple Silicon (M-series chip)
- OS: macOS Sonoma 14.0 or later
- Rosetta 2 (installed automatically)

---

## Getting Started

1. Open the app — the setup wizard installs all dependencies automatically
2. Enter your Steam username, password and Guard code
3. Your library loads with compatibility badges — click **Install** then **Play**
4. Switch Wine engine to GPTK (D3DMetal) for games that show black screens with CrossOver

---

## Dependencies (Auto-Installed)

| Dependency | Purpose |
|-----------|---------|
| Rosetta 2 | x86_64 translation on Apple Silicon |
| CrossOver Wine | Default Wine engine (WineD3D + DXVK) |
| GPTK 3.0 | Apple D3DMetal Wine engine |
| Python 3 + venv | Steam network operations (jacksteam.py) |
| SteamCMD | Game content download |
| Mono (optional) | Steamless DRM stripping |

---

## Credits

Jack would not exist without the work of these projects:

- **[Whisky](https://github.com/Whisky-App/Whisky)** by Isaac Marovitz — project foundation
- **[Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)** by Apple — D3DMetal
- **[GPTK builds](https://github.com/Gcenx/game-porting-toolkit)** by Gcenx
- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [CrossOver](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- [ProtonDB](https://www.protondb.com/) for compatibility data
- [Goldberg Steam Emulator](https://mr_goldberg.gitlab.io/goldberg_emulator/) for DRM bypass

Special thanks to Gcenx, ohaiibuzzle and Nat Brown for their support of the original Whisky project!

---

<table>
  <tr>
    <td>
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="./images/cw-dark.png">
          <img src="./images/cw-light.png" width="500">
        </picture>
    </td>
    <td>
        Jack (and Whisky) would not exist without CrossOver. Support CodeWeavers' work via their <a href="https://www.codeweavers.com/store?ad=1010">affiliate link</a>.
    </td>
  </tr>
</table>
