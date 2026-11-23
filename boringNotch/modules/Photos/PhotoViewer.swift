//
//  PhotoViewer.swift
//  boringNotch
//
//  One photo at a time, filling the window: arrows move through the list, pinch / + / − zoom, a drag pans a
//  zoomed photo, double-click goes between "fit" and actual size. An info panel, a slideshow and full screen. A GIF plays.
//

import AppKit
import SwiftUI

/// The few photos next to the open one, kept decoded so moving between them is instant.
@MainActor
final class PhotoImageCache {
    static let shared = PhotoImageCache()
    private let cache = NSCache<NSNumber, NSImage>()
    private init() { cache.countLimit = 6 }
    func image(_ id: Int64) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }
    func store(_ image: NSImage, for id: Int64) { cache.setObject(image, forKey: NSNumber(value: id)) }
    func clear() { cache.removeAllObjects() }
}

/// An animated GIF, which a plain SwiftUI image would show as one frame.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    /// Remembers which file the view shows, so a SwiftUI update that is not a new photo (the controls fading, a zoom, every
    /// scroll event) does not read and decode the whole file again, which also restarted the animation.
    final class Coordinator { var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        load(into: view, coordinator: context.coordinator)
    }

    private func load(into view: NSImageView, coordinator: Coordinator) {
        guard coordinator.url != url else { return }
        coordinator.url = url
        let target = url
        // Reading and decoding a large GIF takes a while: not on the main thread.
        Task.detached(priority: .userInitiated) {
            let image = NSImage(contentsOf: target)
            await MainActor.run {
                guard coordinator.url == target else { return }
                view.image = image
                view.animates = true
            }
        }
    }
}

struct PhotoViewer: View {
    @ObservedObject var model: PhotoBrowserModel
    @ObservedObject private var library = PhotoLibrary.shared

    @State private var photo: Photo?
    @State private var image: NSImage?
    @State private var isFullResolution = false
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var showInfo = false
    @State private var albumNames: [String] = []
    @State private var container: CGSize = .zero
    @State private var lastPoint: CGPoint?
    @FocusState private var focused: Bool

    private var isGIF: Bool { photo?.url.pathExtension.lowercased() == "gif" }
    private var canEdit: Bool { photo.map { !$0.isMissing && PhotoExporter.canEdit($0.url) } ?? false }

    var body: some View {
        ZStack {
            Color.black
            GeometryReader { geo in
                ZStack { content }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { container = geo.size }
                    .onChange(of: geo.size) { _, size in container = size }
            }
            .background(ChartInput(
                onScroll: { dx, dy, _ in handleScroll(dx: dx, dy: dy) },
                onMagnify: { magnification in zoom(to: scale * (1 + magnification)) }))

            VStack(spacing: 0) {
                topBar
                Spacer()
            }
            .opacity(model.chromeVisible ? 1 : 0)
            HStack {
                arrow("chevron.left", offset: -1, enabled: (model.viewingIndex ?? 0) > 0 || model.slideshowActive)
                Spacer()
                arrow("chevron.right", offset: 1, enabled: (model.viewingIndex ?? 0) < model.ids.count - 1 || model.slideshowActive)
            }
            .padding(.horizontal, 10)
            .opacity(model.chromeVisible ? 1 : 0)

            if showInfo, let photo { infoPanel(photo).transition(.move(edge: .trailing)) }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: showInfo)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onContinuousHover { phase in
            // Only a pointer that really moved counts; a view laid out again under a resting pointer must not call the controls back.
            guard case .active(let point) = phase else { return }
            defer { lastPoint = point }
            if let last = lastPoint, hypot(point.x - last.x, point.y - last.y) < 2 { return }
            model.poke()
        }
        .onKeyPress { press in
            model.poke()
            return handleKey(press)
        }
        .task(id: model.viewing) { await load() }
    }

    // MARK: Picture

