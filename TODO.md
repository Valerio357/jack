# Jack - TODO

## 1. DRM Handling
- [x] Goldberg Steam Emulator (replaces steam_api.dll)
  - [x] Auto-download and install Goldberg v0.2.5
  - [x] Recursive DLL replacement (handles UE4 nested paths)
  - [x] steam_settings/ with appid, username, steamid
  - [x] Backup/restore original DLLs
- [x] Steamless (SteamStub DRM stripper)
  - [x] Native PE patching (no Wine/.NET dependency)
  - [x] Auto-backup original exe
- [ ] Denuvo detection
  - [ ] Detect Denuvo-protected games (PE section analysis or known appid list)
  - [ ] Show warning: "This game uses Denuvo DRM and is unlikely to work"

## 2. Anti-Cheat Handling
- [ ] Auto-detect anti-cheat presence
  - [ ] Scan for EasyAntiCheat/ folder
  - [ ] Scan for BattlEye/ folder or BEService.exe
  - [ ] Scan for vgk.sys (Vanguard)
- [ ] Anti-cheat bypass toggle (per-game)
  - [ ] Rename EasyAntiCheat/ to EasyAntiCheat_disabled/
  - [ ] Rename BattlEye/ to BattlEye_disabled/
  - [ ] Restore on toggle off
- [ ] Show warning in game detail panel
  - [ ] "This game uses EasyAntiCheat. Online play will not work."
  - [ ] "This game uses BattlEye. Online play will not work."
  - [ ] "This game uses Vanguard anti-cheat and cannot run under Wine."

## 3. Redistributables Auto-Install
- [ ] Detect _CommonRedist/ folder in game directory
  - [ ] DirectX (Jun2010/DXSETUP.exe)
  - [ ] Visual C++ Redistributable (vcredist)
  - [ ] .NET Framework
- [ ] Auto-run installers silently on first launch
  - [ ] Run with /silent or /quiet flags
  - [ ] Track installed redists per bottle (avoid re-running)
- [ ] Manual trigger from game detail panel ("Install Prerequisites")

## 4. Per-Game Launch Options
- [ ] Custom launch arguments (free text field)
  - [ ] Common flags: -noeac, -dx11, -dx12, -windowed, -skipintro
- [ ] Environment variables (WINEDLLOVERRIDES, etc.)
- [ ] Custom exe selection (override auto-detected exe)
- [ ] Save per-game settings to disk (JSON per appid)

## 5. Known Issues / Compatibility Database
- [ ] Local database of known issues per appid
  - [ ] Anti-cheat type
  - [ ] DRM type (Denuvo, Steam, none)
  - [ ] Required launch flags
  - [ ] Recommended renderer (WineD3D vs DXVK)
  - [ ] Known crashes and workarounds
- [ ] Show warnings/tips in game detail panel before launch
- [ ] Pull ProtonDB reports for specific tips (already have tier data)

## 6. Game Launch Improvements
- [ ] Auto-detect and launch correct exe
  - [ ] Prefer game exe over launcher exe when anti-cheat is disabled
  - [ ] Handle UE4 games (skip DBFighterZ.exe, run RED-Win64-Shipping.exe directly)
- [ ] Wine prefix per game (isolate bottle configs)
- [ ] Pre-launch checks
  - [ ] Verify required DLLs exist
  - [ ] Check disk space
  - [ ] Validate Wine prefix is initialized

## 7. UI Improvements
- [ ] Three-dot menu on game card (launch options modal)
- [ ] Installation progress bar (SteamCMD download percentage)
- [ ] Game log viewer (Wine output for debugging)
- [ ] Toast notifications for background operations (install complete, etc.)

## 8. Save Management & Steam Cloud Sync
- [ ] Steam Cloud sync (real Steam Cloud <-> Goldberg local saves)
  - [ ] Use SteamCMD to download cloud saves (`app_cloud_download`)
  - [ ] Use SteamCMD to upload local saves (`app_cloud_upload`)
  - [ ] Detect per-game save paths (AppInfo VDF or known paths database)
  - [ ] Map Goldberg local save paths to Steam Cloud paths
  - [ ] Auto-sync on game exit (upload changed saves)
  - [ ] Auto-sync on game launch (download latest cloud saves)
  - [ ] Conflict resolution UI (local vs cloud, show timestamps)
- [ ] Backup/restore UI
  - [ ] One-click backup saves to zip
  - [ ] Restore from backup
  - [ ] Show save file timestamps and sizes
- [ ] Manual save import/export (for sharing between devices)

## 9. Wine / Runtime
- [ ] Auto-install Wine if not present
- [ ] Support multiple Wine versions (user-selectable)
- [ ] DXVK version management (update separately from Wine)
- [ ] Winetricks integration for missing components (d3dcompiler, dotnet, etc.)
