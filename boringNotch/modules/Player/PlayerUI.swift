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
    /// Which chip is selected is remembered, so the Player opens on the playlist (or All, Audio, Video) it was left on.
    @Published var filter: LibraryFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            UserDefaults.standard.set(Self.filterKey(filter), forKey: "player.filter")
            recomputeVisibleItems()
        }
    }
    private static func filterKey(_ filter: LibraryFilter) -> String {
        switch filter {
        case .all: return "all"
        case .audio: return "audio"
        case .video: return "video"
        case .playlist(let id): return "playlist:" + id.uuidString
        }
    }
    private static func savedFilter() -> LibraryFilter {
        switch UserDefaults.standard.string(forKey: "player.filter") ?? "all" {
        case "audio": return .audio
        case "video": return .video
        case let key where key.hasPrefix("playlist:"):
            return UUID(uuidString: String(key.dropFirst(9))).map(LibraryFilter.playlist) ?? .all
        default: return .all
        }
    }
    @Published var search = "" { didSet { if search != oldValue { recomputeVisibleItems() } } }
    @Published var selection: Set<UUID> = []
    @Published var naming: Naming?
    /// The playlist songs are being chosen for: the library list shows a + on every row until Done.
    @Published var pickingFor: UUID?
    @Published var sort: LibrarySort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: PlayerSettingsKey.sort); recomputeVisibleItems() }
    }

    let engine: PlayerEngine
    let library: PlayerLibrary
    let now: PlayerNowPlaying
    private var observer: AnyCancellable?
    /// One pending check for "has the pointer rested long enough"; none while nothing is playing or the controls are hidden.
    private var hideTimer: Timer?
    private var playbackObserver: AnyCancellable?
    private var libraryObserver: AnyCancellable?

    init(engine: PlayerEngine = .shared, library: PlayerLibrary = .shared) {
        self.engine = engine
        self.library = library
        self.now = PlayerNowPlaying(engine: engine)
        sort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: PlayerSettingsKey.sort) ?? "") ?? .recentlyAdded
        filter = Self.savedFilter()
        if case .playlist(let id) = filter, !library.playlists.contains(where: { $0.id == id }) { filter = .all }
        UserDefaults.standard.register(defaults: [PlayerSettingsKey.resume: true, PlayerSettingsKey.miniBar: true,
                                                  PlayerSettingsKey.videoPlacement: "notch", PlayerSettingsKey.floatOnTop: true])
        // The list follows the library (items added, removed, edited, a playlist changed). A publisher fires before the value
        // changes, so the work is done a turn later, when it has.
        libraryObserver = Publishers.Merge(library.$items.map { _ in () }, library.$playlists.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeVisibleItems() }
        recomputeVisibleItems()
        // Playing again with the controls up: they get their rest period too. (A publisher fires before the value changes,
        // so the new state is taken from the event.)
        playbackObserver = engine.$state.removeDuplicates().sink { [weak self] state in
            guard let self, state == .playing, self.controlsVisible else { return }
            self.scheduleHide(playing: true)
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
        scheduleHide()
    }

    /// Asks, once the rest period is up, whether to hide. Never a repeating clock: nothing runs while the controls stay put.
    private func scheduleHide(playing: Bool? = nil) {
        guard hideTimer == nil, playing ?? (engine.state == .playing) else { return }
        // The time left of the rest period (counted from the last activity), not a whole new one.
        let remaining = max(lastActivity.addingTimeInterval(controlsIdleLimit).timeIntervalSinceNow, 0) + 0.05
        hideTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                self.hideControlsIfIdle()
                // Something moved meanwhile: look again when its rest period will be over.
                if self.controlsVisible, self.engine.state == .playing { self.scheduleHide() }
            }
        }
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

    /// The list on screen, worked out when something that decides it changes and not again for every redraw: filtering and
    /// sorting the whole library (with two collations per comparison) on each body evaluation was the cost of every keystroke
    /// and every progress tick of an import.
    @Published private(set) var visibleItems: [MediaItem] = []

    func recomputeVisibleItems() {
        visibleItems = library.items(matching: filter, search: search, sort: sort)
    }

    /// Falls back to All when the selected playlist no longer exists.
    func validateFilter() {
        if case .playlist(let id) = filter, !library.playlists.contains(where: { $0.id == id }) { filter = .all }
        if let id = pickingFor, !library.playlists.contains(where: { $0.id == id }) { pickingFor = nil }
    }

    // MARK: Selecting several

    /// Where a Shift-click range starts: the last row clicked without Shift.
    private(set) var selectionAnchor: UUID?

    /// A click on a row. Plain: only this row. Command: this row joins or leaves the selection. Shift: everything from the
    /// last plain click to here (added to the selection when Command is held too).
    func click(_ id: UUID, in items: [MediaItem], shift: Bool, command: Bool) {
        selection = Self.selection(afterClicking: id, in: items.map(\.id), current: selection, anchor: selectionAnchor, shift: shift, command: command)
        if !shift { selectionAnchor = id }
        if selectionAnchor == nil { selectionAnchor = id }
    }

    /// The rule on its own, so it can be tested without any view.
    static func selection(afterClicking id: UUID, in order: [UUID], current: Set<UUID>, anchor: UUID?, shift: Bool, command: Bool) -> Set<UUID> {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            let range = Set(order[min(a, b)...max(a, b)])
            return command ? current.union(range) : range
        }
        if command {
            var next = current
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            return next
        }
        return [id]
    }

    func selectAllVisible() {
        selection = Set(visibleItems.map(\.id))
        selectionAnchor = visibleItems.first?.id
    }

    func clearSelection() { selection = []; selectionAnchor = nil }

    /// The selected tracks in the order they are listed.
    func selectedInOrder(_ items: [MediaItem]) -> [UUID] { items.map(\.id).filter { selection.contains($0) } }

    /// Forgets selected tracks that are no longer in the list (another filter, a search, removed from the library).
    func pruneSelection() {
        guard !selection.isEmpty else { return }
        let visible = Set(visibleItems.map(\.id))
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
        if kept.isEmpty { selectionAnchor = nil }
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
        // Where to put the files as they come in: nowhere, a playlist that exists, or a new one (named here).
        let chooser = AddToPlaylistChooser(playlists: library.playlists, preselect: { if case .playlist(let id) = self.filter { return id } else { return nil } }())
        panel.accessoryView = chooser.view
        panel.isAccessoryViewDisclosed = true
        SharingStateManager.shared.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.presentAboveNotch()
        panel.begin { [weak self] response in
            SharingStateManager.shared.endInteraction()
            guard response == .OK, let self else { return }
            let urls = panel.urls
            let choice = chooser.choice
            Task { @MainActor in
                var summary = await self.library.importURLs(urls)
                switch choice {
                case .none: break
                case .existing(let id):
                    if let name = self.library.playlists.first(where: { $0.id == id })?.name {
                        self.library.add(summary.itemIDs, toPlaylist: id)
                        summary.playlistName = name
                    }
                case .new(let name):
                    guard !summary.itemIDs.isEmpty else { break }
                    let playlist = self.library.createPlaylist(named: name, with: summary.itemIDs)
                    summary.playlistName = playlist.name
                    self.filter = .playlist(playlist.id)
                }
                if summary.playlistName != nil { self.library.lastSummary = summary }
            }
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
        panel.presentAboveNotch()
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
            clearSelection()
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


// MARK: - Choosing a playlist in the open panel

/// The strip under the open panel's file list: "Add to playlist: [none / existing / New playlist…]" and, for a new one, its name.
@MainActor
final class AddToPlaylistChooser: NSObject, NSTextFieldDelegate {
    enum Choice { case none, existing(UUID), new(String) }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 34))
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let playlists: [Playlist]
    private let newTag = -1

    init(playlists: [Playlist], preselect: UUID?) {
        self.playlists = playlists
        super.init()
        let label = NSTextField(labelWithString: String(localized: "Also put in playlist:"))
        label.font = .systemFont(ofSize: 12)
        popup.addItem(withTitle: String(localized: "None (library only)"))
        popup.menu?.addItem(.separator())
        for (index, playlist) in playlists.enumerated() {
            let item = NSMenuItem(title: playlist.name, action: nil, keyEquivalent: "")
            item.tag = index + 1
            popup.menu?.addItem(item)
        }
        if !playlists.isEmpty { popup.menu?.addItem(.separator()) }
        let new = NSMenuItem(title: String(localized: "New playlist…"), action: nil, keyEquivalent: "")
        new.tag = newTag
        popup.menu?.addItem(new)
        popup.target = self
        popup.action = #selector(changed)
        if let preselect, let index = playlists.firstIndex(where: { $0.id == preselect }) { popup.selectItem(withTag: index + 1) }

        nameField.placeholderString = String(localized: "Playlist name")
        nameField.stringValue = ""
        nameField.isHidden = true

        for sub in [label, popup, nameField] { sub.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(sub) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 170),
            nameField.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    @objc private func changed() {
        nameField.isHidden = popup.selectedItem?.tag != newTag
        if !nameField.isHidden { nameField.window?.makeFirstResponder(nameField) }
    }

    var choice: Choice {
        guard let tag = popup.selectedItem?.tag else { return .none }
        if tag == newTag { return .new(nameField.stringValue) }
        if tag >= 1, tag <= playlists.count { return .existing(playlists[tag - 1].id) }
        return .none
    }
}
