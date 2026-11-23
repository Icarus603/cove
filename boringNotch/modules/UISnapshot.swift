//
//  UISnapshot.swift
//  boringNotch
//
//  Debug builds only: with COVE_SNAPSHOT_DIR set, the app renders its own windows to PNGs
//  (onboarding steps, every notch tab, every game) and quits. Needs no screen-recording permission,
//  because a process may read back its own views.
//

#if DEBUG
import AgentHub
import AppKit
import Combine
import NotchKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum UISnapshot {
    /// With COVE_WINDOW_REPORT set, lists every window a few seconds after launch (to catch ones that are too big).
    static func reportWindowsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT"] else { return }
        Task { @MainActor in
            if ProcessInfo.processInfo.environment["COVE_REPORT_SETTINGS"] == "1" { SettingsWindowController.shared.showWindow() }
            // Optionally watch the notch for a few seconds (first launch shows a welcome animation).
            if let pngDir = ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT_PNG_DIR"] {
                try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true)
                for tick in 1...(Int(ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT_TICKS"] ?? "") ?? 6) {
                    await sleep(1)
                    if let window = NSApp.windows.first(where: { $0 is BoringNotchSkyLightWindow }), let content = window.contentView {
                        snapshot(content, to: "\(pngDir)/t\(tick).png")
                        try? "t\(tick): window=\(window.frame) vm=\(String(describing: AppDelegate.current?.vm.notchSize)) state=\(String(describing: AppDelegate.current?.vm.notchState))\n"
                            .appendLine(to: pngDir + "/log.txt")
                    }
                }
            } else {
                await sleep(4)
            }
            if ProcessInfo.processInfo.environment["COVE_REPORT_SETTINGS"] == "1",
               let dir = ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT_PNG_DIR"],
               let content = SettingsWindowController.shared.window?.contentView {
                snapshot(content, to: "\(dir)/settings.png")
            }
            var lines: [String] = []
            for screen in NSScreen.screens { lines.append("screen frame=\(screen.frame) visible=\(screen.visibleFrame)") }
            for window in NSApp.windows {
                lines.append("\(type(of: window)) title=\"\(window.title)\" visible=\(window.isVisible) level=\(window.level.rawValue) frame=\(window.frame) contentMin=\(window.contentMinSize) contentMax=\(window.contentMaxSize)")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// With COVE_DROP_TEST=<file>[,<file>…] set, drops those files onto the shelf the way a drag would and reports what it kept.
    static func dropTestIfRequested() {
        guard let list = ProcessInfo.processInfo.environment["COVE_DROP_TEST"], let out = ProcessInfo.processInfo.environment["COVE_DROP_TEST_OUT"] else { return }
        Task { @MainActor in
            await sleep(3)
            var lines: [String] = []
            for path in list.split(separator: ",").map(String.init) {
                let before = ShelfStateViewModel.shared.items.count
                if path.hasPrefix("pbfile:") || path.hasPrefix("pbpng:") || path.hasPrefix("pbtext:") {
                    // Through the same pasteboard reader the real drop uses.
                    let pb = NSPasteboard(name: NSPasteboard.Name("cove.droptest.\(UUID().uuidString)"))
                    pb.clearContents()
                    if path.hasPrefix("pbfile:") { pb.writeObjects([URL(fileURLWithPath: String(path.dropFirst(7))) as NSURL]) }
                    if path.hasPrefix("pbpng:") { pb.setData(try! Data(contentsOf: URL(fileURLWithPath: String(path.dropFirst(6)))), forType: .png) }
                    if path.hasPrefix("pbtext:") { pb.setString(String(path.dropFirst(7)), forType: .string) }
                    let providers = await NotchDropHandler.providers(from: pb)
                    ShelfStateViewModel.shared.load(providers)
                    await sleep(2.5)
                    lines.append("\(path.prefix(40)): providers \(providers.count), items \(ShelfStateViewModel.shared.items.count)")
                    continue
                }
                let provider: NSItemProvider
                if path.hasPrefix("png:") {
                    // The way a screenshot thumbnail or a web image arrives: image data, no file URL.
                    let data = try! Data(contentsOf: URL(fileURLWithPath: String(path.dropFirst(4))))
                    provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
                    provider.suggestedName = "Screenshot test"
                } else {
                    provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path))!
                }
                ShelfStateViewModel.shared.load([provider])
                await sleep(2.5)
                lines.append("\(path): items \(before) -> \(ShelfStateViewModel.shared.items.count)")
            }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// With COVE_SHOT_DIR set, takes real screen captures (what the user sees, sidebar and notch included, which the
    /// off-screen snapshots cannot draw): the closed notch strip, then each settings tab named in COVE_SHOT_TABS
    /// (comma separated ids, default all). `scripts/shots.sh` builds and runs this.
    static func screenshotsIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["COVE_SHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await sleep(4)
            func capture(_ args: [String], _ name: String) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x"] + args + ["\(dir)/\(name).png"]
                try? p.run()
                p.waitUntilExit()
            }
            // COVE_SHOT_SCENARIO=<agent preview scenario>: show that agent state in the closed notch first.
            if let scenario = env["COVE_SHOT_SCENARIO"] {
                AppDelegate.current?.closeNotchEverywhere()
                // Live hook events from real agent sessions on this Mac replace the preview, so re-apply it right up to
                // the capture.
                for _ in 0..<8 {
                    AgentRuntime.shared.debugApply(scenario: scenario, keepCollapsed: true)
                    await sleep(0.4)
                }
            }
            if let screen = NSScreen.main {
                // COVE_SHOT_BURST=<n>: n captures one second apart, to catch a live agent tool coming and going.
                let burst = Int(env["COVE_SHOT_BURST"] ?? "") ?? 1
                for index in 1...max(burst, 1) {
                    capture(["-R0,0,\(Int(screen.frame.width)),80"], burst > 1 ? "notch-\(index)" : "notch")
                    if index < burst { await sleep(1) }
                }
            }
            // COVE_SHOT_NOTCH_TAB=<module id>: open the notch on that tab and capture it too.
            if let tab = env["COVE_SHOT_NOTCH_TAB"], let screen = NSScreen.main {
                AppModules.present(moduleID: tab)
                // COVE_SHOT_MARKET_DETAIL=<symbol>: open that pair's detail view on the Markets tab.
                if let symbol = env["COVE_SHOT_MARKET_DETAIL"] {
                    await sleep(2)
                    MarketDetailStore.shared.open(symbol)
                    await sleep(2)
                    // COVE_SHOT_SAMPLE=<seconds>: count how often the on-screen price and the open candle really change.
                    if let seconds = Double(env["COVE_SHOT_SAMPLE"] ?? "") {
                        var lastClose: Double?, lastPrice: Double?, lastBid: Double?, lastShare: Double?, candleChanges = 0, priceChanges = 0, bidChanges = 0, shareChanges = 0
                        let end = Date().addingTimeInterval(seconds)
                        while Date() < end {
                            if let close = MarketDetailStore.shared.candles.last?.close, close != lastClose { if lastClose != nil { candleChanges += 1 }; lastClose = close }
                            if let price = MarketsStore.shared.tickers[symbol]?.price, price != lastPrice { if lastPrice != nil { priceChanges += 1 }; lastPrice = price }
                            if let bid = MarketDetailStore.shared.book?.bids.first?.price, bid != lastBid { if lastBid != nil { bidChanges += 1 }; lastBid = bid }
                            if let share = MarketDetailStore.shared.book?.bidShare(), share != lastShare { if lastShare != nil { shareChanges += 1 }; lastShare = share }
                            await sleep(0.02)
                        }
                        try? "candle close changed \(candleChanges)x, board price changed \(priceChanges)x, best bid changed \(bidChanges)x, order-book imbalance changed \(shareChanges)x in \(Int(seconds)) s\n".write(toFile: dir + "/sample.txt", atomically: true, encoding: .utf8)
                    }
                }
                await sleep(5)
                capture(["-R0,0,\(Int(screen.frame.width)),420"], "notch-open")
                // COVE_SHOT_CHART_STEPS="zoom:0.5;pan:150;wait:3;reset": drive the chart and capture after each step.
                if let steps = env["COVE_SHOT_CHART_STEPS"] {
                    for (index, step) in steps.split(separator: ";").enumerated() {
                        let parts = step.split(separator: ":").map(String.init)
                        var info: [String: Any] = [:]
                        switch parts[0] {
                        case "pan": info["pan"] = Int(parts.dropFirst().first ?? "") ?? 0
                        case "zoom": info["zoom"] = Double(parts.dropFirst().first ?? "") ?? 1
                        case "reset": info["reset"] = true
                        case "hover": info["hover"] = Double(parts.dropFirst().first ?? "") ?? 0.5
                        case "interval": if let raw = parts.dropFirst().first, let value = CandleInterval(rawValue: raw) { MarketDetailStore.shared.setInterval(value) }
                        default: break
                        }
                        if !info.isEmpty { NotificationCenter.default.post(name: Notification.Name("CoveChartCommand"), object: nil, userInfo: info) }
                        await sleep(parts[0] == "wait" ? (Double(parts.dropFirst().first ?? "") ?? 2) : 3)
                        capture(["-R0,0,\(Int(screen.frame.width)),420"], "chart-\(index + 1)-\(parts[0])")
                    }
                }
                AppDelegate.current?.closeNotchEverywhere()
                await sleep(1)
            }
            // COVE_SHOT_PLAYER_LOGIC=<fixtures dir>: run the player library against real files (made by
            // scripts/make-player-fixtures.sh) in a throw-away library, and write the checks to player_library.txt.
            if let fixtures = env["COVE_SHOT_PLAYER_LOGIC"] {
                let report = await playerLibraryChecks(fixtures: URL(fileURLWithPath: fixtures))
                try? report.write(toFile: dir + "/player_library.txt", atomically: true, encoding: .utf8)
            }
            // COVE_SHOT_PLAYER_CONTROLS=<fixtures dir>: windowless; writes the result and quits before anything is shown.
            if let fixtures = env["COVE_SHOT_PLAYER_CONTROLS"] {
                await playerControlsLogic(fixtures: URL(fileURLWithPath: fixtures), dir: dir)
                try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            // COVE_SHOT_ACTIVATION=1: does opening the typing panel activate Cove or change its activation policy?
            if env["COVE_SHOT_ACTIVATION"] != nil {
                var log: [String] = ["policy before: \(NSApp.activationPolicy().rawValue) active: \(NSApp.isActive)"]
                let center = NotificationCenter.default
                let tokens = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification].map { name in
                    center.addObserver(forName: name, object: nil, queue: .main) { n in log.append("event \(n.name.rawValue)") }
                }
                if let screen = NSScreen.main {
                    let rect = NSRect(x: screen.frame.midX - 120, y: screen.frame.maxY - 160, width: 240, height: 24)
                    NotchTextInputController.shared.begin(over: rect, text: "", placeholder: "Search", symbol: nil, onChange: { _ in }, onCommit: {})
                    await sleep(1)
                    log.append("policy after: \(NSApp.activationPolicy().rawValue) active: \(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.className))")
                    NotchTextInputController.shared.end(commit: false)
                    await sleep(0.5)
                    log.append("after end: active: \(NSApp.isActive)")
                }
                tokens.forEach { center.removeObserver($0) }
                try? log.joined(separator: "\n").write(toFile: dir + "/activation.txt", atomically: true, encoding: .utf8)
            }
            if env["COVE_SHOT_PLAYER_TYPING"] != nil { await playerTypingCheck(dir: dir) }
            if let fixtures = env["COVE_SHOT_PLAYER_UI"] {
                await playerUIFlow(fixtures: URL(fileURLWithPath: fixtures), dir: dir)
            }
            if let fixtures = env["COVE_SHOT_PLAYER_ENGINE"] {
                let report = await playerEngineChecks(fixtures: URL(fileURLWithPath: fixtures))
                try? report.write(toFile: dir + "/player_engine.txt", atomically: true, encoding: .utf8)
            }
            // COVE_SHOT_LOOK=<player fixtures>,<photo fixtures>: one on-screen pass over the new screens (captures only).
            if let pair = env["COVE_SHOT_LOOK"]?.split(separator: ",").map(String.init), pair.count == 2 {
                await lookAtNewScreens(playerFixtures: URL(fileURLWithPath: pair[0]), photoFixtures: URL(fileURLWithPath: pair[1]), dir: dir)
                try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            // COVE_SHOT_REPORT=<player fixtures>,<photo fixtures>: off-screen renders of the import report, the library manager
            // and the photo window (nothing is shown on screen), then quit.
            if let pair = env["COVE_SHOT_REPORT"]?.split(separator: ",").map(String.init), pair.count == 2 {
                await importReportShots(playerFixtures: URL(fileURLWithPath: pair[0]), photoFixtures: URL(fileURLWithPath: pair[1]), dir: dir)
                try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if env["COVE_SHOT_ALBUM_ORDER"] != nil {
                let report = await PhotoChecks.albumOrder()
                try? report.write(toFile: dir + "/album_order.txt", atomically: true, encoding: .utf8)
                try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if let fixtures = env["COVE_SHOT_PLAYER_MANAGER"] { await playerManagerChecks(fixtures: URL(fileURLWithPath: fixtures), dir: dir) }
            // COVE_SHOT_PHOTO_LOGIC=<fixtures dir> [COVE_SHOT_PHOTO_MANY=<big dir>]: the photo library against real files.
            if let fixtures = env["COVE_SHOT_PHOTO_LOGIC"] {
                let report = await PhotoChecks.run(fixtures: URL(fileURLWithPath: fixtures), many: env["COVE_SHOT_PHOTO_MANY"].map { URL(fileURLWithPath: $0) })
                try? report.write(toFile: dir + "/photo_library.txt", atomically: true, encoding: .utf8)
            }
            // COVE_SHOT_HEADLESS=1: stop after the logic checks, before any window is shown.
            if env["COVE_SHOT_HEADLESS"] != nil {
                try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            // COVE_SHOT_MARKETS_LOGIC=1: exercise the watchlist and search code for real and write the outcome to logic.txt.
            // The watchlist is put back afterwards.
            if env["COVE_SHOT_MARKETS_LOGIC"] != nil {
                var lines: [String] = []
                let store = MarketsStore.shared, directory = SymbolDirectory.shared
                let original = store.watchlist
                await directory.reload()
                lines.append("directory: \(directory.prices.count) symbols, failed=\(directory.failed)")
                lines.append("suggestions eth: \(directory.suggestions(for: "eth", excluding: []))")
                lines.append("suggestions 'btc usdt': \(directory.suggestions(for: "btc usdt", excluding: []))")
                lines.append("suggestions doge excluding DOGEUSDT: \(directory.suggestions(for: "doge", excluding: ["DOGEUSDT"]))")
                lines.append("suggestions zzzz: \(directory.suggestions(for: "zzzz", excluding: []))")
                lines.append("popular excluding defaults: \(directory.popular(excluding: store.watchlist))")
                store.resetWatchlist(); lines.append("reset: \(store.watchlist)")
                store.addKnown("XRPUSDT"); store.addKnown("XRPUSDT"); lines.append("addKnown XRP twice: \(store.watchlist)")
                store.move("XRPUSDT", by: -2); lines.append("move XRP up 2: \(store.watchlist)")
                store.move("BTCUSDT", by: -1); lines.append("move BTC up at top (no-op): \(store.watchlist)")
                store.move("XRPUSDT", by: 99); lines.append("move XRP down 99 (no-op): \(store.watchlist)")
                store.remove("ETHUSDT"); lines.append("remove ETH: \(store.watchlist)")
                let added = await store.add("sol"); lines.append("add 'sol' (already there): \(String(describing: added)) \(store.watchlist)")
                let added2 = await store.add("pepe"); lines.append("add 'pepe' (network check): \(String(describing: added2)) \(store.watchlist)")
                let bad = await store.add("notacoin"); lines.append("add 'notacoin': \(String(describing: bad))")
                store.watchlist = original; lines.append("restored: \(store.watchlist)")
                try? lines.joined(separator: "\n").write(toFile: dir + "/logic.txt", atomically: true, encoding: .utf8)
            }
            SettingsWindowController.shared.showWindow()
            // COVE_SHOT_WINDOW_SIZE=1400x900: enlarge the settings window first, as the green zoom button would.
            if let size = env["COVE_SHOT_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = SettingsWindowController.shared.window {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
            await sleep(1.5)
            let all = ["General", "Appearance", "Modules", "Media", "Calendar", "HUD", "Battery", "Shelf", "Player", "Photos", "Markets", "Agents", "AgentDisplay",
                       "AgentMascots", "AgentSound", "AgentAutomation", "AgentRemote", "AgentBuddy", "AgentHooks", "Shortcuts", "Advanced", "About"]
            let tabs = env["COVE_SHOT_TABS"].map { $0.split(separator: ",").map(String.init) } ?? all
            if let number = SettingsWindowController.shared.window?.windowNumber {
                for tab in tabs {
                    NotificationCenter.default.post(name: Notification.Name("CoveSelectSettingsTab"), object: tab)
                    await sleep(1)
                    capture(["-o", "-l\(number)"], "settings-\(tab)")
                }
            }
            try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// The player library against real files. Returns a report of PASS / FAIL lines.
    static func playerLibraryChecks(fixtures: URL) async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cove-player-test-\(UUID().uuidString)")
        let libraryDir = work.appendingPathComponent("lib"), mediaDir = work.appendingPathComponent("media")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.copyItem(at: fixtures, to: mediaDir)
        defer { try? fm.removeItem(at: work) }

        let library = PlayerLibrary(directory: libraryDir)
        let summary = await library.importURLs([mediaDir])
        check("import adds 7 playable files", summary.added == 7, "added=\(summary.added)")
        check("mkv is reported as unsupported", summary.unsupported == ["movie.mkv"], "\(summary.unsupported)")
        check("a broken mp3 is reported as failed", summary.failed == ["broken.mp3"], "\(summary.failed)")
        check("notes.txt and cover.png are ignored silently", !summary.unsupported.contains("notes.txt") && !summary.failed.contains("notes.txt"))
        check("library holds 7 items", library.items.count == 7)

        func item(_ title: String) -> MediaItem? { library.items.first { $0.title == title } }
        let alpha = item("Alpha")
        check("mp3 tags read", alpha?.artist == "Test Artist" && alpha?.album == "Test Album" && alpha?.kind == .audio, "\(String(describing: alpha?.artist))")
        check("mp3 duration about 6 s", abs((alpha?.duration ?? 0) - 6) < 0.5, "\(alpha?.duration ?? 0)")
        check("mp3 cover art stored", alpha.map { library.artwork(for: $0) != nil } ?? false)
        check("flac tags read", item("Beta")?.artist == "Test Artist" && item("Beta")?.album == "Second Album")
        check("m4a tags read", item("Gamma")?.artist == "Other Artist" && item("Gamma")?.kind == .audio)
        check("wav falls back to the file name", item("song_d") != nil)
        check("nested folder is searched", item("song_e") != nil)
        let clip = item("Test Clip")
        check("mp4 is a video with a thumbnail", clip?.kind == .video && (clip.map { library.artwork(for: $0) != nil } ?? false))
        check("mp4 duration about 12 s", abs((clip?.duration ?? 0) - 12) < 0.6, "\(clip?.duration ?? 0)")
        check("multi-track mp4 is a video", item("Multi Track")?.kind == .video)

        let again = await library.importURLs([mediaDir, mediaDir.appendingPathComponent("song_a.mp3")])
        check("importing again adds nothing", again.added == 0 && library.items.count == 7, "added=\(again.added) count=\(library.items.count)")
        check("duplicates are counted", again.alreadyInLibrary >= 7, "\(again.alreadyInLibrary)")

        check("filter audio = 5", library.items(matching: .audio).count == 5)
        check("filter video = 2", library.items(matching: .video).count == 2)
        check("search is case-insensitive", library.items(matching: .all, search: "ALPHA").map(\.title) == ["Alpha"])
        check("search matches artist", library.items(matching: .all, search: "other artist").map(\.title) == ["Gamma"])
        check("search needs every word", library.items(matching: .all, search: "test artist second").map(\.title) == ["Beta"], "\(library.items(matching: .all, search: "test artist second").map(\.title))")
        check("search with no match is empty", library.items(matching: .all, search: "zzzz").isEmpty)
        check("sort by title", library.items(matching: .all, sort: .title).first?.title == "Alpha")
        check("sort by duration puts the longest first", library.items(matching: .all, sort: .duration).first?.title == "Test Clip")

        // playlists
        let list = library.createPlaylist(named: "  Mix  ", with: [alpha!.id])
        check("playlist name is trimmed", list.name == "Mix")
        library.add([item("Beta")!.id, alpha!.id, item("Gamma")!.id], toPlaylist: list.id)
        check("playlist ignores duplicates", library.playlists[0].itemIDs.count == 3)
        library.moveInPlaylist(list.id, from: IndexSet(integer: 2), to: 0)
        check("playlist keeps its own order", library.items(matching: .playlist(list.id)).first?.title == "Gamma")
        library.remove([alpha!.id], fromPlaylist: list.id)
        check("remove from playlist", library.items(matching: .playlist(list.id)).count == 2)
        library.renamePlaylist(list.id, to: "")
        check("empty rename is refused", library.playlists[0].name == "Mix")

        // progress and persistence
        library.recordPosition(clip!.id, 5)
        library.recordPlay(clip!.id)
        check("resume position needs more than 5 s", library.item(clip!.id)!.resumePosition == 0)
        library.recordPosition(clip!.id, 7)
        check("resume position is used", library.item(clip!.id)!.resumePosition == 7)
        library.recordPosition(clip!.id, 11)
        check("resume position near the end is dropped", library.item(clip!.id)!.resumePosition == 0)
        library.recordPosition(clip!.id, 7)
        library.saveNow()
        let reopened = PlayerLibrary(directory: libraryDir)
        check("library survives a restart", reopened.items.count == 7 && reopened.playlists.count == 1)
        check("progress survives a restart", reopened.item(clip!.id)?.lastPosition == 7 && reopened.item(clip!.id)?.playCount == 1)
        check("artwork survives a restart", reopened.item(alpha!.id).map { reopened.artwork(for: $0) != nil } ?? false)

        // files that move or vanish
        let songB = item("Beta")!
        let moved = mediaDir.appendingPathComponent("moved-beta.flac")
        try? fm.moveItem(at: songB.url, to: moved)
        let found = library.resolveURL(for: songB.id)
        check("a moved file is found again through its bookmark", found?.lastPathComponent == "moved-beta.flac", "\(String(describing: found?.lastPathComponent))")
        check("the stored path follows it", library.item(songB.id)?.path.hasSuffix("moved-beta.flac") == true)
        let songC = item("Gamma")!
        let songCCopy = work.appendingPathComponent("gamma-copy.m4a")
        try? fm.copyItem(at: songC.url, to: songCCopy)
        try? fm.removeItem(at: songC.url)
        await library.checkAvailability()
        check("a deleted file is marked missing", library.missing == [songC.id], "\(library.missing.count)")
        library.relocate(songC.id, to: songCCopy)
        check("relocate clears missing", library.missing.isEmpty && library.item(songC.id)?.path == songCCopy.path)
        try? fm.removeItem(at: songCCopy)
        await library.checkAvailability()
        library.removeMissing()
        check("remove missing drops them and their playlist entries", library.items.count == 6 && !(library.playlists[0].itemIDs.contains(songC.id)), "items=\(library.items.count)")

        library.remove([clip!.id])
        check("removing an item deletes its thumbnail", !fm.fileExists(atPath: libraryDir.appendingPathComponent("artwork/\(clip!.id.uuidString).jpg").path))

        // a corrupt library file is kept aside, not thrown away
        try? "{ not json".write(to: libraryDir.appendingPathComponent("library.json"), atomically: true, encoding: .utf8)
        let recovered = PlayerLibrary(directory: libraryDir)
        let kept = (try? fm.contentsOfDirectory(atPath: libraryDir.path))?.contains { $0.hasPrefix("library.corrupt-") } ?? false
        check("a corrupt library starts empty and is kept aside", recovered.items.isEmpty && kept)

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The player engine playing real files (silently). Returns a report of PASS / FAIL lines.
    static func playerEngineChecks(fixtures: URL) async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if condition() { return true }; await sleep(0.1) }
            return condition()
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cove-engine-test-\(UUID().uuidString)")
        let mediaDir = work.appendingPathComponent("media")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.copyItem(at: fixtures, to: mediaDir)
        let suiteName = "app.cove.player-test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { try? fm.removeItem(at: work); suite.removePersistentDomain(forName: suiteName) }

        let library = PlayerLibrary(directory: work.appendingPathComponent("lib"))
        await library.importURLs([mediaDir])
        func id(_ title: String) -> UUID { library.items.first { $0.title == title }!.id }
        let engine = PlayerEngine(library: library, defaults: suite)
        engine.volume = 0

        // play, pause, resume, seek
        engine.play(ids: [id("Alpha"), id("song_d"), id("Gamma")], start: id("Alpha"))
        check("starts loading then playing", await waitUntil(5) { engine.state == .playing }, "\(engine.state)")
        check("current item is Alpha", engine.current?.title == "Alpha")
        check("duration is read", abs(engine.duration - 6) < 0.5, "\(engine.duration)")
        await sleep(1.5)
        check("the clock advances while playing", engine.time > 1.0 && engine.time < 2.6, "time=\(engine.time)")
        engine.pause()
        let pausedAt = engine.time
        await sleep(0.8)
        check("pause holds the position", engine.state == .paused && abs(engine.time - pausedAt) < 0.05, "\(pausedAt) -> \(engine.time)")
        engine.togglePlayPause()
        check("toggle resumes", await waitUntil(2) { engine.state == .playing })
        engine.seek(to: 4)
        await sleep(0.6)
        check("seek jumps and keeps playing", engine.time >= 3.9 && engine.time < 5.4 && engine.state == .playing, "time=\(engine.time)")
        engine.seek(to: 999)
        check("seek beyond the end is clamped", engine.time <= engine.duration + 0.01, "\(engine.time)")

        // natural end -> next track
        engine.seek(to: 5.0)
        check("a track ending moves on by itself", await waitUntil(5) { engine.current?.title == "song_d" && engine.state == .playing }, "\(engine.current?.title ?? "-") \(engine.state)")
        check("a play is counted", (library.item(id("song_d"))?.playCount ?? 0) >= 1)

        // previous: restarts when played a while, goes back when at the start
        await sleep(3.4)
        engine.previous()
        check("previous after 3 s restarts the track", engine.current?.title == "song_d" && engine.time < 1, "time=\(engine.time)")
        engine.previous()
        check("previous at the start goes to the one before", await waitUntil(3) { engine.current?.title == "Alpha" }, "\(engine.current?.title ?? "-")")
        engine.next()
        check("next skips ahead", await waitUntil(3) { engine.current?.title == "song_d" })

        // repeat one: a short track keeps itself going
        engine.cycleRepeat(); engine.cycleRepeat()
        check("repeat mode cycles off -> all -> one", engine.repeatMode == .one)
        engine.seek(to: 2.3)
        await sleep(2.0)
        check("repeat one restarts the same track", engine.current?.title == "song_d" && engine.state == .playing && engine.time < 2.0, "t=\(engine.time) \(engine.state)")
        engine.cycleRepeat()
        check("repeat cycles back to off", engine.repeatMode == .off)

        // end of the queue: stops at the start of the last track
        engine.next()
        _ = await waitUntil(3) { engine.current?.title == "Gamma" }
        engine.seek(to: max(engine.duration - 0.8, 0))
        check("queue end stops paused at the start", await waitUntil(4) { engine.state == .paused && engine.time < 0.5 }, "\(engine.state) t=\(engine.time)")

        // speed
        engine.play(ids: [id("Alpha")], start: id("Alpha"), resume: false)
        _ = await waitUntil(3) { engine.state == .playing }
        engine.setRate(2)
        let t0 = engine.time
        await sleep(1.5)
        let advanced = engine.time - t0
        check("2x speed advances about twice as fast", advanced > 2.3 && advanced < 3.6, "advanced \(advanced) s in 1.5 s")
        engine.setRate(1)

        // volume and mute
        engine.volume = 0.4; engine.isMuted = true
        check("volume is stored and applied", abs(suite.double(forKey: "player.volume") - 0.4) < 0.001 && engine.player.isMuted && abs(Double(engine.player.volume) - 0.4) < 0.001)
        engine.isMuted = false; engine.volume = 0

        // resume where it was left
        engine.play(ids: [id("Test Clip")], start: id("Test Clip"), resume: false)
        _ = await waitUntil(4) { engine.state == .playing }
        engine.seek(to: 7); await sleep(0.7)
        engine.pause()
        engine.play(ids: [id("Alpha")], start: id("Alpha"))
        _ = await waitUntil(3) { engine.current?.title == "Alpha" && engine.state == .playing }
        engine.play(ids: [id("Test Clip")], start: id("Test Clip"))
        _ = await waitUntil(4) { engine.current?.title == "Test Clip" && engine.state == .playing }
        check("a track resumes where it was left", engine.time > 6.5 && engine.time < 9.5, "time=\(engine.time)")
        check("a video is a video", engine.current?.kind == .video && engine.player.currentItem?.presentationSize.width ?? 0 > 0, "\(engine.player.currentItem?.presentationSize ?? .zero)")

        // audio and subtitle tracks
        engine.play(ids: [id("Multi Track")], start: id("Multi Track"))
        _ = await waitUntil(4) { engine.state == .playing }
        _ = await waitUntil(3) { engine.audioTracks.count == 2 }
        check("two audio tracks are listed", engine.audioTracks.count == 2, "\(engine.audioTracks.map(\.name))")
        check("a subtitle track is listed", !engine.subtitleTracks.isEmpty, "\(engine.subtitleTracks.map(\.name))")
        if let second = engine.audioTracks.last {
            engine.selectAudio(second.id)
            check("selecting an audio track marks it", engine.audioTracks.last?.isSelected == true && engine.audioTracks.first?.isSelected == false)
        }
        if let subtitle = engine.subtitleTracks.first {
            engine.selectSubtitle(subtitle.id)
            check("selecting subtitles marks them", engine.subtitleTracks.first?.isSelected == true)
            engine.selectSubtitle(nil)
            check("subtitles can be turned off", engine.subtitleTracks.allSatisfy { !$0.isSelected })
        }

        // a bad file in the middle is skipped
        let gone = id("Gamma")
        try? fm.removeItem(at: library.item(gone)!.url)
        await library.checkAvailability()
        engine.play(ids: [id("Alpha"), gone, id("song_d")], start: id("Alpha"), resume: false)
        _ = await waitUntil(3) { engine.state == .playing }
        engine.seek(to: engine.duration - 0.8)
        check("a missing file is skipped during playback", await waitUntil(5) { engine.current?.title == "song_d" && engine.state == .playing }, "\(engine.current?.title ?? "-") \(engine.state)")
        engine.play(ids: [gone], start: gone)
        check("a missing file chosen by hand shows an error", await waitUntil(3) { if case .failed = engine.state { return true } else { return false } }, "\(engine.state)")

        // queue editing through the engine
        engine.play(ids: [id("Alpha"), id("song_d")], start: id("Alpha"), resume: false)
        engine.playNext(id("Beta")); engine.enqueue(id("song_e"))
        check("play next and enqueue edit the order", engine.queueOrder == [id("Alpha"), id("Beta"), id("song_d"), id("song_e")])
        engine.toggleShuffle()
        check("shuffle keeps the current track first", engine.isShuffled && engine.queueOrder.first == id("Alpha") && Set(engine.queueOrder).count == 4)
        engine.toggleShuffle()

        // removing from the library takes it out of the queue; stopping works
        library.remove([id("song_e")])
        check("removing from the library leaves the queue", !engine.queueOrder.contains(where: { library.item($0) == nil }) && engine.queueOrder.count == 3, "\(engine.queueOrder.count)")
        engine.stop()
        check("stop unloads", engine.state == .stopped && engine.player.currentItem == nil)

        // a new engine picks the session up again, paused
        engine.play(ids: [id("Alpha"), id("song_d")], start: id("song_d"), resume: false)
        _ = await waitUntil(3) { engine.state == .playing }
        engine.toggleShuffle(); engine.cycleRepeat()
        engine.pause()
        engine.persistProgress()
        let revived = PlayerEngine(library: library, defaults: suite)
        check("the last session comes back paused, not playing", revived.state == .stopped && revived.current?.title == "song_d" && !revived.player.isMuted, "\(revived.state) \(revived.current?.title ?? "-")")
        check("shuffle and repeat come back", revived.isShuffled && revived.repeatMode == .all)
        check("the queue comes back", revived.queueOrder.count == 2)
        revived.togglePlayPause()
        check("play picks the old session up", await waitUntil(4) { revived.state == .playing })
        revived.stop()

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Player tab for real: library, a video in the notch, popped out, full screen and back, the mini bar. Takes screen
    /// captures into `dir` and writes what it observed to player_ui.txt.
    static func playerUIFlow(fixtures: URL, dir: String) async {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        func shot(_ name: String, height: Int = 520) {
            guard let screen = NSScreen.main else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R0,0,\(Int(screen.frame.width)),\(height)", "\(dir)/\(name).png"]
            try? p.run(); p.waitUntilExit()
        }
        func shotFull(_ name: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "\(dir)/\(name).png"]
            try? p.run(); p.waitUntilExit()
        }
        let ui = PlayerUI.shared, engine = PlayerEngine.shared, library = PlayerLibrary.shared
        engine.volume = 0
        await library.importURLs([fixtures])
        func item(_ title: String) -> MediaItem? { library.items.first { $0.title == title } }
        check("fixtures are in the sandbox library", library.items.count >= 7, "\(library.items.count)")

        AppModules.present(moduleID: PlayerModule.moduleID)
        await sleep(2)
        shot("player-1-library")

        // an audio track: library and controls
        if let alpha = item("Alpha") { ui.play(alpha, in: ui.visibleItems) }
        await sleep(2.5)
        check("audio plays", engine.state == .playing)
        shot("player-2-audio")

        // a video in the notch
        guard let clip = item("Test Clip") else { lines.append("no clip"); return }
        ui.play(clip, in: [clip])
        while engine.repeatMode != .one { engine.cycleRepeat() }   // the clip is 12 s and this flow is longer: keep it looping
        await sleep(3)
        check("video plays in the notch", engine.state == .playing && ui.mode == .video && !ui.isPoppedOut, "\(engine.state) \(ui.mode)")
        shot("player-3-video-notch")

        // full screen from the notch
        ui.toggleFullScreen()
        await sleep(4)
        check("full screen pops the video out", ui.isPoppedOut)
        let window = FloatingPlayerController.shared.panel
        check("the window is full screen", window?.styleMask.contains(.fullScreen) == true && ui.isFullScreen, "style=\(String(describing: window?.styleMask.contains(.fullScreen))) flag=\(ui.isFullScreen)")
        check("the video keeps playing in full screen", engine.state == .playing)
        shotFull("player-4-fullscreen")

        // the controls fade when nothing happens, and come back on activity
        ui.pokeControls()
        check("controls are shown right after activity", ui.controlsVisible)
        await sleep(3.2)
        check("controls fade away in full screen when nothing happens", !ui.controlsVisible, "visible=\(ui.controlsVisible) state=\(engine.state)")
        shotFull("player-4b-fullscreen-idle")
        ui.pokeControls()
        check("activity brings them back", ui.controlsVisible)
        await sleep(3.2)
        check("and they fade again", !ui.controlsVisible)
        ui.pokeControls()

        // leave full screen
        ui.toggleFullScreen()
        await sleep(3)
        check("leaving full screen leaves it in the window", window?.styleMask.contains(.fullScreen) == false && !ui.isFullScreen && ui.isPoppedOut)
        check("the window is above other windows again", window?.level == .floating, "\(String(describing: window?.level.rawValue))")
        shot("player-5-window", height: 900)

        // back into the notch
        ui.popIn()
        await sleep(2)
        check("pop in returns to the notch", !ui.isPoppedOut && ui.mode == .video && window?.isVisible != true,
              "popped=\(ui.isPoppedOut) mode=\(ui.mode) visible=\(String(describing: window?.isVisible)) current=\(engine.current?.title ?? "-") state=\(engine.state)")
        shot("player-6-back")

        // full screen then close the window by popping in while full screen
        ui.toggleFullScreen()
        await sleep(4)
        ui.popIn()
        await sleep(3.5)
        check("pop in from full screen leaves full screen and hides the window", !ui.isFullScreen && window?.isVisible != true && window?.styleMask.contains(.fullScreen) == false)

        // the mini bar
        AppDelegate.current?.closeNotchEverywhere()
        await sleep(2.5)
        check("the mini bar shows while a video plays", PlayerMiniState.shared.visible, "visible=\(PlayerMiniState.shared.visible) state=\(engine.state) log=\(engine.stateLog.suffix(8))")
        shot("player-7-mini", height: 80)
        engine.pause()
        await sleep(0.5)
        check("the mini bar stays a moment after pausing", PlayerMiniState.shared.visible)
        await sleep(7)
        check("the mini bar goes away after a pause", !PlayerMiniState.shared.visible,
              "visible=\(PlayerMiniState.shared.visible) state=\(engine.state) current=\(engine.current?.title ?? "-") t=\(engine.time)")
        engine.stop()

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/player_ui.txt", atomically: true, encoding: .utf8)
    }

    /// Types into the notch's text input panel with key events sent straight to that panel (never to the system, so no other
    /// app can receive them), to check the whole input path: key window, field editor, change callback, Return, Escape,
    /// and what happens when the panel loses the keyboard. Writes the outcome to player_typing.txt.
    static func playerTypingCheck(dir: String) async {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        guard let screen = NSScreen.main else { return }
        AppModules.present(moduleID: PlayerModule.moduleID)
        await sleep(2)
        let controller = NotchTextInputController.shared
        var typed = ""
        var committed = 0
        let rect = NSRect(x: screen.frame.midX - 120, y: screen.frame.maxY - 120, width: 240, height: 24)

        func send(_ panel: NSPanel, _ characters: String, keyCode: UInt16 = 0) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel.windowNumber, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                    panel.sendEvent(event)
                }
            }
        }

        controller.begin(over: rect, text: "ab", placeholder: "Search", symbol: "magnifyingglass",
                         onChange: { typed = $0 }, onCommit: { committed += 1 })
        await sleep(0.5)
        guard let panel = controller.debugPanel else { check("the input panel opens", false); return }
        check("the input panel opens and is the key window", panel.isKeyWindow && panel.canBecomeKey, "key=\(panel.isKeyWindow)")
        check("it sits where the notch field is", abs(panel.frame.midX - rect.midX) < 1 && abs(panel.frame.height - 24) < 1)
        check("the existing text is shown", (panel.firstResponder as? NSText)?.string == "ab", "\(String(describing: (panel.firstResponder as? NSText)?.string))")

        for ch in "cd 世界" { send(panel, String(ch)) }
        await sleep(0.3)
        check("typed text reaches the notch, including spaces and CJK", typed == "abcd 世界", "typed=\(typed)")
        check("the panel stays the key window while typing", panel.isKeyWindow)

        send(panel, "\u{7F}", keyCode: 51)   // delete
        await sleep(0.2)
        check("delete removes a character", typed == "abcd 世", "typed=\(typed)")

        send(panel, "\r", keyCode: 36)
        await sleep(0.4)
        check("Return commits once and closes the panel", committed == 1 && controller.debugPanel == nil, "committed=\(committed)")

        // Escape clears
        controller.begin(over: rect, text: "keep", placeholder: "Search", symbol: nil, onChange: { typed = $0 }, onCommit: { committed += 1 })
        await sleep(0.4)
        if let p2 = controller.debugPanel {
            send(p2, "\u{1B}", keyCode: 53)
            await sleep(0.3)
            check("Escape clears the text and closes without committing", typed == "" && committed == 1 && controller.debugPanel == nil, "typed=\(typed) committed=\(committed)")
        } else { check("the panel opens again", false) }

        // losing the keyboard ends typing and keeps what was typed
        controller.begin(over: rect, text: "", placeholder: "Search", symbol: nil, onChange: { typed = $0 }, onCommit: { committed += 1 })
        await sleep(0.4)
        if let p3 = controller.debugPanel {
            send(p3, "x")
            p3.resignKey()
            await sleep(0.4)
            check("losing the keyboard closes the panel and keeps the text", controller.debugPanel == nil && typed == "x" && committed == 1, "typed=\(typed)")
        }
        check("the notch is released afterwards", !SharingStateManager.shared.preventNotchClose)

        // A click on another window (the notch cannot take the keyboard, so the panel never "loses" it) ends typing too.
        let other = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        for scenario in ["a click on another window", "a click inside the panel stays open"] {
            typed = ""
            controller.begin(over: rect, text: "", placeholder: "Search", symbol: nil, onChange: { typed = $0 }, onCommit: { committed += 1 })
            await sleep(0.3)
            let inside = scenario.contains("inside")
            let target = inside ? (controller.debugPanel?.windowNumber ?? 0) : other.windowNumber
            if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: target, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(click)
            }
            await sleep(0.2)
            check(inside ? "a click inside the panel keeps it open" : "a click on another window closes the panel", (controller.debugPanel == nil) == !inside, scenario)
            controller.end(commit: false)
        }
        other.close()
        // The field leaving the screen (tab switch, notch closing) closes its panel, and only its own.
        let owner = AnchorBox(), stranger = AnchorBox()
        controller.begin(over: rect, text: "", placeholder: "Search", symbol: nil, onChange: { _ in }, onCommit: {}, anchor: owner)
        await sleep(0.3)
        controller.end(ifAnchoredTo: stranger)
        check("another field disappearing leaves the panel alone", controller.debugPanel != nil)
        controller.end(ifAnchoredTo: owner)
        check("its own field disappearing closes the panel", controller.debugPanel == nil)
        check("the notch is released after those too", !SharingStateManager.shared.preventNotchClose)

        // Real keyboard events through the system's event machinery, addressed to this process only.
        typed = ""
        controller.begin(over: rect, text: "", placeholder: "Search", symbol: nil, onChange: { typed = $0 }, onCommit: { committed += 1 })
        await sleep(0.5)
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in "hello world" {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) {
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.postToPid(ProcessInfo.processInfo.processIdentifier)
                }
            }
            await sleep(0.03)
        }
        await sleep(0.4)
        let stillOpen = controller.debugPanel != nil
        check("real key events (posted to this process) type into the panel", typed == "hello world", "typed=\(typed) panelOpen=\(stillOpen) key=\(controller.debugPanel?.isKeyWindow == true) appActive=\(NSApp.isActive)")
        controller.end(commit: false)

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/player_typing.txt", atomically: true, encoding: .utf8)
    }

    /// The controls-over-video countdown, without any window: audio plays silently and only the shared state is read.
    static func playerControlsLogic(fixtures: URL, dir: String) async {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        let ui = PlayerUI.shared, engine = PlayerEngine.shared, library = PlayerLibrary.shared
        engine.volume = 0
        await library.importURLs([fixtures])
        guard let song = library.items.first(where: { $0.title == "Alpha" }) else { return }
        engine.play(ids: [song.id], start: song.id, resume: false)
        for _ in 0..<40 where engine.state != .playing { await sleep(0.1) }
        check("a track is playing", engine.state == .playing)
        ui.pokeControls()
        check("controls are shown right after activity", ui.controlsVisible)
        await sleep(1.5)
        check("controls are still shown before the idle limit", ui.controlsVisible)
        await sleep(2.2)
        check("controls fade after the idle limit while playing", !ui.controlsVisible, "limit=\(ui.controlsIdleLimit)")
        ui.pokeControls()
        check("activity brings them back", ui.controlsVisible)
        await sleep(3)
        check("and they fade again", !ui.controlsVisible)
        ui.pokeControls()
        engine.pause()
        await sleep(3)
        check("controls stay while paused", ui.controlsVisible)
        engine.resumePlayback()
        await sleep(3)
        check("and fade once playing again", !ui.controlsVisible)
        engine.stop()
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/player_controls.txt", atomically: true, encoding: .utf8)
    }

    /// The library manager's logic and the playlist flows, against real files and no window.
    static func playerManagerChecks(fixtures: URL, dir: String) async {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        func settle() async { await sleep(0.25) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cove-manager-test-\(UUID().uuidString)")
        let mediaDir = work.appendingPathComponent("media")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.copyItem(at: fixtures, to: mediaDir)
        defer { try? fm.removeItem(at: work) }

        let library = PlayerLibrary(directory: work.appendingPathComponent("lib"))
        await library.importURLs([mediaDir])
        let model = PlayerManagerModel(library: library)
        await settle()

        // ---- scopes, search, sort
        check("All shows every item", model.rows.count == 7 && model.count(for: .all) == 7, "\(model.rows.count)")
        model.scope = .music; await settle()
        check("Music shows only audio", model.rows.count == 5 && model.rows.allSatisfy { $0.kind == .audio })
        model.scope = .video; await settle()
        check("Video shows only video", model.rows.count == 2 && model.rows.allSatisfy { $0.kind == .video })
        model.scope = .all; await settle()
        model.search = "artist"; await settle()
        check("search narrows the scope", model.rows.count == 3, "\(model.rows.map(\.title))")
        model.search = "artist other"; await settle()
        check("every search word must match", model.rows.map(\.title) == ["Gamma"], "\(model.rows.map(\.title))")
        model.search = ""; await settle()
        model.sortOrder = [KeyPathComparator(\.title, comparator: .localizedStandard)]; await settle()
        check("sorting by title", model.rows.first?.title == "Alpha", "\(model.rows.first?.title ?? "-")")
        model.sortOrder = [KeyPathComparator(\.duration, order: .reverse)]; await settle()
        check("sorting by length puts the longest first", model.rows.first?.title == "Test Clip")

        // ---- selection and bulk removal
        model.selectAll()
        check("Select All selects every row", model.selection.count == 7 && model.allSelected)
        model.clearSelection()
        check("Deselect All empties it", model.selection.isEmpty && !model.allSelected)
        let firstThree = Array(model.rows.prefix(3).map(\.id))
        model.selection = Set(firstThree)
        model.removeSelected(); await settle()
        check("many selected items are removed in one go", library.items.count == 4 && model.rows.count == 4 && model.selection.isEmpty, "left=\(library.items.count)")
        check("the files are untouched", (try? fm.contentsOfDirectory(atPath: mediaDir.appendingPathComponent("trip").path))?.isEmpty == false || fm.fileExists(atPath: mediaDir.appendingPathComponent("song_d.wav").path))

        // ---- remove everything of one kind
        await library.importURLs([mediaDir]); await settle()
        check("importing again restores them", library.items.count == 7, "\(library.items.count)")
        model.scope = .video; await settle()
        model.removeAllShown(); await settle()
        check("Remove all shown clears one kind and nothing else", library.items.count == 5 && library.items.allSatisfy { $0.kind == .audio })

        // ---- missing files
        model.scope = .all; await settle()
        let victim = library.items[0]
        try? fm.removeItem(at: victim.url)
        await library.checkAvailability(); await settle()
        check("a deleted file shows under Missing", model.count(for: .missing) == 1)
        model.scope = .missing; await settle()
        check("the Missing scope lists exactly it", model.rows.map(\.id) == [victim.id])
        model.removeAllShown(); await settle()
        check("Remove all shown clears the missing ones", library.items.count == 4 && library.missing.isEmpty)

        // ---- playlists
        model.scope = .all; await settle()
        let ids = model.rows.map(\.id)
        model.selection = Set(ids.prefix(3))
        let list = model.newPlaylist(named: "Mix", withSelection: true); await settle()
        check("a playlist can be made from a selection", list.itemIDs.count == 3 && model.count(for: .playlist(list.id)) == 3)
        model.scope = .playlist(list.id); await settle()
        let order = library.playlists.first { $0.id == list.id }!.itemIDs
        check("a playlist keeps its own order", model.rows.map(\.id) == order)
        model.selection = [order[2]]
        model.moveSelected(by: -1); await settle()
        check("a selected track moves up one place", library.playlists.first { $0.id == list.id }!.itemIDs == [order[0], order[2], order[1]])
        model.moveSelected(by: -1); model.moveSelected(by: -1); await settle()
        check("it stops at the top", library.playlists.first { $0.id == list.id }!.itemIDs.first == order[2])
        let u = (0..<5).map { _ in UUID() }
        check("moving a block keeps it together", PlayerManagerModel.moved(u, selected: [u[2], u[3]], by: -1) == [u[0], u[2], u[3], u[1], u[4]])
        check("moving down", PlayerManagerModel.moved(u, selected: [u[1]], by: 1) == [u[0], u[2], u[1], u[3], u[4]])
        check("a block already at the end stays", PlayerManagerModel.moved(u, selected: [u[3], u[4]], by: 1) == u)
        check("separate selections each move", PlayerManagerModel.moved(u, selected: [u[1], u[3]], by: -1) == [u[1], u[0], u[3], u[2], u[4]])
        model.selection = [order[0]]
        model.removeSelected(); await settle()
        check("in a playlist Remove only leaves the playlist", library.playlists.first { $0.id == list.id }!.itemIDs.count == 2 && library.items.count == 4)
        model.selectAll()
        model.removeSelectedFromLibrary(); await settle()
        check("Remove from Library takes tracks out of everything", library.items.count == 2 && library.playlists.first { $0.id == list.id }!.itemIDs.isEmpty)

        // ---- the notch: a new playlist goes straight to choosing songs
        let ui = PlayerUI.shared
        let shared = PlayerLibrary.shared
        await shared.importURLs([mediaDir])
        ui.naming = .new(items: [])
        ui.commitNaming("Road trip")
        let made = shared.playlists.first { $0.name == "Road trip" }
        check("creating a playlist opens it", made != nil && ui.filter == .playlist(made!.id) && ui.naming == nil)
        check("and goes straight to picking songs for it", ui.pickingFor == made?.id)
        let someone = shared.items.first!
        shared.add([someone.id], toPlaylist: made!.id)
        check("picking adds to the playlist", shared.playlists.first { $0.id == made!.id }?.itemIDs == [someone.id])
        let other = shared.items[1]
        shared.add([other.id], toPlaylist: made!.id)
        ui.moveInPlaylist(other.id, by: -1)
        check("a track can be moved up from the list", shared.playlists.first { $0.id == made!.id }?.itemIDs == [other.id, someone.id])
        ui.pickingFor = nil
        shared.deletePlaylist(made!.id)
        ui.pickingFor = made!.id
        ui.validateFilter()
        check("deleting a playlist cannot leave the screen stuck on it", ui.filter == .all && ui.pickingFor == nil)
        // With nothing in the library there is nothing to pick from: the new playlist opens, but no picker.
        let emptyLibrary = PlayerLibrary(directory: work.appendingPathComponent("empty"))
        let suite = UserDefaults(suiteName: "app.cove.player-test-\(UUID().uuidString)")!
        let emptyUI = PlayerUI(engine: PlayerEngine(library: emptyLibrary, defaults: suite), library: emptyLibrary)
        emptyUI.naming = .new(items: [])
        emptyUI.commitNaming("Nothing to pick")
        let emptyMade = emptyLibrary.playlists.first
        check("no picker is opened when the library is empty", emptyMade != nil && emptyUI.filter == .playlist(emptyMade!.id) && emptyUI.pickingFor == nil,
              "picking=\(String(describing: emptyUI.pickingFor))")

        // ---- adding straight into a playlist
        let intoDir = work.appendingPathComponent("into")
        try? fm.copyItem(at: fixtures, to: intoDir)
        let intoLib = PlayerLibrary(directory: work.appendingPathComponent("into-lib"))
        var first = await intoLib.importURLs([intoDir])
        check("an import reports the ids of everything playable it covered", first.itemIDs.count == 7 && Set(first.itemIDs).count == 7, "\(first.itemIDs.count)")
        let road = intoLib.createPlaylist(named: "Road", with: first.itemIDs)
        check("a new playlist made from those ids holds all of them, in order", road.itemIDs == first.itemIDs)
        let again = await intoLib.importURLs([intoDir.appendingPathComponent("song_a.mp3"), intoDir.appendingPathComponent("clip.mp4")])
        check("files already in the library are still reported, so they can join a playlist", again.added == 0 && again.itemIDs.count == 2, "added=\(again.added) ids=\(again.itemIDs.count)")
        let otherList = intoLib.createPlaylist(named: "Other")
        intoLib.add(again.itemIDs, toPlaylist: otherList.id)
        intoLib.add(again.itemIDs, toPlaylist: otherList.id)
        check("adding twice does not duplicate", intoLib.playlists.first { $0.id == otherList.id }?.itemIDs.count == 2)
        var report = again; report.playlistName = "Other"
        check("the result line names the playlist", report.report.headline.contains("Other") || report.report.headline.contains("「Other」") || report.report.headline.contains("“Other”"), report.report.headline)
        first = ImportSummary()
        // ---- the order of things added together
        let natural = intoLib.items.sorted { PlayerLibrary.byName($0, $1) }.map(\.id)
        check("files added together are listed in file-name order, not backwards", intoLib.items(matching: .all, sort: .recentlyAdded).map(\.id) == natural)
        let stamped = (1...12).map { i -> MediaItem in
            var m = MediaItem(path: "/x/ep\(i).mp3", bookmark: nil, title: "ep\(i)", artist: "", album: "", duration: 60, kind: .audio)
            m.addedAt = Date(timeIntervalSince1970: 1_000_000 + Double(13 - i))   // stamped backwards, as concurrent probing does
            return m
        }
        check("episode 2 comes before episode 10 inside a batch", PlayerLibrary.recentlyAddedOrder(stamped).map(\.title) == (1...12).map { "ep\($0)" })
        var older = MediaItem(path: "/x/old.mp3", bookmark: nil, title: "old", artist: "", album: "", duration: 60, kind: .audio)
        older.addedAt = Date(timeIntervalSince1970: 1_000_000 - 86_400)
        var newer = MediaItem(path: "/x/new.mp3", bookmark: nil, title: "new", artist: "", album: "", duration: 60, kind: .audio)
        newer.addedAt = Date(timeIntervalSince1970: 1_000_000 + 86_400)
        check("a newer batch is still listed before an older one", PlayerLibrary.recentlyAddedOrder(stamped + [older, newer]).map(\.title).prefix(1) == ["new"] && PlayerLibrary.recentlyAddedOrder(stamped + [older, newer]).last?.title == "old")
        // ---- selecting several rows (Shift and Command)
        let rowIDs = (0..<10).map { _ in UUID() }
        let pick = PlayerUI.selection(afterClicking:in:current:anchor:shift:command:)
        check("a plain click selects only that row", pick(rowIDs[3], rowIDs, [rowIDs[1], rowIDs[2]], rowIDs[1], false, false) == [rowIDs[3]])
        check("Command adds a row", pick(rowIDs[5], rowIDs, [rowIDs[3]], rowIDs[3], false, true) == [rowIDs[3], rowIDs[5]])
        check("Command on a selected row takes it out", pick(rowIDs[3], rowIDs, [rowIDs[3], rowIDs[5]], rowIDs[3], false, true) == [rowIDs[5]])
        check("Shift selects the range from the anchor, downwards", pick(rowIDs[6], rowIDs, [rowIDs[2]], rowIDs[2], true, false) == Set(rowIDs[2...6]))
        check("Shift selects the range from the anchor, upwards", pick(rowIDs[1], rowIDs, [rowIDs[4]], rowIDs[4], true, false) == Set(rowIDs[1...4]))
        check("Shift replaces an earlier range", pick(rowIDs[8], rowIDs, Set(rowIDs[2...6]), rowIDs[2], true, false) == Set(rowIDs[2...8]))
        check("Shift with Command adds the range to what is selected", pick(rowIDs[9], rowIDs, [rowIDs[0], rowIDs[5]], rowIDs[5], true, true) == Set([rowIDs[0]] + Array(rowIDs[5...9])))
        check("Shift without an anchor acts like a plain click", pick(rowIDs[4], rowIDs, [], nil, true, false) == [rowIDs[4]])
        // ---- arranging a playlist
        let backwards = intoLib.createPlaylist(named: "Backwards", with: natural.reversed())
        intoLib.arrange(backwards.id, .fileName)
        check("Arrange by file name puts a reversed playlist right", intoLib.playlists.first { $0.id == backwards.id }?.itemIDs == natural)
        intoLib.arrange(backwards.id, .reverse)
        check("Reverse order turns it round", intoLib.playlists.first { $0.id == backwards.id }?.itemIDs == natural.reversed())
        intoLib.arrange(backwards.id, .title)
        check("Arrange by title keeps every track", Set(intoLib.playlists.first { $0.id == backwards.id }?.itemIDs ?? []) == Set(natural))
        let chooser = AddToPlaylistChooser(playlists: intoLib.playlists, preselect: otherList.id)
        if case .existing(let id) = chooser.choice { check("the chooser preselects the playlist being viewed", id == otherList.id) } else { check("the chooser preselects the playlist being viewed", false) }
        let plain = AddToPlaylistChooser(playlists: intoLib.playlists, preselect: nil)
        if case .none = plain.choice { check("by default nothing is added to a playlist", true) } else { check("by default nothing is added to a playlist", false) }

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/player_manager.txt", atomically: true, encoding: .utf8)
    }

    /// One pass over the new screens for a human to look at: captures only, no input sent anywhere. Run once.
    private static func windowShotOffscreen<V: View>(_ root: V, size: CGSize, name: String, dir: String) async {
        await render(root, size: size, name: name, dir: dir, settle: 0.6)
    }

    static func importReportShots(playerFixtures: URL, photoFixtures: URL, dir: String) async {
        let player = await PlayerLibrary.shared.importURLs([playerFixtures])
        let photos = await PhotoLibrary.shared.importURLs([photoFixtures])
        var lines = ["player: added \(player.added) skipped \(player.skipped.map { "\($0.name)=\($0.reason)" })",
                     "photos: added \(photos.added) skipped \(photos.skipped.map { "\($0.name)=\($0.reason)" })"]
        let bars = VStack(spacing: 10) {
            ImportReportBar(report: player.report, compact: true) {}
            ImportReportBar(report: photos.report, compact: true) {}
            ImportReportBar(report: ImportReport(domain: .media, added: 5, alreadyInLibrary: 0, skipped: []), compact: true) {}
        }
        .padding(14).frame(width: 560).background(Color.black).environment(\.colorScheme, .dark)
        await render(bars, size: CGSize(width: 560, height: 150), name: "report-1-notch-bars", dir: dir)
        await render(ImportReportBar(report: photos.report) {}.padding(14).frame(width: 600), size: CGSize(width: 600, height: 70), name: "report-2-window-bar", dir: dir)
        await render(ImportReportView(report: player.report) {}, size: CGSize(width: 620, height: 460), name: "report-3-player-window", dir: dir)
        await render(ImportReportView(report: photos.report) {}, size: CGSize(width: 620, height: 560), name: "report-4-photo-window", dir: dir)
        func windowShot<V: View>(_ root: V, name: String, width: CGFloat = 1000) async {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: root)
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFront(nil)
            await sleep(3)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(window.windowNumber)", "\(dir)/\(name).png"]
            try? p.run(); p.waitUntilExit()
            window.close()
        }
        await render(PhotoNotchView().frame(width: 600, height: 262).background(Color.black).environment(\.colorScheme, .dark), size: CGSize(width: 600, height: 262), name: "report-8-photos-notch", dir: dir, settle: 1.2)
        await render(PlayerView().frame(width: 600, height: 262).background(Color.black).environment(\.colorScheme, .dark), size: CGSize(width: 600, height: 262), name: "report-9-player-notch", dir: dir, settle: 1.2)
        do {
            func art(_ w: CGFloat, _ h: CGFloat) -> NSImage {
                let image = NSImage(size: NSSize(width: w, height: h))
                image.lockFocus()
                NSGradient(colors: [.systemOrange, .systemPink, .systemIndigo])?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 20)
                NSColor.white.setStroke(); let box = NSBezierPath(rect: NSRect(x: 4, y: 4, width: w - 8, height: h - 8)); box.lineWidth = 6; box.stroke()
                image.unlockFocus(); return image
            }
            let row = HStack(spacing: 16) {
                SquareArtwork(image: art(160, 160)).frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                SquareArtwork(image: art(320, 180)).frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                SquareArtwork(image: art(180, 320)).frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                SquareArtwork(image: art(320, 180)).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
            }.padding(16).background(Color.black)
            await render(row, size: CGSize(width: 480, height: 142), name: "report-10-square-art", dir: dir, settle: 0.6)
        }
        if let file = ProcessInfo.processInfo.environment["COVE_VP9_FILE"] {
            let skipped = await SkippedFile.diagnoseMedia(file)
            lines.append("diagnose \(skipped.name): reason=\(skipped.reason) detail=\(skipped.detail) :: \(skipped.explanation)")
            let two = ImportReport(domain: .media, added: 625, alreadyInLibrary: 0, skipped: [skipped, skipped.withPath(file + ".copy.mp4")])
            await render(ImportReportView(report: two) {}, size: CGSize(width: 460, height: 320), name: "report-11-small-window", dir: dir, settle: 0.8)
            await render(ImportReportView(report: two) {}, size: CGSize(width: 620, height: 460), name: "report-12-default-window", dir: dir, settle: 0.8)
        }
        // The mini player with a video playing: the video itself in the corner.
        if let clip = PlayerLibrary.shared.items.first(where: { $0.kind == .video }) {
            PlayerEngine.shared.volume = 0
            PlayerEngine.shared.play(ids: [clip.id], start: clip.id, resume: false)
            await sleep(1.5)
            await windowShot(PlayerMiniBar(notchWidth: 190, notchHeight: 32).padding(8).background(Color.black).frame(width: 330, height: 50), name: "report-7-minibar-video")
            PlayerEngine.shared.stop()
        }
        // Sidebars are drawn by AppKit table views, which an off-screen bitmap snapshot leaves blank: the window server's own
        // capture of the (off-screen) window shows them.
        PlayerManagerView.debugSelectAll = true; PhotoWindowView.debugSelectAll = true
        await windowShot(PlayerManagerView(), name: "report-5-manager")
        PhotoWindowView.debugSelectAll = true
        await windowShot(PhotoWindowView(), name: "report-6-photos", width: 840)
        if let first = await PhotoLibrary.shared.ids(scope: .all, sort: .name).first {
            PhotoWindowView.debugSelectAll = false
            PhotoWindowController.shared.pending = (.all, first)
            await windowShot(PhotoWindowView(), name: "report-13-viewer-rest")
        }
        try? lines.joined(separator: "\n").write(toFile: dir + "/report.txt", atomically: true, encoding: .utf8)
        lines.removeAll()
    }

    static func lookAtNewScreens(playerFixtures: URL, photoFixtures: URL, dir: String) async {
        guard let screen = NSScreen.main else { return }
        func shot(_ name: String, rect: CGRect? = nil, window: NSWindow? = nil) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            if let window { p.arguments = ["-x", "-o", "-l\(window.windowNumber)", "\(dir)/\(name).png"] }
            else if let rect { p.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", "\(dir)/\(name).png"] }
            else { p.arguments = ["-x", "-R0,0,\(Int(screen.frame.width)),560", "\(dir)/\(name).png"] }
            try? p.run(); p.waitUntilExit()
        }
        let ui = PlayerUI.shared, engine = PlayerEngine.shared, library = PlayerLibrary.shared, photos = PhotoLibrary.shared
        engine.volume = 0
        await library.importURLs([playerFixtures])
        await photos.importURLs([photoFixtures])
        await sleep(1)

        // the Player tab
        AppModules.present(moduleID: PlayerModule.moduleID)
        await sleep(2.5)
        shot("look-1-player")

        // the search box's typing panel, over a spot of the screen with nothing else in it
        let rect = NSRect(x: screen.frame.midX - 150, y: screen.frame.maxY - 640, width: 300, height: 24)
        NotchTextInputController.shared.begin(over: rect, text: "alpha", placeholder: "Search", symbol: "magnifyingglass", onChange: { _ in }, onCommit: {})
        await sleep(0.7)
        shot("look-2-search-field", rect: CGRect(x: rect.minX - 20, y: screen.frame.height - rect.maxY - 20, width: rect.width + 40, height: rect.height + 40))
        NotchTextInputController.shared.end(commit: false)
        await sleep(0.3)

        // a playlist: made, picking songs, filled, and an empty one
        ui.naming = .new(items: [])
        ui.commitNaming("Road trip")
        await sleep(1.2)
        shot("look-3-picker")
        if let made = library.playlists.first(where: { $0.name == "Road trip" }) {
            library.add(Array(library.items.prefix(3).map(\.id)), toPlaylist: made.id)
            ui.pickingFor = nil
            await sleep(1.2)
            shot("look-4-playlist")
        }
        let empty = library.createPlaylist(named: "Empty one")
        ui.filter = .playlist(empty.id)
        await sleep(1.2)
        shot("look-5-empty-playlist")
        ui.filter = .all

        // the closed notch while a video plays
        if let clip = library.items.first(where: { $0.kind == .video }) {
            ui.play(clip, in: [clip])
            await sleep(2)
            AppDelegate.current?.closeNotchEverywhere()
            await sleep(2.5)
            shot("look-6-mini-video", rect: CGRect(x: screen.frame.midX - 220, y: 0, width: 440, height: 60))
            engine.stop()
        }

        // the library manager window
        PlayerManagerWindowController.shared.show()
        await sleep(2)
        if let window = PlayerManagerWindowController.shared.window { shot("look-7-manager", window: window); window.close() }
        await sleep(0.5)

        // photos: the notch tab, the window, the viewer
        AppModules.present(moduleID: PhotosModule.moduleID)
        await sleep(2.5)
        shot("look-8-photos-notch")
        AppDelegate.current?.closeNotchEverywhere()
        PhotoWindowController.shared.show()
        await sleep(2.5)
        if let window = PhotoWindowController.shared.window { shot("look-9-photo-window", window: window) }
        if let first = await photos.ids(scope: .all).first {
            PhotoWindowController.shared.show(scope: .all, photo: first)
            await sleep(2.5)
            if let window = PhotoWindowController.shared.window { shot("look-10-photo-viewer", window: window); window.close() }
        }
        await sleep(0.5)
        try? "done".write(toFile: dir + "/look.txt", atomically: true, encoding: .utf8)
    }

    static func runIfRequested() {
        dropTestIfRequested()
        reportWindowsIfRequested()
        screenshotsIfRequested()
        guard let dir = ProcessInfo.processInfo.environment["COVE_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(into: dir)
            try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Writes the view's current pixels over a neutral backdrop so transparent areas are visible.
    static func snapshot(_ view: NSView, to path: String, backdrop: NSColor = NSColor(white: 0.62, alpha: 1)) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        backdrop.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Hosts a SwiftUI view in an off-screen titled window and snapshots it.
    private static func render<V: View>(_ root: V, size: CGSize, name: String, dir: String, settle: Double = 0.8) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        await sleep(settle)
        snapshot(host, to: "\(dir)/\(name).png")
        window.close()
    }

    private static func run(into dir: String) async {
        await sleep(3)

        // 1. Onboarding (first launch, permissions not yet granted)
        let steps: [(String, OnboardingStep)] = [
            ("onb-1-welcome", .welcome), ("onb-2-camera", .cameraPermission), ("onb-3-calendar", .calendarPermission),
            ("onb-4-reminders", .remindersPermission), ("onb-5-accessibility", .accessibilityPermission), ("onb-5b-agents", .agents),
            ("onb-6-music", .musicPermission), ("onb-7-finished", .finished),
        ]
        for (name, step) in steps {
            await render(OnboardingView(step: step, onFinish: {}, onOpenSettings: {}),
                         size: CGSize(width: 400, height: 600), name: name, dir: dir)
        }

        // 2. Settings → Modules
        await render(ModulesSettings().frame(width: 560, height: 720), size: CGSize(width: 560, height: 720), name: "settings-modules", dir: dir)
        await render(AgentsSettings().frame(width: 560, height: 1500), size: CGSize(width: 560, height: 1500), name: "settings-agents", dir: dir, settle: 1.2)
        await render(Shortcuts().frame(width: 560, height: 700), size: CGSize(width: 560, height: 700), name: "settings-shortcuts", dir: dir)

        // 3. The notch
        guard let delegate = AppDelegate.current,
              let window = NSApp.windows.first(where: { $0 is BoringNotchSkyLightWindow }),
              let content = window.contentView else {
            try? "no notch window; windows=\(NSApp.windows.map { String(describing: type(of: $0)) }); delegateWindow=\(String(describing: AppDelegate.current?.window)); screens=\(NSScreen.screens.count)".write(toFile: dir + "/ERROR", atomically: true, encoding: .utf8)
            return
        }
        let registry = AppModules.registry
        var geometryLog = ""
        func logGeometry(_ label: String) {
            let hosting = content as? NSHostingView<AnyView>
            _ = hosting
            geometryLog += "\(label): window=\(window.frame) contentMin=\(window.contentMinSize) contentMax=\(window.contentMaxSize) fitting=\(content.fittingSize) vm=\(delegate.vm.notchSize) state=\(delegate.vm.notchState)\n"
            try? geometryLog.write(toFile: dir + "/geometry.txt", atomically: true, encoding: .utf8)
        }
        let screen = window.screen ?? NSScreen.main
        let report = """
        screen.frame=\(String(describing: screen?.frame))
        screen.visibleFrame=\(String(describing: screen?.visibleFrame))
        screen.safeAreaInsets=\(String(describing: screen?.safeAreaInsets))
        window.frame=\(window.frame)
        content.frame=\(content.frame) safeArea=\(content.safeAreaInsets)
        notchSize=\(delegate.vm.notchSize) closed=\(delegate.vm.closedNotchSize)
        """
        try? report.write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
        // Timeline of the notch opening and closing, to see who folds it away.
        let start = Date()
        var timeline = ""
        func mark(_ text: String) { timeline += String(format: "%6.2fs  %@\n", Date().timeIntervalSince(start), text) }
        var cancellables: Set<AnyCancellable> = []
        delegate.vm.$notchState.sink { mark("vm.notchState -> \($0)") }.store(in: &cancellables)
        delegate.vm.$notchSize.sink { mark("vm.notchSize -> \($0)") }.store(in: &cancellables)
        defer { try? timeline.write(toFile: dir + "/timeline.txt", atomically: true, encoding: .utf8) }
        snapshot(content, to: "\(dir)/notch-closed.png")
        logGeometry("notch-closed")
        AgentRuntime.shared.debugApply(scenario: "working")
        await sleep(1.0)
        AgentRuntime.shared.debugApply(scenario: "working") // second pass: accessory appears after the first change publishes
        await sleep(1.0)
        snapshot(content, to: "\(dir)/notch-closed-with-agent.png")
        logGeometry("notch-closed-with-agent")
        // Opening from the mascot must land on the Agents tab.
        delegate.openNotchEverywhere()
        await sleep(1.4)
        try? BoringViewCoordinator.shared.currentView.id.write(toFile: dir + "/open-lands-on.txt", atomically: true, encoding: .utf8)
        snapshot(content, to: "\(dir)/notch-open-from-mascot.png")
        logGeometry("notch-open-from-mascot")
        delegate.closeNotchEverywhere()
        await sleep(0.8)
        AgentRuntime.shared.debugReset()
        await sleep(0.5)

        mark("openNotchEverywhere")
        delegate.openNotchEverywhere()
        await sleep(1.2)
        for module in registry.visibleModules where module.id != "builtin.agents" {
            BoringViewCoordinator.shared.currentView = NotchViews(id: module.id)
            await sleep(1.2)
            snapshot(content, to: "\(dir)/notch-\(module.id).png")
            logGeometry("notch-\(module.id)")
        logGeometry("notch-\(module.id)")
        }

        // Agents: first-run card, then CodeIsland's own preview scenarios.
        BoringViewCoordinator.shared.currentView = NotchViews(id: "builtin.agents")
        await sleep(1.2)
        AgentRuntime.shared.debugReset()
        await sleep(0.8)
        snapshot(content, to: "\(dir)/notch-agents-empty.png")
        logGeometry("notch-agents-empty")
        for scenario in ["working", "multi", "approval", "question", "completion", "allcli"] {
            mark("apply scenario \(scenario)")
            AgentRuntime.shared.debugApply(scenario: scenario)
            await sleep(1.5)
            snapshot(content, to: "\(dir)/notch-agents-\(scenario).png")
            logGeometry("notch-agents-\(scenario) :: \(AgentRuntime.shared.debugSummary()) :: preferred=\(String(describing: AppModules.agents.preferredContentSize))")
        logGeometry("notch-agents-\(scenario)")
        }
        AgentRuntime.shared.debugReset()
        await sleep(0.8)

        // A tool running right now (as in a live session), through the shipped bridge, with the notch closed.
        delegate.closeNotchEverywhere()
        await sleep(0.8)
        func send(_ json: String) async {
            let bridge = Process()
            bridge.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Helpers/codeisland-bridge")
            bridge.arguments = ["--source", "claude"]
            bridge.environment = ProcessInfo.processInfo.environment
            let pipe = Pipe()
            bridge.standardInput = pipe
            bridge.standardOutput = Pipe()
            try? bridge.run()
            pipe.fileHandleForWriting.write(Data(json.utf8))
            try? pipe.fileHandleForWriting.close()
            await sleep(0.6)
            bridge.terminate()
        }
        await send(#"{"hook_event_name":"SessionStart","session_id":"snap-live-1","cwd":"/Users/dev/frontend","source":"startup"}"#)
        await send(#"{"hook_event_name":"UserPromptSubmit","session_id":"snap-live-1","cwd":"/Users/dev/frontend","prompt":"Build the dashboard page"}"#)
        await send(#"{"hook_event_name":"PreToolUse","session_id":"snap-live-1","cwd":"/Users/dev/frontend","tool_name":"Write","tool_input":{"file_path":"/Users/dev/frontend/src/pages/Dashboard.tsx"}}"#)
        await sleep(1.5)
        snapshot(content, to: "\(dir)/notch-closed-live-write.png")
        logGeometry("notch-closed-live-write :: \(AgentRuntime.shared.debugSummary())")
        await send(#"{"hook_event_name":"SessionEnd","session_id":"snap-live-1","cwd":"/Users/dev/frontend","reason":"other"}"#)
        AgentRuntime.shared.debugReset()
        await sleep(0.6)

        // A real approval request through the shipped bridge: tall content, as on a real machine.
        delegate.openNotchEverywhere()
        await sleep(1.0)
        BoringViewCoordinator.shared.currentView = NotchViews(id: "builtin.agents")
        await sleep(0.8)
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"snap-real-1","cwd":"/Users/dev/api-server","tool_name":"Bash","tool_input":{"command":"npm run test -- --coverage && npm run lint -- --max-warnings 0 && npm run build && docker compose -f docker-compose.ci.yml up --abort-on-container-exit --exit-code-from tests && echo finished","description":"Run the whole CI pipeline locally before opening the pull request"},"permission_suggestions":[]}
        """
        let bridge = Process()
        bridge.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Helpers/codeisland-bridge")
        bridge.arguments = ["--source", "claude"]
        bridge.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        bridge.standardInput = pipe
        bridge.standardOutput = Pipe()
        try? bridge.run()
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        try? pipe.fileHandleForWriting.close()
        await sleep(2.5)
        snapshot(content, to: "\(dir)/notch-agents-real-approval.png")
        logGeometry("notch-agents-real-approval")
        bridge.terminate()
        await sleep(0.8)
        AgentRuntime.shared.debugReset()
    }
}

private extension String {
    func appendLine(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(utf8)); try handle.close() }
        else { try write(to: url, atomically: true, encoding: .utf8) }
    }
}
#endif
