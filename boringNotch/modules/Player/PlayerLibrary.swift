//
//  PlayerLibrary.swift
//  boringNotch
//
//  The player's library: which files were added, what was read from them, where each was left off, and the playlists.
//  It lives in Application Support/Cove/Player as one JSON file plus a small thumbnail per item. Files are referenced,
//  never copied or moved.
//

import AppKit
import Foundation

@MainActor
final class PlayerLibrary: ObservableObject {
    #if DEBUG
    /// scripts/shots.sh sets this so a screenshot run uses a throw-away library instead of the user's.
    static let shared = PlayerLibrary(directory: ProcessInfo.processInfo.environment["COVE_PLAYER_SANDBOX"].map { URL(fileURLWithPath: $0) })
    #else
    static let shared = PlayerLibrary()
    #endif

    private struct FileFormat: Codable {
        var version = 1
        var items: [MediaItem] = []
        var playlists: [Playlist] = []
    }

    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var playlists: [Playlist] = []
    /// Items whose file is no longer where it was (and could not be found through its bookmark).
    @Published private(set) var missing: Set<UUID> = []
    @Published private(set) var importProgress: (done: Int, total: Int)?
    @Published var lastSummary: ImportSummary?

    private let directory: URL
    private var saveTask: Task<Void, Never>?
    private let artworkCache = NSCache<NSUUID, NSImage>()
    private var byID: [UUID: Int] = [:]

