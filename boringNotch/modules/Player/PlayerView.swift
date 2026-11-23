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
    @State private var dropTargeted = false

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
            if dropTargeted { DropOverlay() }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { ui.importDropped($0) }
        .onAppear { ui.validateFilter() }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.14)))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 26))
                    Text("Drop to add to the player").font(.system(size: 13, weight: .semibold))
                    Text("Audio and video files, or folders").font(.caption).foregroundStyle(.secondary)
                }
            }
            .allowsHitTesting(false)
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
                    LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.kind == .video ? "film" : "music.note").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8))
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
                    Text(reason).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.center)
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
            PlayerIconButton(symbol: "list.bullet", size: 11, active: ui.showQueue, help: "Up next") { ui.showQueue.toggle() }
        }
    }
}

// MARK: - Library

private struct LibraryPane: View {
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var ui = PlayerUI.shared
    @ObservedObject private var now = PlayerUI.shared.now
    @State private var namingText = ""

    var body: some View {
        VStack(spacing: 6) {
            searchRow
            if ui.naming != nil { namingRow } else { chipRow }
            if let progress = library.importProgress { importRow(progress) }
            content
            if let summary = library.lastSummary { SummaryBanner(summary: summary) { library.lastSummary = nil } }
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
                    .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(Text("Add files or folders"))
        }
    }

    private var chipRow: some View {
        HStack(spacing: 5) {
            chip("All", count: library.items.count, selected: ui.filter == .all) { ui.filter = .all }
            chip("Music", count: library.items.filter { $0.kind == .audio }.count, selected: ui.filter == .audio) { ui.filter = .audio }
            chip("Video", count: library.items.filter { $0.kind == .video }.count, selected: ui.filter == .video) { ui.filter = .video }
            playlistMenu
            Spacer(minLength: 0)
            if case .playlist(let id) = ui.filter {
                PlayerIconButton(symbol: "pencil", size: 10, help: "Rename playlist") { namingText = library.playlists.first { $0.id == id }?.name ?? ""; ui.naming = .rename(id) }
                PlayerIconButton(symbol: "trash", size: 10, help: "Delete playlist") { library.deletePlaylist(id); ui.filter = .all }
            }
            sortMenu
            PlayerIconButton(symbol: "list.bullet.rectangle", size: 11, active: ui.showQueue, help: "Up next") { ui.showQueue.toggle() }
        }
        .frame(height: 24)
    }

