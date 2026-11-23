//
//  PhotoBrowserModel.swift
//  boringNotch
//
//  What one photo window is showing and doing: the list (an album or everything, searched and sorted), the selection, which
//  photo is open in the viewer, and the slideshow. Timers live here, not in views: views are rebuilt all the time and a
//  timer made inside one is replaced before it fires.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PhotoBrowserModel: ObservableObject {
    let library: PhotoLibrary

    @Published var scope: PhotoScope = .all { didSet { if oldValue != scope { selection = []; reload() } } }
    @Published var search = "" { didSet { if oldValue != search { scheduleReload() } } }
    @Published var sort: PhotoSort { didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey); reload() } }
    /// Inside an album the photos are in the order the user arranged, unless another order is picked here.
    @Published var albumSort: PhotoSort { didSet { UserDefaults.standard.set(albumSort.rawValue, forKey: Self.albumSortKey); reload() } }
    @Published var thumbSize: Double { didSet { UserDefaults.standard.set(thumbSize, forKey: Self.sizeKey) } }
    @Published private(set) var ids: [Int64] = []
    @Published var selection: Set<Int64> = []
    /// The photo open in the viewer, if any.
    @Published var viewing: Int64?
    /// The photo being edited (always the one open in the viewer, which stays underneath), if any.
    @Published var editing: Int64?
    @Published var toast: String?
    @Published private(set) var slideshowActive = false
    /// The viewer's controls are shown, or have faded during a slideshow.
    @Published var chromeVisible = true
    @Published var isLoading = false

    private static let sortKey = "photos.sort"
    private static let albumSortKey = "photos.albumSort"
    private static let sizeKey = "photos.thumbSize"
    private var anchor: Int64?
    private var reloadTask: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var slideshowTimer: Timer?
    private var chromeTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private(set) var lastActivity = Date()
    static let slideshowInterval: TimeInterval = 4

    init(library: PhotoLibrary = .shared) {
        self.library = library
        let storedSort = PhotoSort(rawValue: UserDefaults.standard.string(forKey: Self.sortKey) ?? "") ?? .takenNewest
        sort = storedSort == .manual ? .takenNewest : storedSort
        albumSort = PhotoSort(rawValue: UserDefaults.standard.string(forKey: Self.albumSortKey) ?? "") ?? .manual
        let stored = UserDefaults.standard.double(forKey: Self.sizeKey)
        thumbSize = stored > 0 ? stored : 150
        observer = library.$revision.dropFirst().sink { [weak self] _ in self?.reload() }
        reload()
    }

    deinit {
        slideshowTimer?.invalidate()
        chromeTimer?.invalidate()
    }

    // MARK: Sorting and arranging

    var isAlbum: Bool { if case .album = scope { return true } else { return false } }

    /// The sort in force here: the album's own while an album is open.
    var currentSort: PhotoSort {
        get { isAlbum ? albumSort : sort }
        set { if isAlbum { albumSort = newValue } else { sort = newValue } }
    }

    /// Photos can be moved by hand in an album that is showing its own order and not being searched.
    var canArrange: Bool { isAlbum && albumSort == .manual && search.isEmpty }

    func moveInAlbum(_ moving: Set<Int64>, _ move: PhotoMove) {
        guard canArrange, case .album(let albumID) = scope else { return }
        let new = PhotoOrder.moved(ids, moving: moving, move)
        guard new != ids else { return }
        ids = new
        Task { await library.setAlbumOrder(albumID, ordered: new) }
    }

    // MARK: List

    func reload() {
        reloadTask?.cancel()
        isLoading = true
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let new = await library.ids(scope: scope, search: search, sort: currentSort)
            guard !Task.isCancelled else { return }
            ids = new
            isLoading = false
            selection.formIntersection(Set(new))
            if let open = viewing, !new.contains(open), editing == nil { viewing = nil; stopSlideshow() }
        }
    }

    /// A search reloads shortly after the last key, not on every one.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    var title: String {
        switch scope {
        case .all: return String(localized: "All Photos")
        case .album(let id): return library.albums.first { $0.id == id }?.name ?? String(localized: "Album")
        }
    }

    // MARK: Selection

    /// A click: replaces the selection; with ⌘ toggles one; with ⇧ extends from the last click to this one.
    func click(_ id: Int64, command: Bool, shift: Bool) {
        if shift, let anchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            selection = Set(ids[min(a, b)...max(a, b)])
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(ids) }
    func clearSelection() { selection = [] }

    /// What an action applies to: the selection, or the one photo it was started on when that is not selected.
    func targets(for id: Int64?) -> [Int64] {
        guard let id else { return ids.filter { selection.contains($0) } }
        return selection.contains(id) ? ids.filter { selection.contains($0) } : [id]
    }

    // MARK: Actions

    func addToAlbum(_ albumID: Int64, photos targets: [Int64]) {
        Task {
            let added = await library.add(targets, toAlbum: albumID)
            let name = library.albums.first { $0.id == albumID }?.name ?? ""
            show(toast: added == 0 ? String(localized: "Already in “\(name)”") : String(localized: "Added \(added) to “\(name)”"))
        }
    }

    func newAlbum(named name: String, with targets: [Int64]) {
        Task {
            if let album = await library.createAlbum(named: name, with: targets) {
                if !targets.isEmpty { show(toast: String(localized: "Added \(targets.count) to “\(album.name)”")) }
            }
        }
    }

    /// In an album this takes photos out of the album; in All Photos it takes them out of the library. Files are never touched.
    func removeTargets(_ targets: [Int64]) {
        guard !targets.isEmpty else { return }
        Task {
            switch scope {
            case .all: await library.remove(targets)
            case .album(let id): await library.remove(targets, fromAlbum: id)
            }
        }
    }

    func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Viewer

    var viewingIndex: Int? { viewing.flatMap { ids.firstIndex(of: $0) } }

    func open(_ id: Int64) {
        viewing = id
        // A photo opens as a picture and nothing else; the controls come when the pointer moves and go again when it rests.
        chromeVisible = false
        lastActivity = .distantPast
    }

    /// Opens the editor on a photo (opening it in the viewer first).
    func edit(_ id: Int64) {
        Task {
            guard let photo = await library.photo(id), PhotoExporter.canEdit(photo.url) else { return }
            stopSlideshow()
            if viewing != id { open(id) }
            editing = id
        }
    }

    func closeEditor() { editing = nil }

    func closeViewer() {
        editing = nil
        viewing = nil
        stopSlideshow()
        chromeTimer?.invalidate(); chromeTimer = nil
        chromeVisible = true
    }

    /// Asks, once the controls have rested long enough, whether to hide them. One pending check at most, never a clock that
    /// runs for as long as the viewer is open.
    private func scheduleChromeHide() {
        guard chromeTimer == nil, viewing != nil else { return }
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 1.85, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.chromeTimer = nil
                self.hideChromeIfIdle()
                if self.chromeVisible, self.viewing != nil { self.scheduleChromeHide() }
            }
        }
    }

    func step(_ offset: Int, wrapping: Bool = false) {
        guard let index = viewingIndex, !ids.isEmpty else { return }
        var next = index + offset
        if wrapping { next = (next % ids.count + ids.count) % ids.count }
        guard ids.indices.contains(next) else { return }
        viewing = ids[next]
    }

    // MARK: Slideshow

    func startSlideshow() {
        if viewing == nil, let first = ids.first(where: { selection.contains($0) }) ?? ids.first { viewing = first }
        guard viewing != nil else { return }
        slideshowActive = true
        restartSlideshowTimer()
        poke()
    }

    func stopSlideshow() {
        slideshowActive = false
        slideshowTimer?.invalidate(); slideshowTimer = nil
        if viewing == nil { chromeTimer?.invalidate(); chromeTimer = nil; chromeVisible = true }
    }

    func toggleSlideshow() { slideshowActive ? stopSlideshow() : startSlideshow() }

    /// A manual step during a slideshow starts the countdown again, so the picture just chosen is not skipped at once.
    func restartSlideshowTimer() {
        slideshowTimer?.invalidate()
        guard slideshowActive else { return }
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: Self.slideshowInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(1, wrapping: true) }
        }
    }

    /// Something happened (the pointer moved, a key was pressed): show the controls and start their countdown again.
    func poke() {
        lastActivity = Date()
        if !chromeVisible { chromeVisible = true }
        scheduleChromeHide()
    }

    private func hideChromeIfIdle() {
        guard chromeVisible, viewing != nil, Date().timeIntervalSince(lastActivity) > 1.8 else { return }
        chromeVisible = false
        // The pointer goes too, but only while a slideshow plays and the photo window is the one in front.
        if slideshowActive, PhotoWindowController.shared.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}