    /// `directory` is for tests, which use a folder of their own instead of the user's library.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Cove"
            self.directory = support.appendingPathComponent(name).appendingPathComponent("Player")
        }
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        load()
        Task { await checkAvailability() }
    }

    private var libraryFile: URL { directory.appendingPathComponent("library.json") }
    private var artworkDirectory: URL { directory.appendingPathComponent("artwork") }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        do {
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            items = file.items; playlists = file.playlists
            reindex()
        } catch {
            // Never throw a library away because it did not parse: keep the file aside and start fresh.
            let aside = directory.appendingPathComponent("library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: libraryFile, to: aside)
        }
    }

    private func reindex() {
        byID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    /// Writes soon, and once for a burst of changes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let file = FileFormat(items: items, playlists: playlists)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: libraryFile, options: .atomic)
    }

    // MARK: Lookup

    func item(_ id: UUID) -> MediaItem? { byID[id].map { items[$0] } }

    func items(matching filter: LibraryFilter, search: String = "", sort: LibrarySort = .recentlyAdded) -> [MediaItem] {
        var result: [MediaItem]
        switch filter {
        case .all: result = items
        case .audio: result = items.filter { $0.kind == .audio }
        case .video: result = items.filter { $0.kind == .video }
        case .playlist(let id):
            // A playlist keeps its own order; sorting does not apply to it.
            let order = playlists.first { $0.id == id }?.itemIDs ?? []
            result = order.compactMap { item($0) }
            return Self.search(result, for: search)
        }
        result = Self.search(result, for: search)
        switch sort {
        case .recentlyAdded: result.sort { $0.addedAt > $1.addedAt }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            result.sort {
                let byArtist = $0.artist.localizedStandardCompare($1.artist)
                return byArtist == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : byArtist == .orderedAscending
            }
        case .duration: result.sort { $0.duration > $1.duration }
        case .recentlyPlayed: result.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        }
        return result
    }

    /// Case- and accent-insensitive match on title, artist, album and file name; every word has to match somewhere.
    static func search(_ items: [MediaItem], for query: String) -> [MediaItem] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = [item.title, item.artist, item.album, item.fileName].joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var totalDuration: TimeInterval { items.reduce(0) { $0 + $1.duration } }

    // MARK: Import

    /// Adds files and folders (searched recursively). Returns what happened, for the summary the user sees.
    @discardableResult
    func importURLs(_ urls: [URL]) async -> ImportSummary {
        var summary = ImportSummary()
        let candidates = Self.collectFiles(urls, summary: &summary)
        var known = Set(items.map(\.path))
        var fresh: [URL] = []
        for url in candidates {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if known.contains(path) { summary.alreadyInLibrary += 1 } else { known.insert(path); fresh.append(URL(fileURLWithPath: path)) }
        }

        importProgress = fresh.isEmpty ? nil : (0, fresh.count)
        var done = 0
        var pending: [MediaItem] = []

        await withTaskGroup(of: (URL, MediaProbeResult?).self) { group in
            var iterator = fresh.makeIterator()
            func startNext() -> Bool {
                guard let url = iterator.next() else { return false }
                group.addTask { (url, await MediaProbe.probe(url)) }
                return true
            }
            for _ in 0..<4 { _ = startNext() }
            for await (url, probe) in group {
                done += 1
                if let probe {
                    pending.append(makeItem(url: url, probe: probe))
                } else {
                    summary.failed.append(url.lastPathComponent)
                }
                if pending.count >= 20 { append(pending); pending = [] }
                importProgress = (done, fresh.count)
                _ = startNext()
            }
        }
        append(pending)
        summary.added = fresh.count - summary.failed.count
        importProgress = nil
        if !summary.isEmpty { lastSummary = summary }
        return summary
    }

    private func makeItem(url: URL, probe: MediaProbeResult) -> MediaItem {
        var item = MediaItem(path: url.path, bookmark: try? url.bookmarkData(), title: probe.title, artist: probe.artist, album: probe.album,
                             duration: probe.duration, kind: probe.kind)
        item.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        if let thumbnail = probe.thumbnail {
            try? thumbnail.write(to: artworkURL(item.id), options: .atomic)
            item.hasArtwork = true
        }
        return item
    }

    private func append(_ new: [MediaItem]) {
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        reindex()
        scheduleSave()
    }

    /// Files from what was dropped or chosen: folders are walked, hidden files and packages skipped.
    nonisolated static func collectFiles(_ urls: [URL], summary: inout ImportSummary, limit: Int = 20_000) -> [URL] {
        var files: [URL] = []
        func consider(_ url: URL) {
            switch MediaFormats.support(of: url) {
            case .supported: files.append(url)
            case .unsupported: summary.unsupported.append(url.lastPathComponent)
            case .notMedia: break
            }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let next = enumerator?.nextObject() as? URL, files.count < limit {
                    if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { consider(next) }
                }
            } else {
                consider(url)
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return files
    }

    // MARK: Files that moved

    /// The file for an item, following its bookmark if it moved. nil when it cannot be found.
    func resolveURL(for id: UUID) -> URL? {
        guard let index = byID[id] else { return nil }
        let item = items[index]
        if FileManager.default.fileExists(atPath: item.path) { return item.url }
        guard let bookmark = item.bookmark else { return nil }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: found.path) else { return nil }
        items[index].path = found.path
        if stale { items[index].bookmark = try? found.bookmarkData() }
        missing.remove(id)
        scheduleSave()
        return found
    }

    /// Looks for every item's file (and follows bookmarks); the ones not found are listed in `missing`.
    func checkAvailability() async {
        var gone: Set<UUID> = []
        for item in items where resolveURL(for: item.id) == nil { gone.insert(item.id) }
        if gone != missing { missing = gone }
    }

    /// Points an item at a file the user picked after it went missing.
    func relocate(_ id: UUID, to url: URL) {
        guard let index = byID[id] else { return }
        items[index].path = url.path
        items[index].bookmark = try? url.bookmarkData()
        missing.remove(id)
        scheduleSave()
    }

    // MARK: Editing

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { try? FileManager.default.removeItem(at: artworkURL(id)); artworkCache.removeObject(forKey: id as NSUUID) }
        items.removeAll { ids.contains($0.id) }
        for index in playlists.indices { playlists[index].itemIDs.removeAll { ids.contains($0) } }
        missing.subtract(ids)
        reindex()
        scheduleSave()
    }

    func removeMissing() { remove(missing) }

    func removeAll() { remove(Set(items.map(\.id))) }

    func recordPosition(_ id: UUID, _ seconds: TimeInterval) {
        guard let index = byID[id] else { return }
        items[index].lastPosition = seconds
        scheduleSave()
    }

    /// A track started playing (not merely resumed): counts a play and remembers when.
    func recordPlay(_ id: UUID) {
        guard let index = byID[id] else { return }
        items[index].playCount += 1
        items[index].lastPlayedAt = Date()
        scheduleSave()
    }

    func updateDuration(_ id: UUID, _ seconds: TimeInterval) {
        guard let index = byID[id], seconds.isFinite, seconds > 0, abs(items[index].duration - seconds) > 1 else { return }
        items[index].duration = seconds
        scheduleSave()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(named name: String, with ids: [UUID] = []) -> Playlist {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: clean.isEmpty ? String(localized: "Untitled playlist") : clean, itemIDs: ids)
        playlists.append(playlist)
        scheduleSave()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        playlists[index].name = clean
        scheduleSave()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    func add(_ ids: [UUID], toPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        for itemID in ids where !playlists[index].itemIDs.contains(itemID) { playlists[index].itemIDs.append(itemID) }
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>, fromPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].itemIDs.removeAll { ids.contains($0) }
        scheduleSave()
    }

    func moveInPlaylist(_ id: UUID, from: IndexSet, to: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].itemIDs.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    // MARK: Artwork

    private func artworkURL(_ id: UUID) -> URL { artworkDirectory.appendingPathComponent(id.uuidString + ".jpg") }

    func artwork(for item: MediaItem) -> NSImage? {
        guard item.hasArtwork else { return nil }
        if let cached = artworkCache.object(forKey: item.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: artworkURL(item.id)) else { return nil }
        artworkCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }
}
