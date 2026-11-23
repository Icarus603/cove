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
    /// Small thumbnails, so a few hundred cost a few MB; the limit keeps scrolling through a library of ten thousand from filling memory.
    private let artworkCache: NSCache<NSUUID, NSImage> = { let cache = NSCache<NSUUID, NSImage>(); cache.countLimit = 400; return cache }()
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

    /// Every write to the library file goes through this queue, in order, off the main thread: encoding a few thousand items
    /// and writing them atomically took tens of milliseconds, and it happened every few seconds while something played.
    private static let writeQueue = DispatchQueue(label: "app.cove.player.library.write", qos: .utility)

    /// Writes soon, and once for a burst of changes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            let file = FileFormat(items: self.items, playlists: self.playlists)   // a snapshot taken here, written elsewhere
            let url = self.libraryFile
            Self.writeQueue.async { Self.write(file, to: url) }
        }
    }

    /// Writes now and returns when it is on disk (pausing, quitting, tests). Waits behind any write already queued.
    func saveNow() {
        let file = FileFormat(items: items, playlists: playlists)
        let url = libraryFile
        Self.writeQueue.sync { Self.write(file, to: url) }
    }

    private nonisolated static func write(_ file: FileFormat, to url: URL) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
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
        case .recentlyAdded: result = Self.recentlyAddedOrder(result)
        case .title:
            result.sort { Self.ordered($0.title.localizedStandardCompare($1.title), $0, $1) }
        case .artist:
            result.sort {
                let byArtist = $0.artist.localizedStandardCompare($1.artist)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return Self.ordered($0.title.localizedStandardCompare($1.title), $0, $1)
            }
        case .duration:
            result.sort { $0.duration != $1.duration ? $0.duration > $1.duration : Self.byName($0, $1) }
        case .recentlyPlayed:
            result.sort {
                let a = $0.lastPlayedAt ?? .distantPast, b = $1.lastPlayedAt ?? .distantPast
                return a != b ? a > b : Self.byName($0, $1)
            }
        }
        return result
    }

    /// File-name order with numbers read as numbers (episode 9 before episode 10), the tie-break for every sort.
    static func byName(_ a: MediaItem, _ b: MediaItem) -> Bool {
        a.path.localizedStandardCompare(b.path) == .orderedAscending
    }

    private static func ordered(_ comparison: ComparisonResult, _ a: MediaItem, _ b: MediaItem) -> Bool {
        comparison == .orderedSame ? byName(a, b) : comparison == .orderedAscending
    }

    /// Newest first, but files added together stay together and in file-name order. A batch is a run of additions no more than
    /// two minutes apart (a long import stamps each file a moment later than the last); without this a folder added in one go
    /// came out backwards, last file first.
    static func recentlyAddedOrder(_ items: [MediaItem], newestFirst: Bool = true) -> [MediaItem] {
        var batchStart: [UUID: Date] = [:]
        var current = Date.distantPast
        var last: Date?
        for item in items.sorted(by: { $0.addedAt < $1.addedAt }) {
            if let last, item.addedAt.timeIntervalSince(last) <= 120 {} else { current = item.addedAt }
            batchStart[item.id] = current
            last = item.addedAt
        }
        return items.sorted { a, b in
            let x = batchStart[a.id] ?? .distantPast, y = batchStart[b.id] ?? .distantPast
            if x != y { return newestFirst ? x > y : x < y }
            return byName(a, b)
        }
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
        // Walking folders and asking about every file is disk work: not on the main thread.
        let (candidates, skippedByFormat) = await Task.detached(priority: .userInitiated) { () -> ([URL], [SkippedFile]) in
            var found = ImportSummary()
            let files = Self.collectFiles(urls, summary: &found)
            return (files, found.skipped)
        }.value
        summary.skipped = skippedByFormat
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
                    summary.skipped.append(await SkippedFile.diagnoseMedia(url.path))
                }
                if pending.count >= 20 { append(pending); pending = [] }
                // The count is shown, not every file: a redraw per file of a big import redrew (and re-sorted) the library list.
                if done % 10 == 0 || done == fresh.count { importProgress = (done, fresh.count) }
                _ = startNext()
            }
        }
        append(pending)
        summary.added = fresh.count - summary.failed.count
        let idByPath = Dictionary(items.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        summary.itemIDs = candidates.compactMap { idByPath[$0.standardizedFileURL.resolvingSymlinksInPath().path] }
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
            case .unsupported: summary.skipped.append(SkippedFile(path: url.path, reason: .format, domain: .media))
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

    /// What looking for one file found. Done off the main thread: a library on a network drive can take seconds.
    private enum Found { case here, moved(path: String, bookmark: Data?), gone }

    private nonisolated static func look(path: String, bookmark: Data?) -> Found {
        if FileManager.default.fileExists(atPath: path) { return .here }
        guard let bookmark else { return .gone }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: found.path) else { return .gone }
        return .moved(path: found.path, bookmark: stale ? (try? found.bookmarkData()) : nil)
    }

    /// Looks for every item's file (and follows bookmarks); the ones not found are listed in `missing`. The looking happens in
    /// the background; only the result comes back to the main thread.
    func checkAvailability() async {
        let snapshot = items.map { ($0.id, $0.path, $0.bookmark) }
        let results = await Task.detached(priority: .utility) { snapshot.map { ($0.0, Self.look(path: $0.1, bookmark: $0.2)) } }.value
        var gone: Set<UUID> = []
        var changed = false
        for (id, found) in results {
            switch found {
            case .here: break
            case .gone: gone.insert(id)
            case .moved(let path, let bookmark):
                if let index = byID[id] { items[index].path = path; if let bookmark { items[index].bookmark = bookmark }; changed = true }
            }
        }
        if gone != missing { missing = gone }
        if changed { scheduleSave() }
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

    /// Replaces a playlist's order (the same tracks, arranged differently). Anything not already in the playlist is ignored.
    func setOrder(_ ids: [UUID], forPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let members = Set(playlists[index].itemIDs)
        playlists[index].itemIDs = ids.filter { members.contains($0) }
        scheduleSave()
    }

    /// Puts a playlist in order in one go: by file name (episode 9 before 10), by title, or simply back to front.
    func arrange(_ id: UUID, _ how: PlaylistArrange) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let members = playlists[index].itemIDs.compactMap { item($0) }
        let ordered: [MediaItem]
        switch how {
        case .fileName: ordered = members.sorted { Self.byName($0, $1) }
        case .title: ordered = members.sorted { $0.title.localizedStandardCompare($1.title) == .orderedSame ? Self.byName($0, $1) : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .reverse: ordered = Array(members.reversed())
        }
        // Entries whose item is gone stay at the end rather than being lost silently.
        let known = Set(ordered.map(\.id))
        playlists[index].itemIDs = ordered.map(\.id) + playlists[index].itemIDs.filter { !known.contains($0) }
        scheduleSave()
    }

    func moveInPlaylist(_ id: UUID, from: IndexSet, to: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].itemIDs.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    // MARK: Artwork

    private func artworkURL(_ id: UUID) -> URL { artworkDirectory.appendingPathComponent(id.uuidString + ".jpg") }

    /// What is in memory already, never touching the disk (what a row asks for while it is drawn).
    func cachedArtwork(for item: MediaItem) -> NSImage? {
        item.hasArtwork ? artworkCache.object(forKey: item.id as NSUUID) : nil
    }

    /// Reads a thumbnail in the background and keeps it. A row shows its placeholder until this comes back.
    func loadArtwork(for item: MediaItem) async -> NSImage? {
        guard item.hasArtwork else { return nil }
        if let cached = artworkCache.object(forKey: item.id as NSUUID) { return cached }
        let url = artworkURL(item.id)
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image { artworkCache.setObject(image, forKey: item.id as NSUUID) }
        return image
    }

    func artwork(for item: MediaItem) -> NSImage? {
        guard item.hasArtwork else { return nil }
        if let cached = artworkCache.object(forKey: item.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: artworkURL(item.id)) else { return nil }
        artworkCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }
}
