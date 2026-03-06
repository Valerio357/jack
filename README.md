<div align="center">

  # Jack 🐇
  *Your Steam library on Mac, without compromise*

</div>

Jack is a macOS gaming launcher that brings your Steam library to Mac via Wine, with automatic game downloads via SteamCMD, ProtonDB compatibility ratings, and Goldberg support for Steam DRM bypass.

---

## Based on Whisky

Jack is a fork of [Whisky](https://github.com/Whisky-App/Whisky), the open source Wine launcher for macOS written in native SwiftUI. The original Whisky codebase is the foundation on which Jack's Steam-first experience is built.

> Jack is distributed under the GNU GPL v3 license. Jack inherits the same license and respects the terms of the original project.

---

## Features

- **Integrated Steam login** — username, password and Steam Guard in a single step, no manual configuration
- **Automatic game library** — owned games are loaded via SteamCMD, no API key required
- **ProtonDB compatibility badges** — Platinum / Gold / Silver / Bronze / Borked for each game
- **Direct download** — install Windows games via SteamCMD without opening Steam
- **Goldberg DRM bypass** — emulates steam_api locally for games with Steam DRM
- **Guided onboarding** — 3 screens to connect your Steam account and start playing

---

## System Requirements

- CPU: Apple Silicon (M-series chip)
- OS: macOS Sonoma 14.0 or later

---

## Getting Started

1. Open the app — the onboarding wizard will appear on first launch
2. Enter your username, password and Steam Guard code to authenticate
3. Your Steam library loads automatically with compatibility badges
4. Click **Install Game** to download and **Play** to launch via Wine

---

## Project Structure

```
Jack/            Main app (SwiftUI, macOS)
JackKit/         Swift framework (Wine, Steam, ProtonDB)
JackCmd/         CLI companion
JackThumbnail/   Quick Look extension
```

---

## Credits

Jack would not exist without the work of these projects:

- **[Whisky](https://github.com/Whisky-App/Whisky)** by Isaac Marovitz — project foundation
- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [CrossOver 22.1.1](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- [ProtonDB](https://www.protondb.com/) for compatibility data
- D3DMetal by Apple

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
