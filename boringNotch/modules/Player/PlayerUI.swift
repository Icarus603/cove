//
//  PlayerUI.swift
//  boringNotch
//
//  State the player's views share and survive being rebuilt: which list is shown, the search, whether the video is in the
//  notch or in the floating window, plus the actions that need AppKit (the open panel, drops, Finder).
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Which track is current and whether it is playing. The engine's clock changes four times a second; the library list only
/// needs this, so it observes this instead and is not redrawn with every tick.
@MainActor
final class PlayerNowPlaying: ObservableObject {
    @Published private(set) var currentID: UUID?
    @Published private(set) var isPlaying = false
    private var observers: Set<AnyCancellable> = []

    init(engine: PlayerEngine) {
        engine.$current.map { $0?.id }.removeDuplicates().sink { [weak self] in self?.currentID = $0 }.store(in: &observers)
        engine.$state.map { $0 == .playing }.removeDuplicates().sink { [weak self] in self?.isPlaying = $0 }.store(in: &observers)
    }
}

enum PlayerSettingsKey {
    static let resume = "player.resume"
    static let miniBar = "player.miniBar"
    static let videoPlacement = "player.videoPlacement"   // "notch" or "window"
    static let floatOnTop = "player.floatOnTop"
    static let sort = "player.sort"
}

@MainActor
final class PlayerUI: ObservableObject {
    static let shared = PlayerUI()

    enum Mode { case library, video }

    enum Naming: Equatable {
        case new(items: [UUID])
        case rename(UUID)
    }

