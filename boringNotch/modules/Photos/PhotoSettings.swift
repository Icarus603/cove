//
//  PhotoSettings.swift
//  boringNotch
//
//  Settings → Photos: what the library holds, adding and tidying, and the thumbnail cache.
//

import AppKit
import SwiftUI

struct PhotoSettings: View {
    @ObservedObject private var library = PhotoLibrary.shared
    @State private var thumbnailBytes: Int64 = 0
    @State private var confirmClear = false
    @State private var findResult: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Photos") { Text("\(library.photoCount)").monospacedDigit() }
                LabeledContent("Albums") { Text("\(library.albums.count)").monospacedDigit() }
                if library.missingCount > 0 {
                    LabeledContent("Missing") { Text("\(library.missingCount)").monospacedDigit().foregroundStyle(Color.coveWarning) }
                }
                HStack {
                    Button("Open Photos") { PhotoWindowController.shared.show() }
                    Button("Add photos or folders…") { PhotoActions.chooseFilesToAdd() }
                    Spacer()
                    Button("Remove everything…", role: .destructive) { confirmClear = true }.disabled(library.photoCount == 0)
                }
                if let progress = library.importProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) { Text("Adding \(progress.done) / \(progress.total)") }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Photos stay where they are. Cove remembers where each one is, and follows it if you move or rename it. Removing a photo here only takes it out of the library, never off your disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if library.missingCount > 0 {
                Section {
                    HStack {
                        Button("Look in a folder…", action: findInFolder)
                        Button("Check again") { Task { await library.checkAvailability() } }
                        Spacer()
                        Button("Remove missing", role: .destructive) { Task { await library.removeMissing() } }
                    }
                    if let findResult { Text(findResult).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Missing photos")
                } footer: {
                    Text("A photo is missing when its file was deleted or its disk is not connected. If you moved a whole folder, point Cove at it and it reconnects the photos by file name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Space used") { Text(ByteCountFormatter.string(fromByteCount: thumbnailBytes, countStyle: .file)).monospacedDigit() }
                Button("Clear thumbnails") { library.clearThumbnails(); refreshSize() }.disabled(thumbnailBytes == 0)
            } header: {
                Text("Thumbnails")
            } footer: {
                Text("Small pictures made the first time a photo is shown, so the grid is quick. They can be cleared at any time and are made again when needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let problem = library.problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Photos")
        .onAppear(perform: refreshSize)
        .onChange(of: library.revision) { _, _ in refreshSize() }
        .task { await library.checkAvailability() }
        .confirmationDialog("Remove every photo from the library?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove everything", role: .destructive) { Task { await library.removeEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your photo files are not deleted. Albums are kept, empty.")
        }
    }

    private func refreshSize() {
        Task { thumbnailBytes = await library.thumbnailBytes() }
    }

    private func findInFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the folder to look in")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let found = await library.relocateMissing(inFolder: folder)
            findResult = found == 0 ? String(localized: "No photos were found in that folder.") : String(localized: "Reconnected \(found) photos.")
        }
    }
}
