//
//  PhotoViewer.swift
//  boringNotch
//
//  One photo at a time, filling the window: arrows and swipes move through the list, pinch / + / − zoom, a drag pans a
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
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.image = NSImage(contentsOf: url)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(contentsOf: url)
        view.animates = true
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
    @State private var swipeAccumulator: CGFloat = 0
    @State private var lastSwipe = Date.distantPast
    @FocusState private var focused: Bool

    private var isGIF: Bool { photo?.url.pathExtension.lowercased() == "gif" }

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
        .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: showInfo)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onContinuousHover { _ in model.poke() }
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
                        .onEnded { drag in
                            defer { dragStart = nil }
                            // At fit size a drag is a swipe to the next or previous photo.
                            if scale <= 1.01, abs(drag.translation.width) > 80, abs(drag.translation.width) > abs(drag.translation.height) {
                                model.step(drag.translation.width < 0 ? 1 : -1)
                            }
                        })
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

    /// Plain scrolling pans a zoomed photo; at fit size a swipe (or the wheel) moves to the next or previous one.
    private func handleScroll(dx: CGFloat, dy: CGFloat) {
        if scale > 1.01 {
            offset = CGSize(width: offset.width + dx, height: offset.height + dy)
            return
        }
        swipeAccumulator += abs(dx) > abs(dy) ? -dx : -dy
        if abs(swipeAccumulator) > 60, Date().timeIntervalSince(lastSwipe) > 0.3 {
            model.step(swipeAccumulator > 0 ? 1 : -1)
            model.restartSlideshowTimer()
            swipeAccumulator = 0
            lastSwipe = Date()
        } else if Date().timeIntervalSince(lastSwipe) > 0.6 {
            swipeAccumulator = 0
        }
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
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
        case "f": PhotoWindowController.shared.toggleFullScreen(); return .handled
        case "+", "=": zoom(to: scale * 1.25); return .handled
        case "-": zoom(to: scale / 1.25); return .handled
        case "0": zoom(to: 1); return .handled
        case "1": zoom(to: max(1 / max(fitFactor, 0.001), 1)); return .handled
        default: return .ignored
        }
    }

    // MARK: Controls

    private var topBar: some View {
        HStack(spacing: 6) {
            iconButton("xmark", help: "Close") { model.closeViewer() }
            VStack(alignment: .leading, spacing: 1) {
                Text(photo?.name ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let photo { Text(photo.taken.formatted(date: .long, time: .shortened)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
            }
            Spacer()
            if let index = model.viewingIndex {
                Text("\(index + 1) / \(model.ids.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            iconButton(model.slideshowActive ? "pause.fill" : "play.fill", help: model.slideshowActive ? "Stop slideshow" : "Start slideshow") { model.toggleSlideshow() }
            iconButton("plus.magnifyingglass", help: "Zoom in") { zoom(to: scale * 1.5) }
            iconButton("minus.magnifyingglass", help: "Zoom out") { zoom(to: scale / 1.5) }
            Menu {
                Button { model.newAlbum(named: "", with: viewingTargets) } label: { Label("New album…", systemImage: "plus") }
                if !library.albums.isEmpty { Divider() }
                ForEach(library.albums) { album in
                    Button(album.name) { model.addToAlbum(album.id, photos: viewingTargets); if let id = model.viewing { refreshAlbumNames(for: id) } }
                }
            } label: { Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(Text("Add to album"))
            iconButton("info.circle", help: "Info", active: showInfo) { showInfo.toggle() }
            iconButton("arrow.up.left.and.arrow.down.right", help: "Full screen") { PhotoWindowController.shared.toggleFullScreen() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 26)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var viewingTargets: [Int64] { model.viewing.map { [$0] } ?? [] }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Color.effectiveAccent : .white)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(Text(help))
    }

    private func arrow(_ symbol: String, offset: Int, enabled: Bool) -> some View {
        Button { model.step(offset, wrapping: model.slideshowActive); model.restartSlideshowTimer() } label: {
            Image(systemName: symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .frame(width: 40, height: 56).background(Circle().fill(Color.black.opacity(0.35)).frame(width: 44, height: 44))
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
