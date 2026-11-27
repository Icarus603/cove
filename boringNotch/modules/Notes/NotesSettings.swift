//
//  NotesSettings.swift
//  boringNotch
//
//  Settings → Notes: how many notes there are, where they are kept, and clearing them.
//

import AppKit
import SwiftUI

struct NotesSettings: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var confirmClear = false
    @State private var exported: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Notes") { Text("\(store.notes.count)").monospacedDigit() }
                HStack {
                    Button("Show in Finder") {
                        store.flush()
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    .disabled(store.notes.isEmpty)
                    Button("Export all as Markdown…", action: exportAll).disabled(store.notes.isEmpty)
                    Spacer()
                    Button("Remove everything…", role: .destructive) { confirmClear = true }.disabled(store.notes.isEmpty)
                }
            } header: {
                Text("Library")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes are plain text, kept on this Mac in one file in Cove's folder. Nothing is sent anywhere.")
                    if let exported { Text(exported) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all \(store.notes.count) notes?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All Notes", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// Every note into a folder of the user's choosing, one Markdown file each.
    private func exportAll() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export all as Markdown…")
        panel.prompt = String(localized: "Export")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let count = NotesExport.exportAll(store.notes, to: folder)
            exported = String(localized: "Exported \(count) notes to “\(folder.lastPathComponent)”.")
        }
    }
}
