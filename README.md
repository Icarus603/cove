<p align="center"><img src="boringNotch/Assets.xcassets/logo2.imageset/logo2.png" width="128" alt="Cove"></p>

# Cove

One notch for the whole Mac: music and calendar, a file shelf, your coding agents, and plugins.
Built on open source, and it follows the system language (English, 简体中文, 繁體中文, 日本語 and more).

## Tabs

- **Home / Shelf** – media controls, calendar, mirror, HUDs, drag-and-drop shelf (from Boring.Notch).
- **Agents** – Claude Code, Codex, Gemini CLI, Cursor and 30+ other coding agents (from CodeIsland): live status, approve or
  deny tool calls, answer questions. Hooks are added automatically for the tools found on this Mac, after their
  configs are backed up; switch any off in **Settings → Agents**. A mascot beside the closed notch shows agent activity;
  opening the notch from it lands on this tab.
- **Plugins** – external programs that draw a tab; see [docs/PLUGINS.md](docs/PLUGINS.md).

## Layout

```
boringNotch/            the app (fork of Boring.Notch)
Packages/NotchKit       NotchModule + ModuleRegistry: the tab system
Packages/AgentHub       CodeIsland's engine, hook bridge and agent tab
Packages/PluginKit      the plugin host
Design/make_icons.swift draws the app and menu bar icons
```

Build: `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch build` (needs Xcode). Each package has tests: `swift test`.

## License

GPL-3.0 (see `LICENSE`). Includes MIT-licensed code from CodeIsland, NotchGames and NotchBasket; their notices are in
`Packages/*/LICENSE-*`.
