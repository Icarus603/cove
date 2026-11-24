//
//  NotesView.swift
//  boringNotch
//
//  The Notes tab: the list of notes on the left (search, New), the open note on the right. Clicking the note starts writing in it
//  (see NoteTextInput). Built like the Player tab: the same type sizes, row height, pill buttons and delete confirmation.
//

import SwiftUI

struct NotesView: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var search = ""
    @State private var confirmingDelete = false
    @State private var editorBox = AnchorBox()

    var body: some View {
        Group {
            if store.notes.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: 12) {
                    listPane.frame(width: 210)
                    editorPane.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 4)
        .onChange(of: store.selectedID) { _, _ in
            NoteTextInputController.shared.end()
            confirmingDelete = false
        }
    }

    // MARK: List

    private var listPane: some View {
        let shown = store.notes(matching: search)
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                NotchTextField(text: $search, placeholder: "Search")
                Button { newNote() } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .help(Text("New Note"))
            }
            if shown.isEmpty {
                Text("No matching notes").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { note in
                            NoteRow(note: note, selected: note.id == store.selectedID) { store.selectedID = note.id }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editorPane: some View {
        if let note = store.selected {
            VStack(spacing: 6) {
                Group {
                    if confirmingDelete { deleteRow(note) } else { headerRow(note) }
                }
                .frame(height: 28)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06))
                    ScrollView {
                        Group {
                            if note.text.isEmpty {
                                Text("Write something…").foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: note.text).foregroundStyle(.white)
                            }
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .scrollIndicators(.hidden)
                }
                .background(AnchorView(box: editorBox))
                .contentShape(Rectangle())
                .onTapGesture { startWriting() }
                .onDisappear { NoteTextInputController.shared.end(ifAnchoredTo: editorBox) }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Pick a note, or press New to write one.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headerRow(_ note: Note) -> some View {
        HStack(spacing: 8) {
            Text("Edited \(note.modified.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            PlayerIconButton(symbol: "square.and.arrow.up", size: 11, help: "Export as Markdown…") { NotesExport.export(note) }
            PlayerIconButton(symbol: "trash", size: 11, help: "Delete Note") { confirmingDelete = true }
        }
    }

    /// Asked in the row itself (a system dialog does not belong in the notch).
    private func deleteRow(_ note: Note) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Delete this note?").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Button { confirmingDelete = false } label: {
                Text("Cancel").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12))).foregroundStyle(Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            Button {
                confirmingDelete = false
                store.delete(note.id)
            } label: {
                Text("Delete Note").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Color.red.opacity(0.9))).foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Nothing yet

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No notes yet").font(.system(size: 12, weight: .semibold))
            Text("Jot something down; it is kept on this Mac.").font(.system(size: 10)).foregroundStyle(.secondary)
            Button { newNote() } label: {
                Label("New Note", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func newNote() {
        search = ""
        confirmingDelete = false
        store.newNote()
        // Once the editor has been laid out for the new note.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startWriting() }
    }

    private func startWriting() {
        guard let note = store.selected, let rect = editorBox.screenRect else { return }
        let id = note.id
        NoteTextInputController.shared.begin(
            over: rect, text: note.text,
            onChange: { NotesStore.shared.update(id, text: $0) },
            onEnd: { NotesStore.shared.removeIfEmpty(id); NotesStore.shared.flush() },
            anchor: editorBox)
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? String(localized: "New Note") : note.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(note.title.isEmpty ? Color.secondary : Color.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.dateText(note.modified)).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                    Text(verbatim: note.preview).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.effectiveAccent.opacity(0.16) : (hovering ? Color.white.opacity(0.07) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// The time for today's notes, the date for older ones.
    private static func dateText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
    }
}
