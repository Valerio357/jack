<div align="center">

  # Jack 🐇
  *I tuoi giochi Steam su Mac, senza compromessi*

</div>

Jack è un gaming launcher per macOS che porta la tua libreria Steam su Mac tramite Wine, mostrando la compatibilità ProtonDB per ogni gioco e permettendo di avviarli direttamente.

---

## Basato su Jack

Jack è un fork di [Jack](https://github.com/Jack-App/Jack), il launcher Wine open source per macOS scritto in SwiftUI nativo. Il codice originale di Jack è il fondamento su cui è costruita l'esperienza Steam-first di Jack.

> Jack è distribuito sotto licenza GNU GPL v3. Jack eredita la stessa licenza e rispetta i termini del progetto originale.

---

## Funzionalità Jack

- **Login Steam via OpenID** — accedi con il tuo account Steam in un click
- **Libreria giochi** — vedi tutti i tuoi titoli con icone e ore di gioco
- **Badge compatibilità ProtonDB** — Platinum / Gold / Silver / Bronze / Borked per ogni gioco
- **Avvio diretto** — `wine steam.exe -applaunch {appid}` senza configurazione manuale
- **Design Jack** — tema navy scuro `#0D1B2A`, accent blu elettrico `#4A90D9`, ispirato al logo del coniglio
- **Onboarding guidato** — 3 schermate per connettere Steam e iniziare a giocare

---

## Requisiti di sistema

- CPU: Apple Silicon (chip M-series)
- OS: macOS Sonoma 14.0 o successivo

---

## Come iniziare

1. Apri l'app — comparirà il wizard di onboarding al primo avvio
2. Accedi con Steam (OpenID) o inserisci il tuo Steam ID manualmente
3. Aggiungi la tua **Steam Web API key** in Impostazioni → Steam ([ottienila qui](https://steamcommunity.com/dev/apikey))
4. La tua libreria si carica automaticamente con i badge di compatibilità

---

## Struttura del progetto

```
Jack/            App principale (SwiftUI, macOS)
JackKit/         Framework Swift (Wine, Steam API, ProtonDB)
JackCmd/         CLI companion
JackThumbnail/   Quick Look extension
```

---

## Crediti e ringraziamenti

Jack non esisterebbe senza il lavoro di questi progetti:

- **[Jack](https://github.com/Jack-App/Jack)** di Isaac Marovitz — base del progetto
- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx e doitsujin
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [CrossOver 22.1.1](https://www.codeweavers.com/crossover) by CodeWeavers e WineHQ
- [ProtonDB](https://www.protondb.com/) per i dati di compatibilità
- D3DMetal by Apple

Special thanks a Gcenx, ohaiibuzzle e Nat Brown per il supporto al progetto originale Jack!

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
        Jack (e Jack) non esisterebbero senza CrossOver. Supporta il lavoro di CodeWeavers con il loro <a href="https://www.codeweavers.com/store?ad=1010">link affiliato</a>.
    </td>
  </tr>
</table>
