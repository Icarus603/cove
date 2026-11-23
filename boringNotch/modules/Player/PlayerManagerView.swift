//
//  PlayerManagerView.swift
//  boringNotch
//
//  The library manager: a window for the work that does not belong in the notch. Everything in the library in one table that
//  fills the window and scrolls, searchable and sortable; select one, many or all and remove, add to a playlist or reorder in
//  one go; playlists are made, renamed and filled here. Nothing the window does touches the files themselves.
//

import AppKit
import SwiftUI

@MainActor
final class PlayerManagerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerManagerWindowController()
    static let requestNotification = Notification.Name("CovePlayerManagerRequest")

    private(set) var window: NSWindow?
    var pending: PlayerScope?

    func show(scope: PlayerScope? = nil) {
        pending = scope
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "Player Library")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 860, height: 500)
            window.identifier = NSUserInterfaceItemIdentifier("CovePlayerManagerWindow")
            let hosting = NSHostingController(rootView: PlayerManagerView().coveAccent())
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.delegate = self
            if !window.setFrameUsingName("CovePlayerManagerWindow") { window.center() }
            window.setFrameAutosaveName("CovePlayerManagerWindow")
            self.window = window
        }
        AppActivation.windowOpened("player-manager")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.requestNotification, object: nil)
    }

    func consumePending() -> PlayerScope? {
        defer { pending = nil }
        return pending
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowClosed("player-manager")
        DispatchQueue.main.async { [weak self] in self?.window = nil }
    }
}

struct PlayerManagerView: View {
    @StateObject private var model = PlayerManagerModel()
    @ObservedObject private var library = PlayerLibrary.shared

    @State private var confirmRemoveSelection = false
    @State private var confirmRemoveShown = false
    @State private var confirmRemoveFromLibrary = false
    @State private var confirmDeletePlaylist: Playlist?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var creating = false
    @State private var newName = ""

