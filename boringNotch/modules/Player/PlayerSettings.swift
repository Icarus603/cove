//
//  PlayerSettings.swift
//  boringNotch
//
//  Settings → Player: how playback behaves, and the whole library in a normal window, where text can be typed and many
//  items selected at once (the notch cannot take the keyboard).
//

import AppKit
import SwiftUI

struct PlayerSettings: View {
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var engine = PlayerEngine.shared
    @AppStorage(PlayerSettingsKey.resume) private var resume = true
    @AppStorage(PlayerSettingsKey.miniBar) private var miniBar = true
    @AppStorage(PlayerSettingsKey.videoPlacement) private var placement = "notch"
    @AppStorage(PlayerSettingsKey.floatOnTop) private var floatOnTop = true

    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var confirmClear = false
    @State private var newPlaylist = ""

    private var shown: [MediaItem] { library.items(matching: .all, search: search, sort: .title) }

    var body: some View {
        Form {
            Section {
                Toggle("Resume where I left off", isOn: $resume)
                Toggle("Show a mini player in the closed notch", isOn: $miniBar)
                Picker("Videos open in", selection: $placement) {
                    Text("The notch").tag("notch")
                    Text("A separate window").tag("window")
                }
                Toggle("Keep the video window above other windows", isOn: $floatOnTop)
                    .onChange(of: floatOnTop) { _, _ in FloatingPlayerController.shared.panel.map { $0.level = floatOnTop ? .floating : .normal } }
            } header: {
                Text("Playback")
            } footer: {
                Text("The system plays mp3, m4a, aac, flac, wav, aiff, caf, mp4, m4v and mov. Other formats such as mkv, webm and avi cannot be played and are named when you add them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Items") { Text("\(library.items.count)").monospacedDigit() }
                LabeledContent("Total length") { Text(PlayerFormat.clock(library.totalDuration)).monospacedDigit() }
                HStack {
                    Button("Add files or folders…") { PlayerUI.shared.chooseFilesToAdd() }
                    if !library.missing.isEmpty {
                        Button("Remove \(library.missing.count) missing", role: .destructive) { library.removeMissing() }
                    }
                    Spacer()
                    Button("Remove everything…", role: .destructive) { confirmClear = true }.disabled(library.items.isEmpty)
                }
                if let progress = library.importProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) { Text("Adding \(progress.done) / \(progress.total)") }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Files stay where they are. Removing something here only takes it out of the player, never off your disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if library.playlists.isEmpty {
                    Text("No playlists yet.").foregroundStyle(.secondary)
                }
                ForEach(library.playlists) { playlist in
                    HStack {
                        TextField("Name", text: Binding(get: { playlist.name }, set: { library.renamePlaylist(playlist.id, to: $0) }))
                            .textFieldStyle(.roundedBorder)
                        Text("\(playlist.itemIDs.count)").foregroundStyle(.secondary).monospacedDigit()
                        Button(role: .destructive) { library.deletePlaylist(playlist.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("New playlist", text: $newPlaylist, prompt: Text("Playlist name")).textFieldStyle(.roundedBorder).onSubmit(createPlaylist)
                    Button("Create", action: createPlaylist).disabled(newPlaylist.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Playlists")
            }

            Section {
                TextField("Search", text: $search, prompt: Text("Search the library")).textFieldStyle(.roundedBorder)
                List(selection: $selection) {
                    ForEach(shown) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.kind == .video ? "film" : "music.note").foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                Text(library.missing.contains(item.id) ? String(localized: "File missing") : (item.detail.isEmpty ? item.fileName : item.detail))
                                    .font(.caption).foregroundStyle(library.missing.contains(item.id) ? Color.orange : .secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(PlayerFormat.clock(item.duration)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { PlayerUI.shared.play(item, in: shown) }
                        .contextMenu {
                            Button("Play") { PlayerUI.shared.play(item, in: shown) }
                            Button("Show in Finder") { PlayerUI.shared.reveal(item) }
                            if library.missing.contains(item.id) { Button("Locate…") { PlayerUI.shared.locate(item) } }
                            Menu("Add to playlist") {
                                ForEach(library.playlists) { playlist in
                                    Button(playlist.name) { library.add(contextTargets(item), toPlaylist: playlist.id) }
                                }
                            }
                            Divider()
                            Button("Remove from library", role: .destructive) { library.remove(Set(contextTargets(item))) }
                        }
                    }
                }
                .frame(height: 260)
                .onDeleteCommand { library.remove(selection); selection = [] }
                HStack {
                    Text("\(shown.count) shown").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove selected", role: .destructive) { library.remove(selection); selection = [] }.disabled(selection.isEmpty)
                }
            } header: {
                Text("Everything in the library")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Player")
        .confirmationDialog("Remove everything from the player?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove everything", role: .destructive) { engine.stop(); library.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your files are not deleted.")
        }
        .task { await library.checkAvailability() }
    }

    /// A right-click on a selected row acts on the whole selection; on any other row, on that row alone.
    private func contextTargets(_ item: MediaItem) -> [UUID] {
        selection.contains(item.id) ? Array(selection) : [item.id]
    }

    private func createPlaylist() {
        guard !newPlaylist.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        library.createPlaylist(named: newPlaylist)
        newPlaylist = ""
    }
}