    @Published var mode: Mode = .library
    @Published var isPoppedOut = false
    @Published var isFullScreen = false
    /// The controls over a playing video fade away when nothing has happened for a moment. Shared by the notch and the window
    /// so the keyboard can bring them back too.
    @Published var controlsVisible = true
    private(set) var lastActivity = Date()
    @Published var showQueue = false
    @Published var filter: LibraryFilter = .all
    @Published var search = ""
    @Published var selection: Set<UUID> = []
    @Published var naming: Naming?
    /// The playlist songs are being chosen for: the library list shows a + on every row until Done.
    @Published var pickingFor: UUID?
    @Published var sort: LibrarySort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: PlayerSettingsKey.sort) }
    }

    let engine: PlayerEngine
    let library: PlayerLibrary
    let now: PlayerNowPlaying
    private var observer: AnyCancellable?
    private var idleTimer: Timer?

    init(engine: PlayerEngine = .shared, library: PlayerLibrary = .shared) {
        self.engine = engine
        self.library = library
        self.now = PlayerNowPlaying(engine: engine)
        sort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: PlayerSettingsKey.sort) ?? "") ?? .recentlyAdded
        UserDefaults.standard.register(defaults: [PlayerSettingsKey.resume: true, PlayerSettingsKey.miniBar: true,
                                                  PlayerSettingsKey.videoPlacement: "notch", PlayerSettingsKey.floatOnTop: true])
        // One clock for the whole app. It must not live in a view: the views are rebuilt with every tick of the player's own
        // clock, and a timer made inside one is replaced before it ever fires.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideControlsIfIdle() }
        }
        // Where a track shows follows what it is: a video goes to the notch or the window (the user's choice), a song
        // brings the window back in. Only when the track really changes, not on every state change.
        observer = engine.$current.compactMap { $0 }.removeDuplicates { $0.id == $1.id }.sink { [weak self] item in
            // The track is set a moment before the engine's state; looking one turn later sees the state that goes with it
            // (and tells a track that was just loaded from one that is only being shown, like the restored last session).
            DispatchQueue.main.async { self?.trackChanged(to: item) }
        }
    }

    private var placementIsWindow: Bool { UserDefaults.standard.string(forKey: PlayerSettingsKey.videoPlacement) == "window" }

    private func trackChanged(to item: MediaItem) {
        guard engine.state != .stopped else { return }
        if item.kind == .video {
            if placementIsWindow { popOut() } else if !isPoppedOut { mode = .video }
        } else {
            mode = .library
            if isPoppedOut { popIn() }
        }
    }

    // MARK: Controls over the video

    /// Something happened (the pointer moved, a key was pressed): show the controls and start the countdown again.
    func pokeControls() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    /// How long the pointer may rest before the controls go: shorter when the video fills the screen.
    var controlsIdleLimit: TimeInterval { isFullScreen ? 2 : 2.5 }

    /// Called by a clock: hides the controls (and the pointer in full screen) once nothing has happened for long enough.
    func hideControlsIfIdle() {
        guard controlsVisible, engine.state == .playing, Date().timeIntervalSince(lastActivity) > controlsIdleLimit else { return }
        controlsVisible = false
        if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: Playing

    /// Double-click on a row: plays it with the rest of the list queued after it.
    func play(_ item: MediaItem, in list: [MediaItem]) {
        engine.play(ids: list.map(\.id), start: item.id, resume: UserDefaults.standard.bool(forKey: PlayerSettingsKey.resume))
        if item.kind == .video, !placementIsWindow, !isPoppedOut { mode = .video }
    }

    func popOut() {
        guard engine.current?.kind == .video else { return }
        isPoppedOut = true
        mode = .library
        FloatingPlayerController.shared.show()
    }

    func popIn() {
        isPoppedOut = false
        isFullScreen = false
        FloatingPlayerController.shared.hide()
        if engine.current?.kind == .video { mode = .video }
    }

    /// Full screen for the video. From the notch the video first moves to its own window, then fills the screen; leaving
    /// full screen leaves it in that window.
    func toggleFullScreen() {
        guard engine.current?.kind == .video else { return }
        pokeControls()   // they show for a moment on the way in and out, then fade
        if !isFullScreen { AppDelegate.current?.closeNotchEverywhere() }   // the notch would stay on top of the video
        if !isPoppedOut { popOut() }
        FloatingPlayerController.shared.toggleFullScreen()
    }

    // MARK: The list shown

    var visibleItems: [MediaItem] { library.items(matching: filter, search: search, sort: sort) }

    /// Falls back to All when the selected playlist no longer exists.
    func validateFilter() {
        if case .playlist(let id) = filter, !library.playlists.contains(where: { $0.id == id }) { filter = .all }
        if let id = pickingFor, !library.playlists.contains(where: { $0.id == id }) { pickingFor = nil }
    }

    /// Moves one track a place up (-1) or down (+1) inside the playlist being shown.
    func moveInPlaylist(_ itemID: UUID, by offset: Int) {
        guard case .playlist(let id) = filter, let playlist = library.playlists.first(where: { $0.id == id }) else { return }
        library.setOrder(PlayerManagerModel.moved(playlist.itemIDs, selected: [itemID], by: offset), forPlaylist: id)
    }

    // MARK: Adding

    /// The open panel for files and folders. The notch is kept open while it is up, as for the share sheet.
    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add to Player")
        panel.prompt = String(localized: "Add")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaFormats.contentTypes
        SharingStateManager.shared.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            SharingStateManager.shared.endInteraction()
            guard response == .OK, let self else { return }
            let urls = panel.urls
            Task { await self.library.importURLs(urls) }
        }
    }

    // MARK: Files

    func reveal(_ item: MediaItem) {
        let url = library.resolveURL(for: item.id) ?? item.url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// For a file that went missing: pick where it is now.
    func locate(_ item: MediaItem) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate “\(item.title)”")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaFormats.supported.compactMap { UTType(filenameExtension: $0) }
        SharingStateManager.shared.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            SharingStateManager.shared.endInteraction()
            guard response == .OK, let url = panel.url, let self else { return }
            self.library.relocate(item.id, to: url)
        }
    }

    // MARK: Playlists

    func commitNaming(_ text: String) {
        switch naming {
        case .new(let items):
            let playlist = library.createPlaylist(named: text, with: items)
            filter = .playlist(playlist.id)
            // A new, empty playlist goes straight to choosing what is in it: there is nothing else to do with it.
            if items.isEmpty, !library.items.isEmpty { pickingFor = playlist.id }
        case .rename(let id):
            library.renamePlaylist(id, to: text)
        case nil:
            break
        }
        naming = nil
    }
}