    /// Set by the screenshot harness only.
    nonisolated(unsafe) static var debugSelectAll = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 500)
        .tint(Color.effectiveAccent)
        .onAppear { applyPending(); if PlayerManagerView.debugSelectAll { Task { try? await Task.sleep(nanoseconds: 800_000_000); model.selectAll() } } }
        .onReceive(NotificationCenter.default.publisher(for: PlayerManagerWindowController.requestNotification)) { _ in applyPending() }
        .confirmationDialog(removeSelectionTitle, isPresented: $confirmRemoveSelection, titleVisibility: .visible) {
            Button(model.isPlaylist ? "Remove from Playlist" : "Remove from Library", role: .destructive) { model.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.isPlaylist ? "The video and audio stay in your library." : "Your files are not deleted.") }
        .confirmationDialog(String(localized: "Remove all \(model.rows.count) shown?"), isPresented: $confirmRemoveShown, titleVisibility: .visible) {
            Button(model.isPlaylist ? "Remove from Playlist" : "Remove from Library", role: .destructive) { model.removeAllShown() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.isPlaylist ? "The video and audio stay in your library." : "Your files are not deleted.") }
        .confirmationDialog(String(localized: "Remove \(model.selection.count) from the library?"), isPresented: $confirmRemoveFromLibrary, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) { model.removeSelectedFromLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your files are not deleted.") }
        .confirmationDialog(confirmDeletePlaylist.map { String(localized: "Delete the playlist “\($0.name)”?") } ?? "", isPresented: Binding(get: { confirmDeletePlaylist != nil }, set: { if !$0 { confirmDeletePlaylist = nil } }), titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let playlist = confirmDeletePlaylist {
                    if model.scope == .playlist(playlist.id) { model.scope = .all }
                    library.deletePlaylist(playlist.id)
                }
                confirmDeletePlaylist = nil
            }
            Button("Cancel", role: .cancel) { confirmDeletePlaylist = nil }
        } message: { Text("The video and audio stay in your library.") }
    }

    private func applyPending() {
        if case .playlist(let id) = model.scope, !library.playlists.contains(where: { $0.id == id }) { model.scope = .all }
        if model.scope == .missing, library.missing.isEmpty { model.scope = .all }
        if let scope = PlayerManagerWindowController.shared.consumePending() { model.scope = scope }
    }

    private var removeSelectionTitle: String {
        model.isPlaylist ? String(localized: "Remove \(model.selection.count) from the playlist?") : String(localized: "Remove \(model.selection.count) from the library?")
    }

    // MARK: Sidebar


    private var sidebar: some View {
        List {
            Section("Library") {
                sidebarRow("All Items", "square.stack", .all)
                sidebarRow("Audio", "waveform", .music)
                sidebarRow("Video", "film", .video)
                if library.missing.count > 0 { sidebarRow("Missing Files", "exclamationmark.triangle", .missing) }
            }
            Section("Playlists") {
                ForEach(library.playlists) { playlist in playlistRow(playlist) }
                if creating {
                    HStack {
                        Image(systemName: "play.square.stack").foregroundStyle(Color.effectiveAccent).frame(width: 18)
                        TextField("Playlist name", text: $newName).textFieldStyle(.roundedBorder)
                            .onSubmit { commitNew() }
                            .onExitCommand { creating = false }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Color.effectiveAccent)
        .safeAreaInset(edge: .bottom) {
            Button { newName = ""; creating = true } label: { Label("New Playlist", systemImage: "plus") }
                .buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sidebarRow(_ title: String.LocalizationValue, _ symbol: String, _ scope: PlayerScope) -> some View {
        let selected = model.scope == scope
        return AccentSidebarRow(selected: selected, action: { model.scope = scope }) {
            SidebarRowLabel(title: String(localized: title), symbol: symbol, count: model.count(for: scope), selected: selected)
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        let scope = PlayerScope.playlist(playlist.id)
        let selected = model.scope == scope
        Group {
            if renaming == playlist.id {
                HStack {
                    Image(systemName: "play.square.stack").foregroundStyle(Color.effectiveAccent).frame(width: 18)
                    TextField("Playlist name", text: $renameText).textFieldStyle(.roundedBorder)
                        .onSubmit { library.renamePlaylist(playlist.id, to: renameText); renaming = nil }
                        .onExitCommand { renaming = nil }
                }
            } else {
                AccentSidebarRow(selected: selected, action: { model.scope = scope }) {
                    SidebarRowLabel(title: playlist.name, symbol: "play.square.stack", count: playlist.itemIDs.count, selected: selected)
                }
            }
        }
        .contextMenu {
            Button("Rename") { renameText = playlist.name; renaming = playlist.id }
            Button("Delete…", role: .destructive) { confirmDeletePlaylist = playlist }
        }
    }

    private func commitNew() {
        let name = newName
        creating = false
        let playlist = model.newPlaylist(named: name, withSelection: false)
        model.scope = .playlist(playlist.id)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionBar
            Divider()
            if library.items.isEmpty {
                EmptyManager()
            } else if model.rows.isEmpty {
                emptyScope
            } else {
                table
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text("\(model.rows.count) items").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            ToolbarSearchField(text: $model.search, width: 210)
            ToolbarPillButton(title: "Add", symbol: "plus", prominent: true) { PlayerUI.shared.chooseFilesToAdd() }
                .help(Text("Add files or folders"))
        }
        .frame(height: ToolbarMetrics.height + 8)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Always on screen, so what can be done with a selection is never a secret.
    private var actionBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolbarPillButton(title: model.allSelected ? "Deselect All" : "Select All") { model.allSelected ? model.clearSelection() : model.selectAll() }
                .disabled(model.rows.isEmpty)
            Text(model.selection.isEmpty ? String(localized: "Nothing selected") : String(localized: "\(model.selection.count) of \(model.rows.count) selected"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button { addToNewPlaylist() } label: { Label("New playlist…", systemImage: "plus") }
                if !library.playlists.isEmpty { Divider() }
                ForEach(library.playlists) { playlist in
                    if model.playlistID != playlist.id { Button(playlist.name) { model.addSelected(toPlaylist: playlist.id) } }
                }
            } label: { ToolbarPillLabel(title: "Add to Playlist", symbol: "text.badge.plus", showsChevron: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(model.selection.isEmpty)
            if case .playlist(let playlistID) = model.scope {
                Menu {
                    ForEach(PlaylistArrange.allCases) { how in Button(how.title) { library.arrange(playlistID, how) } }
                } label: { ToolbarPillLabel(title: "Arrange", symbol: "arrow.up.arrow.down", showsChevron: true) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(Text("Put this playlist in order"))
                ToolbarIconButton(symbol: "arrow.up", help: "Move up") { model.moveSelected(by: -1) }.disabled(model.selection.isEmpty)
                ToolbarIconButton(symbol: "arrow.down", help: "Move down") { model.moveSelected(by: 1) }.disabled(model.selection.isEmpty)
            }
            ToolbarPillButton(title: "Show in Finder", symbol: "folder") { reveal(Array(model.selection)) }.disabled(model.selection.isEmpty)
            ToolbarPillButton(title: model.isPlaylist ? "Remove from Playlist" : "Remove from Library", symbol: "trash") { requestRemoveSelection() }
                .disabled(model.selection.isEmpty)
            if model.isPlaylist {
                ToolbarPillButton(title: "Remove from Library", symbol: "trash.slash") { confirmRemoveFromLibrary = true }
                    .disabled(model.selection.isEmpty)
            }
        }
        .frame(height: ToolbarMetrics.height + 4)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Title", value: \.title) { item in titleCell(item) }
                .width(min: 180, ideal: 320)
            TableColumn("Artist", value: \.artist) { Text($0.artist).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 90, ideal: 160)
            TableColumn("Album Title", value: \.album) { Text($0.album).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 90, ideal: 160)
            TableColumn("Length", value: \.duration) { Text(PlayerFormat.clock($0.duration)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(70)
            TableColumn("Added", value: \.addedAt) { Text($0.addedAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
            TableColumn("Plays", value: \.playCount) { Text("\($0.playCount)").foregroundStyle(.secondary).monospacedDigit() }
                .width(50)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            if let id = model.rows.first(where: { ids.contains($0.id) })?.id, let item = library.item(id) { model.play(item) }
        }
        .onDeleteCommand { if !model.selection.isEmpty { requestRemoveSelection() } }
    }

    private func titleCell(_ item: MediaItem) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.kind == .video ? "film" : "waveform").foregroundStyle(.secondary).frame(width: 16)
            Text(item.title).lineLimit(1)
            if library.missing.contains(item.id) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.coveWarning).font(.system(size: 11)).help(Text("File missing"))
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<UUID>) -> some View {
        let targets = model.rows.map(\.id).filter { ids.contains($0) }
        if let first = targets.first.flatMap({ library.item($0) }) {
            Button("Play") { model.play(first) }
            Button("Play next") { targets.reversed().forEach { PlayerEngine.shared.playNext($0) } }
            Button("Add to queue") { targets.forEach { PlayerEngine.shared.enqueue($0) } }
            Divider()
            Menu("Add to playlist") {
                Button("New playlist…") { addToNewPlaylist(targets) }
                if !library.playlists.isEmpty { Divider() }
                ForEach(library.playlists) { playlist in
                    if model.playlistID != playlist.id { Button(playlist.name) { library.add(targets, toPlaylist: playlist.id) } }
                }
            }
            Divider()
            Button("Show in Finder") { reveal(targets) }
            if targets.count == 1, library.missing.contains(first.id) { Button("Locate…") { PlayerUI.shared.locate(first) } }
            Divider()
            if let playlist = model.playlistID {
                Button("Remove from playlist", role: .destructive) { library.remove(Set(targets), fromPlaylist: playlist) }
            }
            Button("Remove from library", role: .destructive) { library.remove(Set(targets)) }
        }
    }

    private var emptyScope: some View {
        VStack(spacing: 10) {
            Image(systemName: model.search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(emptyScopeText).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.isPlaylist && model.search.isEmpty {
                Button { model.scope = .all } label: { Label("Choose from All Items", systemImage: "square.stack") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyScopeText: LocalizedStringKey {
        if !model.search.isEmpty { return "Nothing matches your search." }
        switch model.scope {
        case .playlist: return "This playlist is empty.\nSelect video or audio in All Items, then choose Add to Playlist."
        case .missing: return "No files are missing."
        default: return "Nothing here."
        }
    }

    private var footer: some View {
        HStack {
            Text("Total length \(PlayerFormat.clock(model.rows.reduce(0) { $0 + $1.duration }))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if library.missing.count > 0 && model.scope != .missing {
                FooterButton(title: String(localized: "Show \(library.missing.count) Missing Files"), symbol: "exclamationmark.triangle") { model.scope = .missing }
            }
            FooterButton(title: model.isPlaylist ? String(localized: "Remove all \(model.rows.count) from the playlist…") : String(localized: "Remove all \(model.rows.count) shown…"),
                         symbol: "trash") { confirmRemoveShown = true }
                .disabled(model.rows.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    // MARK: Actions

    private func requestRemoveSelection() {
        if model.selection.count > 1 { confirmRemoveSelection = true } else { model.removeSelected() }
    }

    private func addToNewPlaylist(_ targets: [UUID]? = nil) {
        let ids = targets ?? model.rows.map(\.id).filter { model.selection.contains($0) }
        let playlist = library.createPlaylist(named: "", with: ids)
        model.scope = .playlist(playlist.id)
        renameText = playlist.name
        renaming = playlist.id
    }

    private func reveal(_ ids: [UUID]) {
        let urls = ids.compactMap { id in library.resolveURL(for: id) ?? library.item(id)?.url }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// A quiet text button for the footer: grey until hovered, never system blue.
private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(hovering && isEnabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EmptyManager: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.title3.weight(.semibold))
            Text("Add audio and video files, or whole folders. Your files stay where they are.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { PlayerUI.shared.chooseFilesToAdd() } label: { Label("Add Files or Folders…", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
