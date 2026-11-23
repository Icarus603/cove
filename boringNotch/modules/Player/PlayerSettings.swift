//
//  PlayerSettings.swift
//  boringNotch
//
//  Settings → Player: how playback behaves, and a way into the library. The library itself (browsing, bulk removal,
//  playlists) lives in its own window, which has the room for it.
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

    @State private var confirmClear = false
    @State private var confirmRemoveMissing = false

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
                LabeledContent("Playlists") { Text("\(library.playlists.count)").monospacedDigit() }
                LabeledContent("Total length") { Text(PlayerFormat.clock(library.totalDuration)).monospacedDigit() }
                if library.missing.count > 0 {
                    LabeledContent("Missing files") { Text("\(library.missing.count)").monospacedDigit().foregroundStyle(Color.coveWarning) }
                }
                if let progress = library.importProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) { Text("Adding \(progress.done) / \(progress.total)") }
                }
                HStack {
                    Button { PlayerManagerWindowController.shared.show() } label: { Label("Manage Library…", systemImage: "rectangle.and.pencil.and.ellipsis") }
                        .buttonStyle(.borderedProminent)
                    Button("Add files or folders…") { PlayerUI.shared.chooseFilesToAdd() }
                    Spacer()
                }
            } header: {
                Text("Library")
            } footer: {
                Text("The library window lists everything in one scrollable table: select one, many or all, and remove or add to a playlist in one go. Files stay where they are; removing something only takes it out of the player, never off your disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if library.missing.count > 0 {
                    HStack {
                        Button("Show missing files") { PlayerManagerWindowController.shared.show(scope: .missing) }
                        Button("Remove \(library.missing.count) missing", role: .destructive) { confirmRemoveMissing = true }
                        Spacer()
                    }
                }
                HStack {
                    Spacer()
                    Button("Remove everything…", role: .destructive) { confirmClear = true }.disabled(library.items.isEmpty)
                }
            } header: {
                Text("Clean up")
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
        .confirmationDialog(String(localized: "Remove \(library.missing.count) missing files from the library?"), isPresented: $confirmRemoveMissing, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) { library.removeMissing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your files are not deleted.")
        }
        .task { await library.checkAvailability() }
    }
}
