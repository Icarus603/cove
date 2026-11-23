//
//  PhotoLibrary.swift
//  boringNotch
//
//  The photo library the views talk to: adding files and folders, the lists to show, albums, thumbnails, and noticing
//  files that moved or vanished. Photos are referenced by path (plus a bookmark that follows a move), never copied; the
//  database lives in Application Support/Cove/Photos with the thumbnails beside it.
//

import AppKit
import Foundation

@MainActor
final class PhotoLibrary: ObservableObject {
    #if DEBUG
    /// scripts/shots.sh sets this so a run uses a throw-away library instead of the user's.
    static let shared = PhotoLibrary(directory: ProcessInfo.processInfo.environment["COVE_PHOTO_SANDBOX"].map { URL(fileURLWithPath: $0) })
    #else
    static let shared = PhotoLibrary()
    #endif

    @Published private(set) var albums: [Album] = []
    /// The album list has been read from the database at least once (before that, an empty list means nothing).
    private(set) var summaryLoaded = false
    @Published private(set) var photoCount = 0
    @Published private(set) var missingCount = 0
    @Published private(set) var importProgress: (done: Int, total: Int)?
    @Published var lastSummary: PhotoImportSummary?
    /// Raised whenever what the library holds changes, so lists reload.
    @Published private(set) var revision = 0
    /// Set when the database could not be opened.
    @Published private(set) var problem: String?

