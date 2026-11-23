<div align="center">

<img src="docs/images/banner.png" alt="Cove: one notch for the whole Mac" width="100%">

<br>

[![Latest release](https://img.shields.io/github/v/release/Icarus603/cove?style=flat-square&color=4A5EE8&label=release)](https://github.com/Icarus603/cove/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple&logoColor=white)](#install)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-111?style=flat-square)](#install)
[![License](https://img.shields.io/badge/license-GPL--3.0-2ea44f?style=flat-square)](LICENSE)

**English** · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

[Why Cove](#why-cove) · [Install](#install) · [Using Cove](#using-cove) · [Features](#features) · [Build](#build-from-source) · [Plugins](docs/PLUGINS.md)

</div>

---

## Why Cove

The notch is the one piece of screen that is always there and never used. Cove turns it into a small, quiet dashboard: it
opens when you point at it and gets out of the way when you leave. Everything lives in tabs, so you only see what you reach
for.

Three rules shape it:

- **Your files stay where they are.** The player and photo libraries remember a file's location (and follow it if you move
  it). Nothing is copied, moved or locked into a private library, and removing something from a library never deletes the file.
- **Read-only where money is involved.** Markets shows prices and, with a read-only key, your balances. Cove never places an
  order and never asks for a key that could.
- **It looks like you chose it.** Every control follows your own accent colour, and the interface follows the system language.

## Install

<img src="docs/images/icon.png" width="112" align="right" alt="Cove app icon">

Requires **macOS 14 or later**. Built for Apple Silicon.

1. Download `Cove.dmg` from the [latest release](https://github.com/Icarus603/cove/releases/latest) and drag Cove to
   Applications.
2. Cove is not notarized by Apple, so the first time: right-click Cove → **Open**, or allow it in
   **System Settings → Privacy & Security**.
3. After that Cove updates itself through [Sparkle](https://sparkle-project.org): it checks at launch and every hour, and
   installs an update when it will not interrupt you (notch closed, settings closed, no agent waiting for you).
   **About → Check for Updates** forces a check.

## Using Cove

### The first minute

1. **Launch Cove.** A short welcome asks for the permissions the optional features need (camera for the mirror, calendar and
   reminders, accessibility, music). Grant only what you will use; everything else works without them.
2. **Open the notch.** Point at the notch and hold for a moment; it opens. Move away and it closes. (You can change this to
   a click in **Settings → General**.)
3. **Switch tabs** with the icons along the top: Home, Shelf, Player, Photos, Markets, Agents.
4. **Open Settings** with the gear in the open notch, or the Cove icon in the menu bar. **Settings → Modules** chooses which
   tabs you see, and the pages under **Features** set up each one.
5. **Make it yours.** **Settings → Advanced** has a custom accent colour; every sidebar, button and focus ring follows it.

### Play your own audio and video (Player)

1. Open the **Player** tab and press **＋ Add**. Choose files or whole folders (subfolders are included). Cove reads tags and
   cover art for you.
2. **Double-click** a title to play it. Use the **⋯** that appears on a row for Play next, Add to queue, Add to playlist,
   Show in Finder and more.
3. Filter with **All / Audio / Video**, search at the top, and sort with the ⇅ menu.
4. **Make a playlist.** Choose **Playlists → New playlist…**, name it, then press **＋** on what to put in. Or, in the
   Add dialog, pick **Also put in playlist** so new files go straight into one.
5. **Select many at once:** click, **Shift**-click for a range, **Command**-click for single rows. A bar appears with
   *Add to playlist*, *Add to queue* and *Select all*.
6. **Put a playlist in order:** the ⇅ menu inside a playlist sorts it by file name, by title or backwards; the **⋯** on a
   row moves it up or down.
7. **Video** plays in the notch. Double-click it, press **F**, or use the button to go full screen; pop it out into its
   own window with the arrow button. Controls and the pointer fade when you stop moving.
8. **For bigger jobs,** open **⋯ → Manage Library…** for a full window: a table sorted by any column, select all, remove many
   at once, and every playlist in the sidebar.

> A file Cove cannot add (mkv, webm, or a video encoded as VP9 or AV1) is listed with the reason and how to convert it.
> A file you moved is found again automatically; one that is gone shows *file missing* with a **Locate…** button.

### Keep your photos in albums (Photos)

1. Open the **Photos** tab and press **＋ Add**. Choose photos or folders. In the dialog, **Also put in album** files them
   into an existing album, or a new one you name, as they come in.
2. The tab shows a quick-look strip. Press **Open Photos** for the large window.
3. **Show your albums** with the sidebar button at the left of the toolbar. Make one with **New Album**, or select photos and
   use **Add to album**. Select with a click, **Shift** for a range, **Command** for single photos, or **Select All**.
4. **Arrange an album by hand.** Inside an album, drag a photo in front of another, or select photos and choose
   **Arrange → Move to the start / earlier / later / to the end**. New photos go to the end. The ⇅ menu can switch to date, name
   or recently added instead.
5. **Double-click** a photo to open it as a plain big picture. Move the mouse to bring up the few controls.

| In the viewer | |
| --- | --- |
| ← / → | Previous / next photo |
| Space | Start or stop a slideshow |
| Double-click, **+** / **−**, pinch | Zoom; **0** fits, **1** actual size |
| **I** | Info (name, date, size, albums, folder) |
| **F** | Full screen |
| Esc | Zoom out, then close |

### Watch the markets (Markets)

1. Open the **Markets** tab. Add pairs with the search; they appear as live cards.
2. Click a card for the chart: scroll or pinch to zoom, drag through history, hover for the crosshair and details. Switch the
   interval, and turn on SMA, EMA, RSI, MACD or Bollinger bands.
3. **Settings → Markets** has the rising and falling colours, a *Hide balance* switch and an optional **read-only** Binance API
   key to show your balances. Cove cannot trade, and you should never give it a key that can.

### Watch your coding agents (Agents)

1. Start Claude Code, Codex, Gemini CLI, Cursor or any of 30+ other agents in a terminal or editor as usual.
2. A mascot beside the closed notch shows what they are doing. Open the notch from it to land on the **Agents** tab: every
   session with its state, and any tool call or question waiting for you.
3. **Approve or deny** a tool call, or answer a question, right there.
4. **Settings → Agents → Connections** lists the tools Cove found on this Mac. Hooks are added for them after their configs are backed up,
   and you can switch any off.

### Move files through the Shelf

**Drag files onto the notch** to park them on the Shelf, then drag them out into another app, or send them with AirDrop. In
Cove, dropping always means the Shelf; the Player and Photos libraries use their **Add** buttons.

### Plugins

A plugin is a folder with a manifest and an executable that draws a tab of its own. Add one with **Settings → Modules →
Plugins → Add plugin…** (or drop its folder into `~/Library/Application Support/Cove/Plugins/`) and it appears in the notch.
[docs/PLUGINS.md](docs/PLUGINS.md) shows how to write one.

## Features

| Tab | What it is |
| --- | --- |
| **Home** | Now-playing controls, calendar, mirror and system HUDs. |
| **Shelf** | A drag-and-drop shelf for files, with AirDrop. |
| **Player** | An audio and video library with playlists, a queue, a pop-out window and a mini player. |
| **Photos** | A reference-based photo library with your own albums, a large window and a quick-look strip. |
| **Markets** | Live Binance prices and candlestick charts. |
| **Agents** | Live status of Claude Code, Codex, Gemini CLI, Cursor and 30+ other coding agents. |
| **Plugins** | External programs that draw a tab of their own. |

### Player

- **Formats:** mp3, m4a, aac, flac, wav, aiff, caf, mp4, m4v and mov, played by the system's media engine.
- **Library:** files or whole folders; tags and cover art read for you; search, filter, sort; resumes where each file was left.
- **Playlists:** arrange by hand, by file name or by title; add straight into one from the Add dialog; multi-select with Shift
  and Command.
- **Playing:** shuffle, repeat, speed, volume, audio and subtitle tracks, an up-next queue.
- **Video:** in the notch, in a resizable pop-out window, or full screen, with controls that fade.
- **Mini player:** a small cover (or the live video) beside the closed notch while something plays.
- **Library window:** a full table for bulk work.

### Photos

- **Albums are yours.** No timeline, no folder guessing: create albums, add in bulk, and arrange each one by hand.
- **Formats:** JPEG, PNG, HEIC, TIFF, GIF (animated), WebP and BMP. RAW and design files are named and left alone.
- **Viewer:** zoom, pan, actual size, slideshow, info, full screen; an open photo shows only the picture.
- **Built for large libraries:** a SQLite database with thumbnails made on demand, so the list opens at once (a 3,000-photo
  import takes under a second in tests).
- Missing files (a drive that is not connected) are shown as missing, never dropped.

### Markets

- Live prices and candlestick charts from Binance, updated from the per-trade stream and a local order book, not polled.
- Zoomable, scrollable history with a crosshair and detail tooltip; SMA, EMA, RSI, MACD and Bollinger bands.
- A searchable watchlist; configurable rising and falling colours.
- Read-only. **Cove cannot trade.**

### Agents

From [CodeIsland](https://github.com/wxtsky/CodeIsland): live status for Claude Code, Codex, Gemini CLI, Cursor and 30+ other
coding agents; approve tool calls and answer questions from the notch; a mascot beside the closed notch; opening the notch
from it lands on this tab.

### Home, Shelf and Plugins

Media controls, calendar, mirror, HUDs and the drag-and-drop shelf come from
[Boring.Notch](https://github.com/TheBoredTeam/boring.notch).

### Everywhere

- **Updates itself** (see [Install](#install)).
- **Your accent colour** is used by every sidebar, button and focus ring.
- **Languages:** English, 简体中文, 繁體中文 and more; it follows the system language.

## Build from source

You need Xcode.

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch build
```

Each package has its own tests: `swift test` inside `Packages/NotchKit`, `Packages/AgentHub` and `Packages/PluginKit`.
Headless checks for the Player and Photos logic live in `scripts/` (`test-player.sh`, `test-indicators.sh`) and in the
screenshot harness (`scripts/shots.sh`). `python3 scripts/make_banner.py` redraws the banner above.

### Layout

```
boringNotch/              the app (a fork of Boring.Notch)
  modules/                Player, Photos, Markets and the other tabs
Packages/NotchKit         NotchModule and ModuleRegistry: the tab system
Packages/AgentHub         CodeIsland's engine, hook bridge and agent tab
Packages/PluginKit        the plugin host
Design/make_icons.swift   draws the app and menu bar icons
scripts/                  packaging, update feed, banner and test scripts
docs/                     the plugin guide and README images
```

## Releasing

```bash
scripts/package.sh                 # Release build, signed, build/Cove.dmg
scripts/make-appcast.sh 1.0.0      # build/appcast.xml, signed with the Sparkle key in your Keychain
gh release create v1.0.0 build/Cove.dmg build/appcast.xml --title "Cove 1.0.0"
```

The update feed is `releases/latest/download/appcast.xml`, so every release uploads both files. Keep the Sparkle private key:
losing it means installed copies can no longer verify updates. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` before
each release.

## License

[GPL-3.0](LICENSE). Includes MIT-licensed code from CodeIsland; its notice is in `Packages/AgentHub/LICENSE-CodeIsland`.

## Credits

Cove is built on [Boring.Notch](https://github.com/TheBoredTeam/boring.notch) and
[CodeIsland](https://github.com/wxtsky/CodeIsland), and uses [Sparkle](https://sparkle-project.org) for updates. Thanks to
their authors.