    @ViewBuilder
    private var content: some View {
        if isGIF, let photo {
            AnimatedImageView(url: photo.url)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { drag in
                            guard scale > 1.01 else { return }
                            let start = dragStart ?? offset
                            dragStart = start
                            offset = CGSize(width: start.width + drag.translation.width, height: start.height + drag.translation.height)
                        }
                        .onEnded { _ in dragStart = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? scale
                        pinchStart = start
                        zoom(to: start * value.magnification)
                    }
                    .onEnded { _ in pinchStart = nil })
                .onTapGesture(count: 2) { toggleActualSize() }
        } else if photo?.isMissing == true {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(Color.coveWarning)
                Text("File missing").foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    private func load() async {
        guard let id = model.viewing else { return }
        scale = 1; offset = .zero; isFullResolution = false; pinchStart = nil
        photo = await library.photo(id)
        if let cached = PhotoImageCache.shared.image(id) { image = cached } else { image = library.thumbnails.cached(id) }
        guard let photo, !photo.isMissing else { image = nil; return }
        refreshAlbumNames(for: id)
        if !isGIF {
            let long = max(container.width, container.height, 1200) * (NSScreen.main?.backingScaleFactor ?? 2)
            let decoded = await library.image(at: photo.url, maxPixel: Int(min(long, 6000)))
            guard !Task.isCancelled, model.viewing == id else { return }
            if let decoded { image = decoded; PhotoImageCache.shared.store(decoded, for: id) }
        }
        await prefetchNeighbours()
    }

    private func prefetchNeighbours() async {
        guard let index = model.viewingIndex else { return }
        for neighbour in [index + 1, index - 1] where model.ids.indices.contains(neighbour) {
            let id = model.ids[neighbour]
            guard PhotoImageCache.shared.image(id) == nil, let next = await library.photo(id), !next.isMissing, next.url.pathExtension.lowercased() != "gif" else { continue }
            if Task.isCancelled { return }
            if let decoded = await library.image(at: next.url, maxPixel: 3200) { PhotoImageCache.shared.store(decoded, for: id) }
        }
    }

    private func refreshAlbumNames(for id: Int64) {
        Task {
            let ids = await library.albumIDs(containing: id)
            albumNames = library.albums.filter { ids.contains($0.id) }.map(\.name)
        }
    }

    // MARK: Zoom

    /// Points per pixel when the picture is fitted to the window.
    private var fitFactor: CGFloat {
        guard let photo, photo.width > 0, photo.height > 0, container.width > 0 else { return 1 }
        return min(container.width / CGFloat(photo.width), container.height / CGFloat(photo.height))
    }

    private func zoom(to proposed: CGFloat) {
        scale = min(max(proposed, 1), 10)
        if scale <= 1.01 { scale = 1; offset = .zero }
        if scale > 1.6, !isFullResolution, let photo, !isGIF {
            isFullResolution = true
            let id = photo.id
            Task {
                if let full = await library.image(at: photo.url, maxPixel: min(max(photo.width, photo.height), 9000)), model.viewing == id { image = full }
            }
        }
    }

    private func toggleActualSize() {
        if scale > 1.01 { zoom(to: 1) } else { zoom(to: max(1 / max(fitFactor, 0.001), 2)) }
    }

    /// Two-finger scrolling pans a zoomed photo and does nothing at fit size: it never changes the photo (that is for the arrows, the
    /// keys and the buttons).
    private func handleScroll(dx: CGFloat, dy: CGFloat) {
        guard model.editing == nil, scale > 1.01 else { return }
        offset = CGSize(width: offset.width + dx, height: offset.height + dy)
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.editing == nil else { return .ignored }   // the editor is over the picture; its keys are its own
        switch press.key {
        case .leftArrow: model.step(-1); model.restartSlideshowTimer(); return .handled
        case .rightArrow: model.step(1); model.restartSlideshowTimer(); return .handled
        case .escape:
            if scale > 1.01 { zoom(to: 1) } else { model.closeViewer() }
            return .handled
        case .space: model.toggleSlideshow(); return .handled
        default: break
        }
        switch press.characters {
        case "i": showInfo.toggle(); return .handled
        case "e": if canEdit, let id = model.viewing { model.edit(id) }; return .handled
        case "f": PhotoWindowController.shared.toggleFullScreen(); return .handled
        case "+", "=": zoom(to: scale * 1.25); return .handled
        case "-": zoom(to: scale / 1.25); return .handled
        case "0": zoom(to: 1); return .handled
        case "1": zoom(to: max(1 / max(fitFactor, 0.001), 1)); return .handled
        default: return .ignored
        }
    }

    // MARK: Controls

    /// Floating over the picture, no bar, so the picture keeps the whole window: the few things worth having on the right,
    /// level with the window buttons (their middle is 23 pt from the top, as 9 + 14 is). Everything else (zoom, slideshow, next and previous) is a gesture or a key.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            floating {
                HStack(spacing: 0) {
                    Menu {
                        Button { model.newAlbum(named: "", with: viewingTargets) } label: { Label("New album…", systemImage: "plus") }
                        if !library.albums.isEmpty { Divider() }
                        ForEach(library.albums) { album in
                            Button(album.name) { model.addToAlbum(album.id, photos: viewingTargets); if let id = model.viewing { refreshAlbumNames(for: id) } }
                        }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                            .frame(width: ToolbarMetrics.height, height: ToolbarMetrics.height).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(Text("Add to album"))
                    iconButton("info.circle", help: "Info", active: showInfo) { showInfo.toggle() }
                    iconButton("arrow.up.left.and.arrow.down.right", help: "Full screen") { PhotoWindowController.shared.toggleFullScreen() }
                }
            }
            ToolbarPillButton(title: "Edit", symbol: "slider.horizontal.3", prominent: true) { if let id = model.viewing { model.edit(id) } }
                .opacity(canEdit ? 1 : 0.35)
                .disabled(!canEdit)
                .help(Text(isGIF ? "Animated GIFs cannot be edited" : "Edit this photo (E)"))
        }
        .frame(height: ToolbarMetrics.height)
        .padding(.horizontal, 16).padding(.top, 9)
    }

    private func floating<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
    }

    private var viewingTargets: [Int64] { model.viewing.map { [$0] } ?? [] }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.effectiveAccent : .white)
                .frame(width: ToolbarMetrics.height, height: ToolbarMetrics.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(Text(help))
    }

    private func arrow(_ symbol: String, offset: Int, enabled: Bool) -> some View {
        Button { model.step(offset, wrapping: model.slideshowActive); model.restartSlideshowTimer() } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 56).background(Circle().fill(Color.black.opacity(0.45)).frame(width: 36, height: 36))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }

    // MARK: Info

    private func infoPanel(_ photo: Photo) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("Info").font(.headline)
                row("Name", photo.name)
                row("Taken", photo.taken.formatted(date: .long, time: .standard))
                row("Dimensions", "\(photo.width) × \(photo.height)")
                row("File size", ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file))
                row("Albums", albumNames.isEmpty ? "—" : albumNames.joined(separator: ", "))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").font(.caption).foregroundStyle(.secondary)
                    Text(photo.url.deletingLastPathComponent().path).font(.system(size: 11)).textSelection(.enabled).lineLimit(4)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .controlSize(.small)
                Spacer()
            }
            .padding(14)
            .frame(width: 260)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
        }
        .padding(.top, 56)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled)
        }
    }
}
