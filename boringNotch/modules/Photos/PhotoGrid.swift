//
//  PhotoGrid.swift
//  boringNotch
//
//  The wall of thumbnails: square cells, selection, drag to an album, and the right-click menu.
//

import AppKit
import SwiftUI

struct PhotoCell: View {
    let id: Int64
    let size: CGFloat
    var isSelected = false
    @ObservedObject private var library = PhotoLibrary.shared
    @State private var photo: Photo?
    @State private var image: NSImage?

    /// Rounded like the thumbnails in the notch, a little less so as they get small.
    static func corner(for size: CGFloat) -> CGFloat { min(10, max(4, size * 0.07)) }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if photo?.isMissing == true {
                VStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.coveWarning)
                    if size > 100 { Text("File missing").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner(for: size), style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.corner(for: size), style: .continuous).fill(Color.effectiveAccent.opacity(0.18))
                RoundedRectangle(cornerRadius: Self.corner(for: size), style: .continuous).strokeBorder(Color.effectiveAccent, lineWidth: 3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.effectiveAccent).padding(4)
            }
        }
        .contentShape(Rectangle())
        // Reloads when the id changes (a cell is reused as the list scrolls) or the library changed (a file may have gone missing).
        .task(id: "\(id)-\(library.revision)") {
            guard let loaded = await library.photo(id) else { return }
            photo = loaded
            if let cached = library.thumbnails.cached(id) { image = cached; return }
            let made = await library.thumbnail(for: loaded)
            if !Task.isCancelled { image = made }
        }
    }
}

struct PhotoGridView: View {
    @ObservedObject var model: PhotoBrowserModel
    @ObservedObject private var library = PhotoLibrary.shared
    @State private var dropTarget: Int64?

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8, inset: CGFloat = 14
            let usable = max(geo.size.width - inset * 2, 1)
            let columns = max(Int((usable + spacing) / (model.thumbSize + spacing)), 1)
            let cell = (usable - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(model.ids, id: \.self) { id in
                        PhotoCell(id: id, size: cell, isSelected: model.selection.contains(id))
                            .onTapGesture(count: 2) { model.open(id) }
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                model.click(id, command: flags.contains(.command), shift: flags.contains(.shift))
                            }
                            .draggable(dragString(for: id))
                            // In an album with its own order, a photo dropped on another goes in front of it.
                            .overlay(alignment: .leading) {
                                if dropTarget == id { Capsule().fill(Color.effectiveAccent).frame(width: 3).offset(x: -spacing / 2 - 1.5) }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, before: id)
                            } isTargeted: { targeted in
                                if targeted { dropTarget = id } else if dropTarget == id { dropTarget = nil }
                            }
                            .contextMenu { PhotoMenu(model: model, id: id) }
                    }
                }
                .padding(.horizontal, inset).padding(.vertical, 12)
            }
            // A click on empty space clears the selection.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.clearSelection() })
        }
    }

    /// A photo dropped on another goes in front of it, in an album that keeps its own order.
    private func drop(_ items: [String], before target: Int64) -> Bool {
        defer { dropTarget = nil }
        guard model.canArrange, let text = items.first(where: { $0.hasPrefix(Self.dragPrefix) }) else { return false }
        let ids = Set(text.dropFirst(Self.dragPrefix.count).split(separator: ",").compactMap { Int64($0) })
        guard !ids.isEmpty else { return false }
        model.moveInAlbum(ids, .before(target))
        return true
    }

    static let dragPrefix = "cove-photos:"

    /// What is dragged (to an album in the sidebar, or to another photo): the ids of the selection, or of this photo alone.
    private func dragString(for id: Int64) -> String {
        Self.dragPrefix + model.targets(for: id).map(String.init).joined(separator: ",")
    }
}

/// The right-click menu of a photo (or of the whole selection when it is part of it).
struct PhotoMenu: View {
    @ObservedObject var model: PhotoBrowserModel
    let id: Int64
    @ObservedObject private var library = PhotoLibrary.shared

    var body: some View {
        let targets = model.targets(for: id)
        Button { model.open(id) } label: { Label("Open", systemImage: "photo") }
        if targets.count == 1 { Button { model.edit(id) } label: { Label("Edit…", systemImage: "slider.horizontal.3") } }
        Divider()
        Menu {
            Button { model.newAlbum(named: "", with: targets) } label: { Label("New album…", systemImage: "plus") }
            if !library.albums.isEmpty { Divider() }
            ForEach(library.albums) { album in
                if case .album(let current) = model.scope, current == album.id { EmptyView() } else {
                    Button(album.name) { model.addToAlbum(album.id, photos: targets) }
                }
            }
        } label: { Label("Add to album", systemImage: "rectangle.stack.badge.plus") }
        if model.canArrange {
            Menu {
                Button { model.moveInAlbum(Set(targets), .start) } label: { Label("Move to the start", systemImage: "arrow.up.to.line") }
                Button { model.moveInAlbum(Set(targets), .earlier) } label: { Label("Move earlier", systemImage: "arrow.up") }
                Button { model.moveInAlbum(Set(targets), .later) } label: { Label("Move later", systemImage: "arrow.down") }
                Button { model.moveInAlbum(Set(targets), .end) } label: { Label("Move to the end", systemImage: "arrow.down.to.line") }
            } label: { Label("Arrange", systemImage: "arrow.up.arrow.down") }
        }
        if case .album = model.scope {
            Button { model.removeTargets(targets) } label: { Label("Remove from album", systemImage: "minus.circle") }
        }
        Divider()
        Button { reveal(targets) } label: { Label("Show in Finder", systemImage: "folder") }
        if case .all = model.scope {
            Button(role: .destructive) { model.removeTargets(targets) } label: { Label("Remove from library", systemImage: "trash") }
        }
    }

    private func reveal(_ targets: [Int64]) {
        Task {
            let photos = await library.photos(targets)
            NSWorkspace.shared.activateFileViewerSelecting(photos.map(\.url))
        }
    }
}
