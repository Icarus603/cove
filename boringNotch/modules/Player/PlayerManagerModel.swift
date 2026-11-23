//
//  PlayerManagerModel.swift
//  boringNotch
//
//  The logic behind the library manager window: which items a scope shows, searching and sorting, the selection, and the
//  bulk actions (remove many at once, add many to a playlist, move within a playlist). Kept out of the views so it can be
//  tested without a window.
//

import Combine
import Foundation
import SwiftUI

enum PlayerScope: Hashable {
    case all, music, video, missing
    case playlist(UUID)
}

@MainActor
final class PlayerManagerModel: ObservableObject {
    let library: PlayerLibrary

    @Published var scope: PlayerScope = .all { didSet { if oldValue != scope { selection = []; refresh() } } }
    @Published var search = "" { didSet { if oldValue != search { refresh() } } }
    @Published var sortOrder: [KeyPathComparator<MediaItem>] = [KeyPathComparator(\.addedAt, order: .reverse)] { didSet { refresh() } }
    @Published var selection: Set<UUID> = []
    /// What the scope, search and sort show, in order. Updated when any of them or the library changes.
    @Published private(set) var rows: [MediaItem] = []

    private var observers: Set<AnyCancellable> = []

    init(library: PlayerLibrary = .shared) {
        self.library = library
        library.$items.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &observers)
        library.$playlists.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &observers)
        library.$missing.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &observers)
        refresh()
    }

    // MARK: What is shown

    func refresh() {
        var items: [MediaItem]
        switch scope {
        case .all: items = library.items
        case .music: items = library.items.filter { $0.kind == .audio }
        case .video: items = library.items.filter { $0.kind == .video }
        case .missing: items = library.items.filter { library.missing.contains($0.id) }
        case .playlist(let id):
            // A playlist keeps the order it was arranged in.
            items = Self.search((library.playlists.first { $0.id == id }?.itemIDs ?? []).compactMap { library.item($0) }, for: search)
            rows = items
            selection.formIntersection(Set(items.map(\.id)))
            return
        }
        items = Self.search(items, for: search)
        if let first = sortOrder.first, first.keyPath == \MediaItem.addedAt {
            items = PlayerLibrary.recentlyAddedOrder(items, newestFirst: first.order == .reverse)
        } else {
            // Equal values (the same artist, the same length) fall back to file-name order instead of an arbitrary one.
            items.sort(using: sortOrder + [KeyPathComparator(\.path, comparator: .localizedStandard)])
        }
        rows = items
        selection.formIntersection(Set(items.map(\.id)))
    }

    static func search(_ items: [MediaItem], for query: String) -> [MediaItem] { PlayerLibrary.search(items, for: query) }

    var isPlaylist: Bool { if case .playlist = scope { return true } else { return false } }
    var playlistID: UUID? { if case .playlist(let id) = scope { return id } else { return nil } }

    func count(for scope: PlayerScope) -> Int {
        switch scope {
        case .all: return library.items.count
        case .music: return library.items.filter { $0.kind == .audio }.count
        case .video: return library.items.filter { $0.kind == .video }.count
        case .missing: return library.missing.count
        case .playlist(let id): return library.playlists.first { $0.id == id }?.itemIDs.count ?? 0
        }
    }

    var title: String {
        switch scope {
        case .all: return String(localized: "All Items")
        case .music: return String(localized: "Audio")
        case .video: return String(localized: "Video")
        case .missing: return String(localized: "Missing Files")
        case .playlist(let id): return library.playlists.first { $0.id == id }?.name ?? String(localized: "Playlist")
        }
    }

    // MARK: Selection

    func selectAll() { selection = Set(rows.map(\.id)) }
    func clearSelection() { selection = [] }
    var allSelected: Bool { !rows.isEmpty && selection.count == rows.count }

    // MARK: Removing

    /// In a playlist this takes tracks out of the playlist; anywhere else it takes them out of the library. Files are never touched.
    func removeSelected() { remove(Array(selection)) }

    /// The same for everything the current scope and search show: the quick way to clear all videos, all missing files…
    func removeAllShown() { remove(rows.map(\.id)) }

    private func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if let playlist = playlistID { library.remove(Set(ids), fromPlaylist: playlist) } else { library.remove(Set(ids)) }
        selection.subtract(ids)
    }

    /// Takes tracks out of the library even while looking at a playlist.
    func removeSelectedFromLibrary() {
        library.remove(selection)
        selection = []
    }

    // MARK: Playlists

    func addSelected(toPlaylist id: UUID) { library.add(rows.map(\.id).filter { selection.contains($0) }, toPlaylist: id) }

    @discardableResult
    func newPlaylist(named name: String, withSelection: Bool) -> Playlist {
        let ids = withSelection ? rows.map(\.id).filter { selection.contains($0) } : []
        return library.createPlaylist(named: name, with: ids)
    }

    /// Moves the selected tracks one place up (offset -1) or down (+1) within the playlist being shown.
    func moveSelected(by offset: Int) {
        guard let id = playlistID, let playlist = library.playlists.first(where: { $0.id == id }) else { return }
        library.setOrder(Self.moved(playlist.itemIDs, selected: selection, by: offset), forPlaylist: id)
    }

    /// `ids` with every selected element moved one place towards the start (offset < 0) or the end (offset > 0). Selected
    /// elements keep their order and the ones between are not disturbed more than needed.
    static func moved(_ ids: [UUID], selected: Set<UUID>, by offset: Int) -> [UUID] {
        var result = ids
        if offset < 0 {
            for index in result.indices where index > 0 && selected.contains(result[index]) && !selected.contains(result[index - 1]) { result.swapAt(index, index - 1) }
        } else if offset > 0 {
            for index in result.indices.reversed() where index < result.count - 1 && selected.contains(result[index]) && !selected.contains(result[index + 1]) { result.swapAt(index, index + 1) }
        }
        return result
    }

    var canMoveUp: Bool {
        guard isPlaylist, !selection.isEmpty, let first = rows.first else { return false }
        return !selection.contains(first.id) || selection.count < rows.count && rows.drop(while: { selection.contains($0.id) }).count > 0
    }

    func play(_ item: MediaItem) { PlayerUI.shared.play(item, in: rows) }
}
