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
        .clipped()
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Color.effectiveAccent, lineWidth: 3)
                Rectangle().fill(Color.effectiveAccent.opacity(0.18))
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

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let columns = max(Int((geo.size.width + spacing) / (model.thumbSize + spacing)), 1)
            let cell = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(model.ids, id: \.self) { id in
                        PhotoCell(id: id, size: cell, isSelected: model.selection.contains(id))
                            .onTapGesture(count: 2) { model.open(id) }
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                model.click(id, command: flags.contains(.command), shift: flags.contains(.shift))
                            }
                            .onDrag { dragProvider(for: id) }
                            .contextMenu { PhotoMenu(model: model, id: id) }
                    }
                }
            }
            // A click on empty space clears the selection.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.clearSelection() })
        }
    }

    /// What is dragged to an album in the sidebar: the ids of the selection, or of this photo alone.
    private func dragProvider(for id: Int64) -> NSItemProvider {
        let ids = model.targets(for: id)
        return NSItemProvider(object: ("cove-photos:" + ids.map(String.init).joined(separator: ",")) as NSString)
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
