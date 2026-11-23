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
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "Photos")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 520)
            window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
            window.identifier = NSUserInterfaceItemIdentifier("CovePhotoWindow")
            // The title bar is see-through so an open photo can run right up to the top edge, as a video does.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
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
        let chooser = AddToAlbumChooser(albums: PhotoLibrary.shared.albums)
        panel.accessoryView = chooser.view
        panel.isAccessoryViewDisclosed = true
        SharingStateManager.shared.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.presentAboveNotch()
        panel.begin { response in
            SharingStateManager.shared.endInteraction()
            guard response == .OK else { return }
            let urls = panel.urls
            let destination = chooser.destination
            Task { @MainActor in
                var summary = await PhotoLibrary.shared.importURLs(urls)
                if let note = await PhotoLibrary.shared.file(summary, into: destination) {
                    summary.albumNote = note
                    PhotoLibrary.shared.lastSummary = summary
                }
            }
        }
    }
}

struct PhotoWindowView: View {
    /// Set by the screenshot harness only.
    nonisolated(unsafe) static var debugSelectAll = false
    @StateObject private var model = PhotoBrowserModel()
    @ObservedObject private var library = PhotoLibrary.shared
    @State private var confirmRemove = false
    /// The album list is out of the way until asked for (the button in the title bar); the choice is remembered.
    @AppStorage("photos.sidebarVisible") private var sidebarVisible = false

    var body: some View {
        // The sidebar is laid out by hand rather than with a system split view: that one puts its own button in the title bar,
        // and it could not be taken off an open photo.
        HStack(spacing: 0) {
            if sidebarVisible {
                PhotoSidebar(model: model)
                    .frame(width: 220)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }
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
        }
        // An open photo covers the whole window, sidebar and toolbar included: it is a picture, not a page with a picture on it.
        .overlay {
            if model.viewing != nil { PhotoViewer(model: model).ignoresSafeArea().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.15), value: model.viewing)
        .frame(minWidth: 820, minHeight: 520)
        .tint(Color.effectiveAccent)
        .onAppear { applyPending(); if PhotoWindowView.debugSelectAll { Task { try? await Task.sleep(nanoseconds: 800_000_000); model.selectAll() } } }
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

    /// The bar that is always there, and under it, only while photos are selected, the bar for what can be done with them. They
    /// are two rows so neither can outgrow the window (one row with everything on it did, and broke the layout).
    private var toolbar: some View {
        VStack(spacing: 0) {
            mainBar
            if !model.selection.isEmpty {
                Divider()
                selectionBar
            }
        }
    }

    private var mainBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolbarIconButton(symbol: "sidebar.left", help: sidebarVisible ? "Hide albums" : "Show albums") { withAnimation(.easeInOut(duration: 0.15)) { sidebarVisible.toggle() } }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(String(localized: "\(model.ids.count) photos")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            ToolbarSearchField(text: $model.search, width: 150)
            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.thumbSize, in: 80...320).frame(width: 80).controlSize(.mini)
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: ToolbarMetrics.height)
            Menu {
                ForEach(PhotoSort.choices(inAlbum: model.isAlbum)) { sort in
                    Button { model.currentSort = sort } label: { if model.currentSort == sort { Label(Self.sortName(sort), systemImage: "checkmark") } else { Text(Self.sortName(sort)) } }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 13)).frame(width: ToolbarMetrics.height, height: ToolbarMetrics.height).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(Text("Sort"))
            ToolbarIconButton(symbol: "play.rectangle", help: "Slideshow") { model.startSlideshow() }
                .disabled(model.ids.isEmpty)
            ToolbarPillButton(title: "Add", symbol: "plus", prominent: true) { PhotoActions.chooseFilesToAdd() }
                .help(Text("Add photos or folders"))
                .fixedSize()
        }
        .frame(height: ToolbarMetrics.height + 6)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var selectionBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolbarPillButton(title: model.selection.count == model.ids.count ? "Deselect All" : "Select All") {
                if model.selection.count == model.ids.count { model.clearSelection() } else { model.selectAll() }
            }
            .fixedSize()
            Text(String(localized: "\(model.selection.count) selected")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            selectionActions
        }
        .frame(height: ToolbarMetrics.height + 4)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
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
            } label: { ToolbarPillLabel(title: "Add to album", symbol: "rectangle.stack.badge.plus", showsChevron: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            if model.canArrange {
                Menu {
                    Button { model.moveInAlbum(model.selection, .start) } label: { Label("Move to the start", systemImage: "arrow.up.to.line") }
                    Button { model.moveInAlbum(model.selection, .earlier) } label: { Label("Move earlier", systemImage: "arrow.up") }
                    Button { model.moveInAlbum(model.selection, .later) } label: { Label("Move later", systemImage: "arrow.down") }
                    Button { model.moveInAlbum(model.selection, .end) } label: { Label("Move to the end", systemImage: "arrow.down.to.line") }
                } label: { ToolbarPillLabel(title: "Arrange", symbol: "arrow.up.arrow.down", showsChevron: true) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if case .album = model.scope {
                ToolbarPillButton(title: "Remove from album", symbol: "minus.circle") { handleRemove() }.fixedSize()
            } else {
                ToolbarPillButton(title: "Remove from Library", symbol: "trash") { handleRemove() }.fixedSize()
            }
        }
    }

    static func sortName(_ sort: PhotoSort) -> LocalizedStringKey {
        switch sort {
        case .manual: return "Custom order"
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


/// The strip under the open panel's file list: where the photos go as they are added.
@MainActor
final class AddToAlbumChooser: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 34))
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let albums: [Album]
    private let newTag = -1

    init(albums: [Album]) {
        self.albums = albums
        super.init()
        let label = NSTextField(labelWithString: String(localized: "Also put in album:"))
        label.font = .systemFont(ofSize: 12)
        popup.addItem(withTitle: String(localized: "None (library only)"))
        popup.menu?.addItem(.separator())
        for (index, album) in albums.enumerated() {
            let item = NSMenuItem(title: album.name, action: nil, keyEquivalent: "")
            item.tag = index + 1
            popup.menu?.addItem(item)
        }
        if !albums.isEmpty { popup.menu?.addItem(.separator()) }
        let new = NSMenuItem(title: String(localized: "New album…"), action: nil, keyEquivalent: ""); new.tag = newTag
        popup.menu?.addItem(new)
        popup.target = self
        popup.action = #selector(changed)
        nameField.placeholderString = String(localized: "Album name")
        nameField.isHidden = true
        for sub in [label, popup, nameField] { sub.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(sub) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 190),
            nameField.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    @objc private func changed() {
        nameField.isHidden = popup.selectedItem?.tag != newTag
        if !nameField.isHidden { nameField.window?.makeFirstResponder(nameField) }
    }

    var destination: PhotoLibrary.Destination {
        guard let tag = popup.selectedItem?.tag else { return .none }
        if tag == newTag { return .new(nameField.stringValue) }
        if tag >= 1, tag <= albums.count { return .existing(albums[tag - 1].id) }
        return .none
    }
}
