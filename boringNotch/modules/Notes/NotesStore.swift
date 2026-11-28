//
//  NotesStore.swift
//  boringNotch
//
//  The notes: plain text, one list, kept on this Mac in a single JSON file in Cove's Application Support folder. A note's first
//  line is its title. The newest edit is listed first. Writes are batched a moment after typing stops, and flushed when Cove quits.
//

import AppKit
import Combine
import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var created = Date()
    var modified = Date()

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// The first line, or empty for a note with nothing written.
    var title: String { lines.first ?? "" }
    /// The next line, for the list.
    var preview: String { lines.dropFirst().first ?? "" }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
final class NotesStore: ObservableObject {
    #if DEBUG
    /// scripts/shots.sh and the checks set this so a run uses a throw-away folder instead of the user's notes.
    static let shared = NotesStore(directory: ProcessInfo.processInfo.environment["COVE_NOTES_SANDBOX"].map { URL(fileURLWithPath: $0) })
    #else
    static let shared = NotesStore()
    #endif

    private static let selectedKey = "notes.selected"

    /// Newest edit first.
    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey) }
    }
    var pendingQuickNoteID: UUID?

    let fileURL: URL
    private let writeQueue = DispatchQueue(label: "cove.notes.write", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    init(directory: URL? = nil) {
        let base = directory ?? {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Cove"
            return support.appendingPathComponent(name).appendingPathComponent("Notes")
        }()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("notes.json")
        load()
        if let saved = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:)), notes.contains(where: { $0.id == saved }) {
            selectedID = saved
        } else {
            selectedID = notes.first?.id
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }

    // MARK: Reading and writing

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded.sorted { $0.modified > $1.modified }
        } else {
            // Not readable: keep the file where the user can find it rather than overwrite it with an empty list.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("notes.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes now (and drops any write that was waiting).
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        guard let data = try? JSONEncoder().encode(notes) else { return }
        let url = fileURL
        writeQueue.sync { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Editing

    var selected: Note? { notes.first { $0.id == selectedID } }

    @discardableResult
    func newNote() -> Note {
        // An empty note that is already there is reused: pressing New twice does not pile up blank notes.
        if let blank = notes.first(where: { $0.isEmpty }) { selectedID = blank.id; return blank }
        let note = Note()
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
        return note
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        var note = notes.remove(at: index)
        note.text = text
        note.modified = Date()
        notes.insert(note, at: 0)
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        if selectedID == id { selectedID = notes.indices.contains(index) ? notes[index].id : notes.last?.id }
        flush()
    }

    /// A note left with nothing in it goes away by itself.
    func removeIfEmpty(_ id: UUID) {
        if let note = notes.first(where: { $0.id == id }), note.isEmpty { delete(id) }
    }

    func deleteAll() {
        notes = []
        selectedID = nil
        flush()
    }

    /// Notes whose text contains the search (all of them when it is empty).
    func notes(matching search: String) -> [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}
