//
//  PhotoWindow.swift
//  boringNotch
//
//  The photo library in a window of its own: sidebar, thumbnail wall, toolbar and viewer. Cove normally lives in the menu
//  bar without a Dock icon; while a real window is open it needs one, and gives it up when the last one closes.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps the app in "regular" mode (Dock icon, menu bar) while any of its real windows is open.
@MainActor
enum AppActivation {
    private static var open: Set<String> = []

    static func windowOpened(_ name: String) {
        open.insert(name)
        NSApp.setActivationPolicy(.regular)
    }

    static func windowClosed(_ name: String) {
        open.remove(name)
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
final class PhotoWindowController: NSObject, NSWindowDelegate {
    static let shared = PhotoWindowController()
    static let requestNotification = Notification.Name("CovePhotoWindowRequest")

    private(set) var window: NSWindow?
    /// Where the window should go when it opens (set by the notch tab); consumed by the window's view.
    var pending: (scope: PhotoScope, photo: Int64?)?

    func show(scope: PhotoScope = .all, photo: Int64? = nil) {
        pending = (scope, photo)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "Photos")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 520)
            window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
            window.identifier = NSUserInterfaceItemIdentifier("CovePhotoWindow")
            window.titlebarAppearsTransparent = false
            let hosting = NSHostingController(rootView: PhotoWindowView())
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.delegate = self
            if !window.setFrameUsingName("CovePhotoWindow") { window.center() }
            window.setFrameAutosaveName("CovePhotoWindow")
            self.window = window
        }
        AppActivation.windowOpened("photos")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.requestNotification, object: nil)
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func consumePending() -> (scope: PhotoScope, photo: Int64?)? {
        defer { pending = nil }
        return pending
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowClosed("photos")
        // Let go of the window (and with it the view, its model and the slideshow timer) once this call has returned.
        DispatchQueue.main.async { [weak self] in self?.window = nil }
    }
}

enum PhotoActions {
    /// The open panel for photo files and folders. The notch is kept open while it is up.
    @MainActor
    static func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add to Photos")
        panel.prompt = String(localized: "Add")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = PhotoFormats.contentTypes
        SharingStateManager.shared.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            SharingStateManager.shared.endInteraction()
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await PhotoLibrary.shared.importURLs(urls) }
        }
    }
}

struct PhotoWindowView: View {
    @StateObject private var model = PhotoBrowserModel()
    @ObservedObject private var library = PhotoLibrary.shared
    @State private var confirmRemove = false

    var body: some View {
        NavigationSplitView {
            PhotoSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            ZStack {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    ZStack(alignment: .bottom) {
                        content
                        VStack(spacing: 6) {
                            if let progress = library.importProgress { ImportBar(progress: progress) }
                            if let summary = library.lastSummary { ImportReportBar(report: summary.report) { library.lastSummary = nil }.frame(maxWidth: 560) }
                            if let toast = model.toast { ToastBar(text: toast) }
                        }
                        .padding(10)
                    }
                }
                if model.viewing != nil { PhotoViewer(model: model).transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.15), value: model.viewing)
        }
        .frame(minWidth: 820, minHeight: 520)
        .tint(Color.effectiveAccent)
        .onAppear { applyPending() }
        .onReceive(NotificationCenter.default.publisher(for: PhotoWindowController.requestNotification)) { _ in applyPending() }
        // Select all and delete from the keyboard, when the viewer is not open.
        .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
            guard press.modifiers.contains(.command), model.viewing == nil else { return .ignored }
            model.selectAll(); return .handled
        }
        .onDeleteCommand { if model.viewing == nil, !model.selection.isEmpty { handleRemove() } }
        .onExitCommand { if model.viewing == nil { model.clearSelection() } }
        .confirmationDialog(String(localized: "Remove \(model.selection.count) photos from the library?"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) { model.removeTargets(model.targets(for: nil)); model.clearSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files stay where they are.")
        }
    }

    private func applyPending() {
        guard let request = PhotoWindowController.shared.consumePending() else { return }
        model.scope = request.scope
        if let id = request.photo { model.open(id) }
    }

    /// In an album the photos only leave the album; from All Photos a few are removed at once, many ask first.
    private func handleRemove() {
        if case .all = model.scope, model.selection.count > 1 { confirmRemove = true }
        else { model.removeTargets(model.targets(for: nil)); model.clearSelection() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(model.selection.isEmpty ? String(localized: "\(model.ids.count) photos") : String(localized: "\(model.selection.count) selected"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !model.ids.isEmpty {
                Button(model.selection.count == model.ids.count ? "Deselect All" : "Select All") {
                    if model.selection.count == model.ids.count { model.clearSelection() } else { model.selectAll() }
                }
                .buttonStyle(.plain).font(.system(size: 12))
            }
            if !model.selection.isEmpty { selectionActions }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.search).textFieldStyle(.plain).frame(width: 130)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.15)))
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.thumbSize, in: 80...320).frame(width: 90).controlSize(.mini)
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Menu {
                ForEach(PhotoSort.allCases) { sort in
                    Button { model.sort = sort } label: { if model.sort == sort { Label(Self.sortName(sort), systemImage: "checkmark") } else { Text(Self.sortName(sort)) } }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(Text("Sort"))
            Button { model.startSlideshow() } label: { Image(systemName: "play.rectangle") }
                .buttonStyle(.plain).help(Text("Slideshow")).disabled(model.ids.isEmpty)
            Button { PhotoActions.chooseFilesToAdd() } label: { Label("Add", systemImage: "plus") }
                .help(Text("Add photos or folders"))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var selectionActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button { model.newAlbum(named: "", with: model.targets(for: nil)) } label: { Label("New album…", systemImage: "plus") }
                if !library.albums.isEmpty { Divider() }
                ForEach(library.albums) { album in
                    if case .album(let current) = model.scope, current == album.id { EmptyView() } else {
                        Button(album.name) { model.addToAlbum(album.id, photos: model.targets(for: nil)) }
                    }
                }
            } label: { Label("Add to album", systemImage: "rectangle.stack.badge.plus") }
                .menuStyle(.borderlessButton).fixedSize()
            Button { handleRemove() } label: {
                if case .album = model.scope { Label("Remove from album", systemImage: "minus.circle") } else { Label("Remove", systemImage: "trash") }
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
    }

    static func sortName(_ sort: PhotoSort) -> LocalizedStringKey {
        switch sort {
        case .takenNewest: return "Date taken, newest first"
        case .takenOldest: return "Date taken, oldest first"
        case .name: return "Name"
        case .addedNewest: return "Recently added"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if library.photoCount == 0 && library.importProgress == nil {
            EmptyLibraryView()
        } else if model.ids.isEmpty && !model.isLoading {
            VStack(spacing: 8) {
                Image(systemName: model.search.isEmpty ? "rectangle.stack" : "magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhotoGridView(model: model)
        }
    }

    private var emptyText: LocalizedStringKey {
        if !model.search.isEmpty { return "No photos match your search." }
        if case .album = model.scope { return "This album is empty.\nDrag photos here from All Photos, or choose Add to album." }
        return "No photos."
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Your photo library is empty").font(.title3.weight(.semibold))
            Text("Add photos or folders with the button. Your files stay where they are: Cove only remembers where they are.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { PhotoActions.chooseFilesToAdd() } label: { Label("Add Photos…", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("JPEG · PNG · HEIC · TIFF · GIF · WebP · BMP").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportBar: View {
    let progress: (done: Int, total: Int)
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).progressViewStyle(.linear)
            Text("Adding \(progress.done) / \(progress.total)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: 420)
    }
}

private struct ToastBar: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
    }
}