    let directory: URL
    private(set) var store: PhotoStore?
    let thumbnails: PhotoThumbnails
    private var photoCache: [Int64: Photo] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Cove"
            self.directory = support.appendingPathComponent(name).appendingPathComponent("Photos")
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        thumbnails = PhotoThumbnails(directory: self.directory.appendingPathComponent("thumbnails", isDirectory: true))
        openStore()
        Task { await reloadSummary(); await checkAvailability() }
    }

    private func openStore() {
        let file = directory.appendingPathComponent("photos.sqlite")
        if let opened = try? PhotoStore(url: file) { store = opened; return }
        // A database that will not open is kept aside, not deleted, and a fresh one started.
        let aside = directory.appendingPathComponent("photos.corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
        try? FileManager.default.moveItem(at: file, to: aside)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + suffix)) }
        if let opened = try? PhotoStore(url: file) { store = opened; problem = nil } else { problem = String(localized: "The photo library could not be opened.") }
    }

    // MARK: Summary

    func reloadSummary() async {
        guard let store else { return }
        if let counts = try? await store.counts() { photoCount = counts.photos; missingCount = counts.missing }
        if let list = try? await store.albums() { albums = list; summaryLoaded = true }
    }

    private func changed() async {
        photoCache.removeAll()
        await reloadSummary()
        revision += 1
    }

    // MARK: Lists

    func ids(scope: PhotoScope, search: String = "", sort: PhotoSort = .takenNewest) async -> [Int64] {
        guard let store else { return [] }
        return (try? await store.ids(scope: scope, search: search, sort: sort)) ?? []
    }

    /// The photos for ids, in the order asked. Ones that no longer exist are left out.
    func photos(_ ids: [Int64]) async -> [Photo] {
        guard let store else { return [] }
        let missing = ids.filter { photoCache[$0] == nil }
        if !missing.isEmpty, let fetched = try? await store.photos(ids: missing) {
            for (id, photo) in fetched { photoCache[id] = photo }
            if photoCache.count > 20_000 { photoCache = photoCache.filter { fetched[$0.key] != nil } }
        }
        return ids.compactMap { photoCache[$0] }
    }

    func photo(_ id: Int64) async -> Photo? { await photos([id]).first }

    /// The id of the photo stored at this path (already standardised), if it is in the library.
    func id(forPath path: String) async -> Int64? { (try? await store?.idsByPath([path]))?[path] }

    // MARK: Images

    func thumbnail(for photo: Photo) async -> NSImage? {
        if photo.isMissing { return nil }
        return await thumbnails.thumbnail(id: photo.id, url: photo.url)
    }

    /// The picture at up to `maxPixel` on its long side, decoded off the main thread, orientation applied.
    nonisolated func image(at url: URL, maxPixel: Int) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let cg = PhotoThumbnails.makeThumbnail(url: url, maxPixel: maxPixel) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    // MARK: Adding

    /// Adds image files and folders (searched recursively). Returns what happened, for the summary the user sees.
    @discardableResult
    func importURLs(_ urls: [URL]) async -> PhotoImportSummary {
        var summary = PhotoImportSummary()
        guard let store else { return summary }
        let (candidates, skipped) = await Task.detached(priority: .userInitiated) { () -> ([String], [SkippedFile]) in
            var s = PhotoImportSummary()
            let files = Self.collectFiles(urls, summary: &s)
            return (files.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }, s.skipped)
        }.value
        summary.skipped = skipped
        summary.candidatePaths = candidates
        let known = (try? await store.knownPaths(among: candidates)) ?? []
        var seen = Set<String>()
        var fresh: [String] = []
        for path in candidates {
            if known.contains(path) || !seen.insert(path).inserted { summary.alreadyInLibrary += 1 } else { fresh.append(path) }
        }

        importProgress = fresh.isEmpty ? nil : (0, fresh.count)
        var done = 0
        var batch: [PhotoRecord] = []
        var inserted = 0
        let now = Date()

        await withTaskGroup(of: (String, PhotoRecord?).self) { group in
            var iterator = fresh.makeIterator()
            func startNext() -> Bool {
                guard let path = iterator.next() else { return false }
                group.addTask {
                    let url = URL(fileURLWithPath: path)
                    guard let meta = PhotoProbe.read(url) else { return (path, nil) }
                    return (path, PhotoRecord(path: path, bookmark: try? url.bookmarkData(), name: url.lastPathComponent, width: meta.width,
                                              height: meta.height, taken: meta.taken, added: now, size: meta.size))
                }
                return true
            }
            for _ in 0..<6 { _ = startNext() }
            for await (path, record) in group {
                done += 1
                if let record { batch.append(record) } else { summary.skipped.append(SkippedFile.diagnose(path, domain: .photo)) }
                if batch.count >= 200 {
                    inserted += (try? await store.insert(batch)) ?? 0
                    batch = []
                    importProgress = (done, fresh.count)
                } else if done % 25 == 0 {
                    importProgress = (done, fresh.count)
                }
                _ = startNext()
            }
        }
        if !batch.isEmpty { inserted += (try? await store.insert(batch)) ?? 0 }
        summary.added = inserted
        importProgress = nil
        if !summary.isEmpty { lastSummary = summary }
        await changed()
        return summary
    }

    /// Image files in what was dropped or chosen: folders are walked, hidden files and packages skipped.
    nonisolated static func collectFiles(_ urls: [URL], summary: inout PhotoImportSummary, limit: Int = 500_000) -> [URL] {
        var files: [URL] = []
        func consider(_ url: URL) {
            switch PhotoFormats.support(of: url) {
            case .supported: files.append(url)
            case .unsupported: summary.skipped.append(SkippedFile(path: url.path, reason: .format, domain: .photo))
            case .notAnImage: break
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
        return files
    }

    // MARK: Removing

    /// Takes photos out of the library (and their thumbnails). Never touches the files.
    func remove(_ ids: [Int64]) async {
        guard let store, !ids.isEmpty else { return }
        try? await store.remove(ids)
        thumbnails.remove(ids)
        await changed()
    }

    func removeMissing() async {
        let ids = await ids(scope: .all).isEmpty ? [] : await missingIDs()
        await remove(ids)
    }

    func removeEverything() async {
        guard let store else { return }
        try? await store.removeAllPhotos()
        thumbnails.clear()
        await changed()
    }

    private func missingIDs() async -> [Int64] {
        guard let store, let refs = try? await store.fileReferences() else { return [] }
        let all = await photos(refs.map(\.id))
        return all.filter(\.isMissing).map(\.id)
    }

    // MARK: Files that moved

    /// Looks for every photo's file, following bookmarks for ones that moved. What is not found is marked missing.
    func checkAvailability() async {
        guard let store, let refs = try? await store.fileReferences() else { return }
        let result = await Task.detached(priority: .utility) { () -> (missing: [Int64], found: [Int64], moved: [(Int64, String, Data?)]) in
            var missing: [Int64] = [], found: [Int64] = []
            var moved: [(Int64, String, Data?)] = []
            for ref in refs {
                if FileManager.default.fileExists(atPath: ref.path) { found.append(ref.id); continue }
                if let bookmark = ref.bookmark {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                       FileManager.default.fileExists(atPath: url.path) {
                        moved.append((ref.id, url.path, try? url.bookmarkData()))
                        continue
                    }
                }
                missing.append(ref.id)
            }
            return (missing, found, moved)
        }.value
        for (id, path, bookmark) in result.moved { try? await store.updateLocation(id: id, path: path, bookmark: bookmark) }
        try? await store.setMissing(result.missing, found: result.found)
        await changed()
    }

    /// Points one photo at a file the user picked.
    func relocate(_ id: Int64, to url: URL) async {
        try? await store?.updateLocation(id: id, path: url.path, bookmark: try? url.bookmarkData())
        await changed()
    }

    /// After a whole folder was moved: looks in `folder` for the files of missing photos, by file name, and reconnects the ones
    /// found exactly once. Returns how many were reconnected.
    @discardableResult
    func relocateMissing(inFolder folder: URL) async -> Int {
        guard let store else { return 0 }
        let missing = await photos(await missingIDs())
        guard !missing.isEmpty else { return 0 }
        let index = await Task.detached(priority: .userInitiated) { () -> [String: [URL]] in
            var s = PhotoImportSummary()
            var byName: [String: [URL]] = [:]
            for url in Self.collectFiles([folder], summary: &s) { byName[url.lastPathComponent.lowercased(), default: []].append(url) }
            return byName
        }.value
        var reconnected = 0
        for photo in missing {
            guard let matches = index[photo.name.lowercased()], matches.count == 1, let url = matches.first else { continue }
            try? await store.updateLocation(id: photo.id, path: url.standardizedFileURL.path, bookmark: try? url.bookmarkData())
            reconnected += 1
        }
        await changed()
        return reconnected
    }

    // MARK: Albums

    /// Where photos go as they are added.
    enum Destination { case none, existing(Int64), new(String) }

    /// Puts the photos of an import into an album, an existing one or a new one. Albums are made by the user, never from the
    /// folder layout (folders are nested; an album per folder would be a heap). Returns how the result should be described.
    func file(_ summary: PhotoImportSummary, into destination: Destination) async -> String? {
        guard let store, !summary.candidatePaths.isEmpty else { return nil }
        let idByPath = (try? await store.idsByPath(summary.candidatePaths)) ?? [:]
        func ids(_ paths: [String]) -> [Int64] { paths.compactMap { idByPath[$0] } }
        switch destination {
        case .none:
            return nil
        case .existing(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return nil }
            await add(ids(summary.candidatePaths), toAlbum: id)
            return "“\(album.name)”"
        case .new(let name):
            let album = await createAlbum(named: name.isEmpty ? Self.folderName(summary.candidatePaths.first) : name, with: ids(summary.candidatePaths))
            return album.map { "“\($0.name)”" }
        }
    }

    private static func folderName(_ path: String?) -> String {
        path.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent } ?? ""
    }

    @discardableResult
    func createAlbum(named name: String, with ids: [Int64] = []) async -> Album? {
        guard let store else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = clean.isEmpty ? String(localized: "Untitled album") : clean
        guard let id = try? await store.createAlbum(named: title) else { return nil }
        if !ids.isEmpty { _ = try? await store.add(ids, toAlbum: id) }
        await changed()
        return albums.first { $0.id == id }
    }

    func setAlbumOrder(_ albumID: Int64, ordered: [Int64]) async {
        try? await store?.setAlbumOrder(albumID, ordered: ordered)
        await changed()   // the notch's strip shows the new order too
    }

    func renameAlbum(_ id: Int64, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try? await store?.renameAlbum(id, to: clean)
        await reloadSummary()
    }

    func deleteAlbum(_ id: Int64) async {
        try? await store?.deleteAlbum(id)
        await changed()
    }

    /// Returns how many were added (photos already in the album are not added twice).
    @discardableResult
    func add(_ ids: [Int64], toAlbum albumID: Int64) async -> Int {
        let added = (try? await store?.add(ids, toAlbum: albumID)) ?? 0
        await changed()
        return added
    }

    func remove(_ ids: [Int64], fromAlbum albumID: Int64) async {
        try? await store?.remove(ids, fromAlbum: albumID)
        await changed()
    }

    func albumIDs(containing photoID: Int64) async -> Set<Int64> {
        (try? await store?.albumIDs(containing: photoID)) ?? []
    }

    func coverPhoto(ofAlbum id: Int64) async -> Photo? {
        guard let coverID = try? await store?.coverPhotoID(ofAlbum: id) else { return nil }
        return await photo(coverID)
    }

    // MARK: Cache

    func thumbnailBytes() async -> Int64 {
        await Task.detached { self.thumbnails.diskSize() }.value
    }

    func clearThumbnails() {
        thumbnails.clear()
        revision += 1
    }
}
