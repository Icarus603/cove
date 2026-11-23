//
//  PhotoSidebar.swift
//  boringNotch
//
//  The left column of the photo window: All Photos, then the albums. Albums are renamed in place, deleted from the
//  context menu, and accept photos dragged onto them.
//

import AppKit
import SwiftUI

struct PhotoSidebar: View {
    @ObservedObject var model: PhotoBrowserModel
    @ObservedObject private var library = PhotoLibrary.shared
    @State private var renaming: Int64?
    @State private var renameText = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var deleting: Album?
    @State private var dropTarget: Int64?


    var body: some View {
        List {
            Section {
                AccentSidebarRow(selected: model.scope == .all, action: { model.scope = .all }) {
                    SidebarRowLabel(title: String(localized: "All Photos"), symbol: "photo.on.rectangle", count: library.photoCount, selected: model.scope == .all)
                }
            }
            Section("Albums") {
                ForEach(library.albums) { album in
                    albumRow(album)
                }
                if creating {
                    HStack {
                        Image(systemName: "rectangle.stack").foregroundStyle(Color.effectiveAccent).frame(width: 18)
                        TextField("Album name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitNew() }
                            .onExitCommand { creating = false }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Color.effectiveAccent)
        .safeAreaInset(edge: .bottom) {
            Button { newName = ""; creating = true } label: { Label("New Album", systemImage: "plus") }
                .buttonStyle(.plain)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(deleting.map { String(localized: "Delete the album “\($0.name)”?") } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                if let album = deleting {
                    if model.scope == .album(album.id) { model.scope = .all }
                    Task { await library.deleteAlbum(album.id) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The photos stay in your library and on your disk.")
        }
    }

    @ViewBuilder
    private func albumRow(_ album: Album) -> some View {
        let isTarget = dropTarget == album.id
        let selected = model.scope == .album(album.id)
        Group {
            if renaming == album.id {
                HStack {
                    Image(systemName: "rectangle.stack").foregroundStyle(Color.effectiveAccent).frame(width: 18)
                    TextField("Album name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(album) }
                        .onExitCommand { renaming = nil }
                }
            } else {
                AccentSidebarRow(selected: selected, highlighted: isTarget, action: { model.scope = .album(album.id) }) {
                    SidebarRowLabel(title: album.name, symbol: "rectangle.stack", count: album.count, selected: selected)
                }
            }
        }
        .onDrop(of: [.plainText], isTargeted: dropBinding(for: album.id)) { providers in drop(providers, on: album) }
        .contextMenu {
            Button("Rename") { renameText = album.name; renaming = album.id }
            Button("Delete…", role: .destructive) { deleting = album }
        }
    }

    private func dropBinding(for id: Int64) -> Binding<Bool> {
        Binding(
            get: { dropTarget == id },
            set: { targeted in
                if targeted { dropTarget = id } else if dropTarget == id { dropTarget = nil }
            })
    }

    private func commitRename(_ album: Album) {
        let name = renameText
        renaming = nil
        Task { await library.renameAlbum(album.id, to: name) }
    }

    private func commitNew() {
        let name = newName
        creating = false
        Task {
            if let album = await library.createAlbum(named: name) { model.scope = .album(album.id) }
        }
    }

    /// Photos dragged from the grid (they carry their ids as text).
    private func drop(_ providers: [NSItemProvider], on album: Album) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let text = item as? String, text.hasPrefix("cove-photos:") else { return }
            let ids = text.dropFirst("cove-photos:".count).split(separator: ",").compactMap { Int64($0) }
            Task { @MainActor in model.addToAlbum(album.id, photos: ids) }
        }
        return true
    }
}