    private func chip(_ title: LocalizedStringKey, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Text("\(count)").foregroundStyle(selected ? Color.black.opacity(0.55) : Color.secondary)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(selected && !ui.showQueue ? Color.white.opacity(0.92) : Color.white.opacity(0.1)))
            .foregroundStyle(selected && !ui.showQueue ? Color.black : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private var playlistMenu: some View {
        let selectedName: String? = { if case .playlist(let id) = ui.filter { return library.playlists.first { $0.id == id }?.name } else { return nil } }()
        return Menu {
            Button { namingText = ""; ui.naming = .new(items: []) } label: { Label("New playlist…", systemImage: "plus") }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { playlist in
                Button { ui.filter = .playlist(playlist.id) } label: {
                    if ui.filter == .playlist(playlist.id) { Label("\(playlist.name) (\(playlist.itemIDs.count))", systemImage: "checkmark") }
                    else { Text("\(playlist.name) (\(playlist.itemIDs.count))") }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "music.note.list").font(.system(size: 9))
                Text(selectedName ?? String(localized: "Playlists")).lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(selectedName != nil && !ui.showQueue ? Color.white.opacity(0.92) : Color.white.opacity(0.1)))
            .foregroundStyle(selectedName != nil && !ui.showQueue ? Color.black : Color.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button { ui.sort = sort } label: {
                    if ui.sort == sort { Label(Self.sortName(sort), systemImage: "checkmark") } else { Text(Self.sortName(sort)) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(Text("Sort"))
        .disabled({ if case .playlist = ui.filter { return true } else { return false } }())
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

    private var namingRow: some View {
        HStack(spacing: 6) {
            NotchTextField(text: $namingText, placeholder: "Playlist name", symbol: "music.note.list", onCommit: { ui.commitNaming(namingText) })
            Button("Save") { ui.commitNaming(namingText) }.controlSize(.small).disabled(namingText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { ui.naming = nil }.controlSize(.small)
        }
        .frame(height: 24)
    }

    private func importRow(_ progress: (done: Int, total: Int)) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).progressViewStyle(.linear).tint(.accentColor)
            Text("Adding \(progress.done) / \(progress.total)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if ui.showQueue {
            QueueList()
        } else {
            let items = ui.visibleItems
            if library.items.isEmpty {
                EmptyLibrary()
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
            Text("Drop audio and video files or folders here, or use Add.").font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("mp3 · m4a · aac · flac · wav · aiff · mp4 · m4v · mov").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
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
                        Image(systemName: now.isPlaying ? "waveform" : "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative, isActive: now.isPlaying)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5))
                        Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11, weight: isCurrent ? .bold : .medium)).foregroundStyle(isCurrent ? Color.accentColor : .white).lineLimit(1)
                HStack(spacing: 4) {
                    if isMissing { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                    Text(isMissing ? String(localized: "File missing") : item.detail).font(.system(size: 9)).foregroundStyle(isMissing ? Color.orange : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.kind == .video { Image(systemName: "film").font(.system(size: 9)).foregroundStyle(.tertiary) }
            Text(PlayerFormat.clock(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isCurrent ? Color.accentColor.opacity(0.16) : (hovering ? Color.white.opacity(0.07) : .clear)))
        .overlay(alignment: .bottomLeading) {
            if item.progress > 0.01, item.progress < 0.99 {
                GeometryReader { geo in
                    Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: geo.size.width * item.progress, height: 1.5).offset(y: geo.size.height - 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { ui.play(item, in: items) }
        .contextMenu { RowMenu(item: item, items: items) }
    }
}

private struct Thumbnail: View {
    let item: MediaItem
    let size: CGFloat
    @ObservedObject private var library = PlayerLibrary.shared

    var body: some View {
        Group {
            if let image = library.artwork(for: item) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: item.kind == .video ? "film" : "music.note").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
        } label: { Label("Add to playlist", systemImage: "music.note.list") }
        if case .playlist(let id) = ui.filter {
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
                Button("Library") { ui.showQueue = false }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
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
                                    .foregroundStyle(now.currentID == item.id ? Color.accentColor : .white).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(PlayerFormat.clock(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(now.currentID == item.id ? Color.accentColor.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { engine.playFromQueue(item.id) }
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

// MARK: - Import result

private struct SummaryBanner: View {
    let summary: ImportSummary
    let dismiss: () -> Void

    private var text: String {
        var parts: [String] = []
        if summary.added > 0 { parts.append(String(localized: "Added \(summary.added)")) }
        if summary.alreadyInLibrary > 0 { parts.append(String(localized: "\(summary.alreadyInLibrary) already in the library")) }
        if !summary.unsupported.isEmpty { parts.append(String(localized: "\(summary.unsupported.count) in a format the system cannot play")) }
        if !summary.failed.isEmpty { parts.append(String(localized: "\(summary.failed.count) could not be read")) }
        return parts.joined(separator: " · ")
    }

    private var details: String {
        var lines: [String] = []
        if !summary.unsupported.isEmpty { lines.append(String(localized: "Not playable here: ") + summary.unsupported.prefix(12).joined(separator: ", ")) }
        if !summary.failed.isEmpty { lines.append(String(localized: "Could not be read: ") + summary.failed.prefix(12).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: summary.unsupported.isEmpty && summary.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(summary.unsupported.isEmpty && summary.failed.isEmpty ? Color.green : Color.orange)
            Text(text).font(.system(size: 10)).lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.09)))
        .help(Text(details))
        .task(id: summary) {
            // Good news goes away by itself; a problem stays until it is dismissed.
            if summary.unsupported.isEmpty && summary.failed.isEmpty {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                dismiss()
            }
        }
    }
}
