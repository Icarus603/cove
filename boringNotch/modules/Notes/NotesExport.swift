//
//  NotesExport.swift
//  boringNotch
//
//  Notes out as files. Markdown by default: a note is plain text, which is already valid Markdown, so the text goes out exactly as
//  written, with the first line's words as the file name. One note through a save panel, or all of them into a folder.
//

import AppKit
import UniformTypeIdentifiers

enum NotesExport {
    /// A file name from the note's title: no characters a file system objects to, a sensible length, never empty.
    static func baseName(for note: Note) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        var name = note.title.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? String(localized: "Note") : name
    }

    /// The text as written, ending with a newline.
    static func markdown(for note: Note) -> String {
        note.text.hasSuffix("\n") ? note.text : note.text + "\n"
    }

    /// File names for a set of notes in one folder: the same title twice becomes "Title" and "Title 2".
    static func fileNames(for notes: [Note], extension ext: String = "md") -> [UUID: String] {
        var used: [String: Int] = [:]
        var names: [UUID: String] = [:]
        for note in notes {
            let base = baseName(for: note)
            let key = base.lowercased()
            let count = (used[key] ?? 0) + 1
            used[key] = count
            names[note.id] = (count == 1 ? base : "\(base) \(count)") + "." + ext
        }
        return names
    }

    private static var markdownType: UTType { UTType(filenameExtension: "md") ?? .plainText }

    /// One note, through a save panel (Markdown unless the name is given another ending).
    @MainActor
    static func export(_ note: Note) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Note")
        panel.prompt = String(localized: "Export")
        panel.nameFieldStringValue = baseName(for: note) + ".md"
        panel.allowedContentTypes = [markdownType, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        let text = markdown(for: note)
        SharingStateManager.shared.beginInteraction()
        NSApp.activate(ignoringOtherApps: true)
        panel.presentAboveNotch()
        panel.begin { response in
            SharingStateManager.shared.endInteraction()
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
        }
    }

    /// Every note into a folder as its own Markdown file. Returns how many were written.
    @MainActor
    @discardableResult
    static func exportAll(_ notes: [Note], to folder: URL) -> Int {
        let names = fileNames(for: notes)
        var written = 0
        for note in notes {
            guard let name = names[note.id] else { continue }
            let url = uniqueURL(folder.appendingPathComponent(name))
            if (try? markdown(for: note).write(to: url, atomically: true, encoding: .utf8)) != nil { written += 1 }
        }
        return written
    }

    /// Never overwrites a file that is already there: "Title.md" becomes "Title 2.md" and so on.
    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
