//
//  PlayerView.swift
//  boringNotch
//
//  The Player tab. Left: what is playing, with its controls. Right: the library (search, filters, sort, rows) or the
//  queue. A video that is playing in the notch fills the tab instead, with its controls over it. Files and folders
//  dropped on the tab are added to the library.
//

import AppKit
import SwiftUI

struct PlayerView: View {
    @ObservedObject private var engine = PlayerEngine.shared
    @ObservedObject private var ui = PlayerUI.shared

    private var showsVideo: Bool {
        ui.mode == .video && engine.current?.kind == .video && !ui.isPoppedOut && engine.state != .stopped
    }

    var body: some View {
        ZStack {
            if showsVideo {
                PlayerVideoView(engine: engine, showsBack: true, isFloating: false)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    NowPlayingPane().frame(width: 210)
                    LibraryPane().frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 4)
            }
        }
        .onAppear { ui.validateFilter() }
        .overlay {
            if ui.isDropTargeted && !showsVideo {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.effectiveAccent.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Now playing

private struct NowPlayingPane: View {
    @ObservedObject private var engine = PlayerEngine.shared
    @ObservedObject private var ui = PlayerUI.shared
    @ObservedObject private var library = PlayerLibrary.shared

    var body: some View {
        VStack(spacing: 5) {
            media
            titleBlock
            if engine.current != nil {
                ScrubBar(engine: engine)
                TransportRow(engine: engine)
                bottomRow
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Picture

    @ViewBuilder
    private var media: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07))
            if let item = engine.current {
                if item.kind == .video {
                    if ui.isPoppedOut {
                        VStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle").font(.system(size: 22)).foregroundStyle(.secondary)
                            Text("Playing in its own window").font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("Bring back") { ui.popIn() }.controlSize(.small)
                        }
                    } else if engine.state != .stopped {
                        VideoSurface(player: engine.player)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                PlayerIconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 11, help: "Expand") { ui.mode = .video }
                                    .padding(3)
                            }
                    } else {
                        artwork(for: item)
                    }
                } else {
                    artwork(for: item)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "play.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Nothing playing").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Double-click a title to play it").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 210, height: 118)
    }

    private func artwork(for item: MediaItem) -> some View {
        Group {
            if let image = library.artwork(for: item) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color.effectiveAccent.opacity(0.5), Color.effectiveAccent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.kind == .video ? "film" : "waveform").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    // MARK: Text

    @ViewBuilder
    private var titleBlock: some View {
        if let item = engine.current {
            VStack(spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if case .failed(let reason) = engine.state {
                    Text(reason).font(.system(size: 10)).foregroundStyle(Color.coveWarning).lineLimit(2).multilineTextAlignment(.center)
                    if library.missing.contains(item.id) {
                        Button("Locate…") { ui.locate(item) }.controlSize(.mini)
                    }
                } else {
                    Text(item.detail.isEmpty ? " " : item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Row of small controls

    private var bottomRow: some View {
        HStack(spacing: 2) {
            VolumeControl(engine: engine, barWidth: 48)
            Spacer(minLength: 2)
            PlayerOptionsMenus(engine: engine)
            if engine.current?.kind == .video && !ui.isPoppedOut {
                PlayerIconButton(symbol: "arrow.up.forward.app", size: 11, help: "Pop out") { ui.popOut() }
            }
            if let current = engine.current { addToPlaylistMenu(current) }
            PlayerIconButton(symbol: "list.bullet", size: 11, active: ui.showQueue, help: "Up next") { ui.showQueue.toggle() }
        }
    }

    /// Puts the track that is playing into a playlist (or a new one), without going to find it in the list.
    private func addToPlaylistMenu(_ item: MediaItem) -> some View {
        Menu {
            Button { ui.naming = .new(items: [item.id]) } label: { Label("New playlist…", systemImage: "plus") }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { playlist in
                Button { library.add([item.id], toPlaylist: playlist.id) } label: {
                    if playlist.itemIDs.contains(item.id) { Label(playlist.name, systemImage: "checkmark") } else { Text(playlist.name) }
                }
            }
        } label: {
            Image(systemName: "text.badge.plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(Text("Add to playlist"))
    }
}

// MARK: - Library

private struct LibraryPane: View {
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var ui = PlayerUI.shared
    @ObservedObject private var now = PlayerUI.shared.now
    @State private var namingText = ""
    /// The playlist waiting for a yes before it is deleted.
    @State private var confirmingDelete: UUID?

    var body: some View {
        VStack(spacing: 6) {
            searchRow
            if let pid = ui.pickingFor { pickerHeader(pid) } else if let id = confirmingDelete, let list = library.playlists.first(where: { $0.id == id }) { deleteRow(list) } else if ui.naming != nil { namingRow } else { chipRow }
            if let progress = library.importProgress { importRow(progress) }
            content
            if let summary = library.lastSummary { ImportReportBar(report: summary.report, compact: true) { library.lastSummary = nil } }
        }
    }

    // MARK: Toolbar

    private var searchRow: some View {
        HStack(spacing: 6) {
            NotchTextField(text: Binding(get: { ui.search }, set: { ui.search = $0 }), placeholder: "Search")
            Button { ui.chooseFilesToAdd() } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .help(Text("Add files or folders"))
        }
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            // All, Audio, Video and then every playlist, in one row that slides sideways when there are more than fit.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        chip(Text("All"), selected: ui.filter == .all) { ui.filter = .all }.id("all")
                        chip(Text("Audio"), selected: ui.filter == .audio) { ui.filter = .audio }.id("audio")
                        chip(Text("Video"), selected: ui.filter == .video) { ui.filter = .video }.id("video")
                        ForEach(library.playlists) { playlist in
                            chip(Text(verbatim: playlist.name), symbol: "play.square.stack", selected: ui.filter == .playlist(playlist.id)) {
                                ui.filter = .playlist(playlist.id)
                            }
                            .id(playlist.id)
                        }
                    }
                    .padding(.trailing, 14)
                }
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    }
                )
                .onAppear {
                    // Open with the remembered chip in view, not with the row back at its start.
                    if case .playlist(let id) = ui.filter {
                        if library.playlists.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) } else { ui.filter = .all }
                    }
                }
                .onChange(of: ui.filter) { _, filter in
                    if case .playlist(let id) = filter { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if case .playlist(let id) = ui.filter {
                PlayerIconButton(symbol: "plus.circle", size: 11, help: "Add video or audio") { ui.pickingFor = id }
                PlayerIconButton(symbol: "pencil", size: 10, help: "Rename playlist") { namingText = library.playlists.first { $0.id == id }?.name ?? ""; ui.naming = .rename(id) }
                PlayerIconButton(symbol: "trash", size: 10, help: "Delete playlist") { confirmingDelete = id }
            }
            // A plus with the word beside it, so what it makes is plain without waiting for a tooltip.
            Button { namingText = ""; ui.naming = .new(items: []) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("Playlists")
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 20)
                .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .foregroundStyle(Color.white.opacity(0.85))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("New playlist…"))
            manageMenu
            sortMenu
            PlayerIconButton(symbol: "list.bullet.rectangle", size: 11, active: ui.showQueue, help: "Up next") { ui.showQueue.toggle() }
        }
        .frame(height: 24)
    }

    private func chip(_ title: Text, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
                title.lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: 130)
            .fixedSize()
            .background(Capsule().fill(selected && !ui.showQueue ? Color.white.opacity(0.92) : Color.white.opacity(0.1)))
            .foregroundStyle(selected && !ui.showQueue ? Color.black : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    /// The way into the library window, where bulk work is done.
    private var manageMenu: some View {
        Menu {
            Button { PlayerManagerWindowController.shared.show(scope: { if case .playlist(let id) = ui.filter { return .playlist(id) } else { return .all } }()) } label: {
                Label("Manage Library…", systemImage: "rectangle.and.pencil.and.ellipsis")
            }
            Button { ui.chooseFilesToAdd() } label: { Label("Add files or folders…", systemImage: "plus") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(Text("Manage Library…"))
    }

    private func pickerHeader(_ id: UUID) -> some View {
        let name = library.playlists.first { $0.id == id }?.name ?? ""
        let count = library.playlists.first { $0.id == id }?.itemIDs.count ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "play.square.stack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Adding to “\(name)”").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("\(count) in this playlist").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { ui.pickingFor = nil } label: {
                Text("Done").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.92))).foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
    }

    private var sortMenu: some View {
        Menu {
            if case .playlist(let id) = ui.filter {
                // A playlist has no sort of its own, only an order; these put it in order once.
                Text("Arrange this playlist")
                ForEach(PlaylistArrange.allCases) { how in
                    Button(how.title) { library.arrange(id, how) }
                }
            } else {
                ForEach(LibrarySort.allCases) { sort in
                    Button { ui.sort = sort } label: {
                        if ui.sort == sort { Label(Self.sortName(sort), systemImage: "checkmark") } else { Text(Self.sortName(sort)) }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(Text("Sort"))
    }


    static func sortName(_ sort: LibrarySort) -> LocalizedStringKey {
        switch sort {
        case .recentlyAdded: return "Recently added"
        case .title: return "Title"
        case .artist: return "Artist"
        case .duration: return "Longest first"
        case .recentlyPlayed: return "Recently played"
        }
    }

    /// Asked in the row itself (a system dialog does not belong in the notch). The media in the playlist stay in the library.
    private func deleteRow(_ list: Playlist) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Delete the playlist “\(list.name)”?").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("The video and audio stay in your library.").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { confirmingDelete = nil } label: {
                Text("Cancel").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12))).foregroundStyle(Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            Button {
                library.deletePlaylist(list.id)
                if ui.filter == .playlist(list.id) { ui.filter = .all }
                confirmingDelete = nil
            } label: {
                Text("Delete Playlist").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color.red.opacity(0.9))).foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
    }

    private var namingRow: some View {
        HStack(spacing: 6) {
            NotchTextField(text: $namingText, placeholder: "Playlist name", symbol: "play.square.stack", onCommit: { ui.commitNaming(namingText) })
            Button("Save") { ui.commitNaming(namingText) }.controlSize(.small).disabled(namingText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { ui.naming = nil }.controlSize(.small)
        }
        .frame(height: 24)
    }

    private func importRow(_ progress: (done: Int, total: Int)) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).progressViewStyle(.linear).tint(.effectiveAccent)
            Text("Adding \(progress.done) / \(progress.total)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if let pid = ui.pickingFor {
            PlaylistPicker(playlistID: pid)
        } else if ui.showQueue {
            QueueList()
        } else {
            let items = ui.visibleItems
            if library.items.isEmpty {
                EmptyLibrary()
            } else if items.isEmpty, case .playlist(let pid) = ui.filter, ui.search.isEmpty {
                EmptyPlaylist(playlistID: pid)
            } else if items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
                    Text(LocalizedStringKey(ui.search.isEmpty ? "Nothing here yet" : "No matches")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { item in
                            LibraryRow(item: item, items: items, now: now)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.system(size: 12, weight: .semibold))
            Text("Use Add to put audio and video files or folders in the library.").font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("mp3 · m4a · aac · flac · wav · aiff · mp4 · m4v · mov").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

// MARK: - Playlists

/// Choosing songs for a playlist: the whole library, a + (or a tick) on every row, searchable, until Done.
private struct PlaylistPicker: View {
    let playlistID: UUID
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var ui = PlayerUI.shared

    var body: some View {
        let items = library.items(matching: .all, search: ui.search, sort: ui.sort)
        let members = Set(library.playlists.first { $0.id == playlistID }?.itemIDs ?? [])
        if items.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("No matches").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        let isIn = members.contains(item.id)
                        HStack(spacing: 8) {
                            Thumbnail(item: item, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(item.detail.isEmpty ? " " : item.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(PlayerFormat.clock(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle")
                                .font(.system(size: 17))
                                .foregroundStyle(isIn ? Color.effectiveAccent : Color.white.opacity(0.7))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 7).fill(isIn ? Color.white.opacity(0.07) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isIn { library.remove([item.id], fromPlaylist: playlistID) } else { library.add([item.id], toPlaylist: playlistID) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// A playlist with nothing in it: say so, and put the way to fill it right there.
private struct EmptyPlaylist: View {
    let playlistID: UUID
    @ObservedObject private var ui = PlayerUI.shared

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.square.stack").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("This playlist is empty").font(.system(size: 12, weight: .semibold))
            Text("Choose video or audio from your library to put in it.").font(.system(size: 10)).foregroundStyle(.secondary)
            Button { ui.pickingFor = playlistID } label: {
                Label("Add video or audio", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.92))).foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rows

private struct LibraryRow: View {
    let item: MediaItem
    let items: [MediaItem]
    @ObservedObject var now: PlayerNowPlaying
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var ui = PlayerUI.shared
    @State private var hovering = false

    private var isCurrent: Bool { now.currentID == item.id }
    private var isMissing: Bool { library.missing.contains(item.id) }

    var body: some View {
        HStack(spacing: 8) {
            Thumbnail(item: item, size: 28)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55))
                        Image(systemName: now.isPlaying ? "waveform" : "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.effectiveAccent)
                            .symbolEffect(.variableColor.iterative, isActive: now.isPlaying)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5))
                        Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11, weight: isCurrent ? .bold : .medium)).foregroundStyle(isCurrent ? Color.effectiveAccent : .white).lineLimit(1)
                HStack(spacing: 4) {
                    if isMissing { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(Color.coveWarning) }
                    Text(isMissing ? String(localized: "File missing") : item.detail).font(.system(size: 9)).foregroundStyle(isMissing ? Color.coveWarning : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.kind == .video { Image(systemName: "film").font(.system(size: 9)).foregroundStyle(.tertiary) }
            Text(PlayerFormat.clock(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            // Everything the right-click menu has, where it can be seen.
            Menu { RowMenu(item: item, items: items) } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white.opacity(0.85)).frame(width: 20, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovering ? 1 : 0)
            .help(Text("More"))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isCurrent ? Color.effectiveAccent.opacity(0.16) : (hovering ? Color.white.opacity(0.07) : .clear)))
        .overlay(alignment: .bottomLeading) {
            if item.progress > 0.01, item.progress < 0.99 {
                GeometryReader { geo in
                    Capsule().fill(Color.effectiveAccent.opacity(0.7)).frame(width: geo.size.width * item.progress, height: 1.5).offset(y: geo.size.height - 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One click plays. Choosing several rows is for the library window (Manage Library…), not for this list.
        .onTapGesture { ui.play(item, in: items) }
        .contextMenu { RowMenu(item: item, items: items) }
    }
}

private struct Thumbnail: View {
    let item: MediaItem
    let size: CGFloat
    private let library = PlayerLibrary.shared
    /// Starts with what is in memory; the rest is read in the background, so scrolling never waits for the disk.
    @State private var loaded: NSImage?

    init(item: MediaItem, size: CGFloat) {
        self.item = item
        self.size = size
        _loaded = State(initialValue: PlayerLibrary.shared.cachedArtwork(for: item))
    }

    var body: some View {
        Group {
            if let image = loaded {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: item.kind == .video ? "film" : "waveform").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: item.id) { if loaded == nil { loaded = await library.loadArtwork(for: item) } }
    }
}

/// What the right-click menu of a row offers.
private struct RowMenu: View {
    let item: MediaItem
    let items: [MediaItem]
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var ui = PlayerUI.shared

    var body: some View {
        Button { ui.play(item, in: items) } label: { Label("Play", systemImage: "play.fill") }
        Button { PlayerEngine.shared.playNext(item.id) } label: { Label("Play next", systemImage: "text.insert") }
        Button { PlayerEngine.shared.enqueue(item.id) } label: { Label("Add to queue", systemImage: "text.append") }
        Divider()
        Menu {
            Button { ui.naming = .new(items: [item.id]) } label: { Label("New playlist…", systemImage: "plus") }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { library.add([item.id], toPlaylist: playlist.id) }
            }
        } label: { Label("Add to playlist", systemImage: "play.square.stack") }
        if case .playlist(let id) = ui.filter {
            Button { ui.moveInPlaylist(item.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
            Button { ui.moveInPlaylist(item.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
            Button { library.remove([item.id], fromPlaylist: id) } label: { Label("Remove from playlist", systemImage: "minus.circle") }
        }
        Divider()
        if library.missing.contains(item.id) {
            Button { ui.locate(item) } label: { Label("Locate…", systemImage: "magnifyingglass") }
        } else {
            Button { ui.reveal(item) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        Button(role: .destructive) { library.remove([item.id]) } label: { Label("Remove from library", systemImage: "trash") }
    }
}

// MARK: - Queue

private struct QueueList: View {
    @ObservedObject private var engine = PlayerEngine.shared
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var ui = PlayerUI.shared
    @ObservedObject private var now = PlayerUI.shared.now

    var body: some View {
        let queued = engine.queueOrder.compactMap { library.item($0) }
        VStack(spacing: 4) {
            HStack {
                Text("Up next").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text("\(queued.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Library") { ui.showQueue = false }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.effectiveAccent)
            }
            if queued.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet").font(.system(size: 18)).foregroundStyle(.secondary)
                    Text("The queue is empty").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(queued.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 16)
                                Thumbnail(item: item, size: 24)
                                Text(item.title).font(.system(size: 11, weight: now.currentID == item.id ? .bold : .medium))
                                    .foregroundStyle(now.currentID == item.id ? Color.effectiveAccent : .white).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(PlayerFormat.clock(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(now.currentID == item.id ? Color.effectiveAccent.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { engine.playFromQueue(item.id) }
                            .contextMenu {
                                Button { engine.playFromQueue(item.id) } label: { Label("Play", systemImage: "play.fill") }
                                Button(role: .destructive) { engine.removeFromQueue(item.id) } label: { Label("Remove from queue", systemImage: "minus.circle") }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

