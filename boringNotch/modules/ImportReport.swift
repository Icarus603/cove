//
//  ImportReport.swift
//  boringNotch
//
//  What happened when files were added to the Player or Photos library, told plainly: how many went in, and for every file
//  that did not, which file it is, where it lives, why it was left out and what the user can do about it. A short line sits
//  in the notch or the photo window; "Why?" opens a window listing each file.
//

import AppKit
import SwiftUI

/// Which library a file was being added to; the wording differs (play vs show).
enum ImportDomain: Equatable { case media, photo }

/// A file that was looked at but not added.
struct SkippedFile: Equatable, Hashable, Identifiable {
    enum Reason: Equatable, Hashable {
        /// A format the library does not take (mkv, RAW…), known from the name.
        case format
        /// The file vanished between choosing and reading it.
        case missing
        /// macOS does not let Cove read it.
        case noPermission
        /// Zero bytes.
        case empty
        /// Still in iCloud, not on this Mac.
        case notDownloaded
        /// The name says it should work, but its content could not be decoded.
        case damaged
    }

    let path: String
    let reason: Reason
    let domain: ImportDomain

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    private var ext: String { url.pathExtension.uppercased() }

    var isFormatProblem: Bool { reason == .format }

    /// Why a file the name said was fine could not be read, worked out from the file itself.
    static func diagnose(_ path: String, domain: ImportDomain) -> SkippedFile {
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        let reason: Reason
        if !manager.fileExists(atPath: path) {
            reason = .missing
        } else if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
                  status == .notDownloaded {
            reason = .notDownloaded
        } else if !manager.isReadableFile(atPath: path) {
            reason = .noPermission
        } else if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
            reason = .empty
        } else {
            reason = .damaged
        }
        return SkippedFile(path: path, reason: reason, domain: domain)
    }

    private static let rawFormats: Set<String> = ["RAW", "CR2", "CR3", "NEF", "ARW", "DNG", "ORF", "RW2", "RAF"]
    private static let designFormats: Set<String> = ["PSD", "SVG", "AI", "EPS"]

    /// One sentence on why the file is not in the library.
    var explanation: String {
        switch reason {
        case .format:
            switch domain {
            case .media:
                return String(localized: "\(ext) files cannot be played by the macOS media engine that Cove uses.")
            case .photo:
                if Self.rawFormats.contains(ext) { return String(localized: "\(ext) is a camera RAW file; Photos in Cove takes finished pictures only.") }
                if Self.designFormats.contains(ext) { return String(localized: "\(ext) is a design file rather than a picture.") }
                return String(localized: "\(ext) pictures are not supported yet.")
            }
        case .missing: return String(localized: "The file was gone by the time Cove read it (moved or deleted).")
        case .noPermission: return String(localized: "macOS does not allow Cove to read this file.")
        case .empty: return String(localized: "The file is empty (0 bytes).")
        case .notDownloaded: return String(localized: "The file is in iCloud and not downloaded to this Mac.")
        case .damaged:
            switch domain {
            case .media: return String(localized: "Its name says \(ext), but the content could not be decoded.")
            case .photo: return String(localized: "Its name says \(ext), but the picture inside could not be read.")
            }
        }
    }

    /// What the user can do about it.
    var advice: String {
        switch reason {
        case .format:
            switch domain {
            case .media: return String(localized: "Open it in a player such as IINA or VLC, or convert it to MP4 / M4A and add it again.")
            case .photo:
                if Self.rawFormats.contains(ext) { return String(localized: "Export it as JPEG or HEIC from your camera app or Apple Photos, then add that.") }
                return String(localized: "Export it as PNG or JPEG, then add that.")
            }
        case .missing: return String(localized: "Find where it went and add it again.")
        case .noPermission: return String(localized: "Check its permissions in Finder (Get Info), or copy it somewhere you own.")
        case .empty: return String(localized: "It was probably not fully downloaded or copied. Get the file again.")
        case .notDownloaded: return String(localized: "Download it in Finder first (the cloud icon), then add it again.")
        case .damaged: return String(localized: "Try opening it in another app. If that fails too, the file is damaged or only partly downloaded.")
        }
    }

    /// Short label for the group the file is listed under.
    var groupTitle: LocalizedStringKey { isFormatProblem ? "Format not supported" : "Could not be read" }
}

/// The parts every import summary has in common, so one banner and one window serve both libraries.
struct ImportReport: Equatable {
    var domain: ImportDomain
    var added: Int
    var alreadyInLibrary: Int
    var skipped: [SkippedFile]

    var isClean: Bool { skipped.isEmpty }

    var headline: String {
        if added == 0 && alreadyInLibrary > 0 && skipped.isEmpty {
            return String(localized: "Everything was already in the library")
        }
        return domain == .media ? String(localized: "Added \(added) files") : String(localized: "Added \(added) photos")
    }

    /// The second half of the line: what did not go in, said without jargon.
    var detail: String? {
        var parts: [String] = []
        if alreadyInLibrary > 0 && added > 0 { parts.append(String(localized: "\(alreadyInLibrary) were already there")) }
        if !skipped.isEmpty { parts.append(String(localized: "\(skipped.count) not added")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Plain text for the clipboard.
    var listText: String {
        skipped.map { "\($0.path)\n    \($0.explanation)" }.joined(separator: "\n")
    }
}

// MARK: - The line in the notch and the photo window

struct ImportReportBar: View {
    let report: ImportReport
    /// Smaller type for the notch.
    var compact: Bool = false
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: compact ? 7 : 9) {
            Image(systemName: report.isClean ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(report.isClean ? AnyShapeStyle(compact ? Color.white.opacity(0.85) : Color.effectiveAccent) : AnyShapeStyle(Color.primary.opacity(0.75)))
            Text(report.headline).font(.system(size: compact ? 11 : 12, weight: .semibold)).lineLimit(1)
            if let detail = report.detail {
                Text(detail).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !report.isClean {
                Button { ImportReportWindowController.shared.show(report) } label: {
                    Text("Which ones and why").font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 3 : 4)
                        .background(Capsule().fill(Color.primary.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: compact ? 8 : 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.leading, compact ? 9 : 12).padding(.trailing, compact ? 5 : 8).padding(.vertical, compact ? 5 : 7)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
        .task(id: report) {
            // Good news goes away by itself; a list of problems stays until it is dismissed.
            if report.isClean { try? await Task.sleep(nanoseconds: 4_000_000_000); dismiss() }
        }
    }
}

// MARK: - The window that lists every file

@MainActor
final class ImportReportWindowController: NSObject, NSWindowDelegate {
    static let shared = ImportReportWindowController()
    private var window: NSWindow?

    func show(_ report: ImportReport) {
        let view = ImportReportView(report: report) { [weak self] in self?.window?.close() }
        if let window {
            (window.contentViewController as? NSHostingController<ImportReportView>)?.rootView = view
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = String(localized: "Files not added")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 300)
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.delegate = self
            window.center()
            self.window = window
        }
        AppActivation.windowOpened("import-report")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowClosed("import-report")
    }
}

struct ImportReportView: View {
    let report: ImportReport
    let close: () -> Void
    @State private var copied = false

    private var groups: [(title: LocalizedStringKey, files: [SkippedFile])] {
        let format = report.skipped.filter(\.isFormatProblem)
        let unreadable = report.skipped.filter { !$0.isFormatProblem }
        return [("Format not supported", format), ("Could not be read", unreadable)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.files.first!.id) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Text("\(group.files.count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                    if index > 0 { Divider().padding(.leading, 52) }
                                    SkippedFileRow(file: file)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .tint(Color.effectiveAccent)
        .frame(minWidth: 480, minHeight: 300)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            stat(report.added, "Added to the library")
            if report.alreadyInLibrary > 0 { stat(report.alreadyInLibrary, "Already in the library") }
            stat(report.skipped.count, "Not added (stat)")
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private func stat(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Show All in Finder") { NSWorkspace.shared.activateFileViewerSelecting(report.skipped.map(\.url)) }
            Button(copied ? "Copied" : "Copy List") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.listText, forType: .string)
                copied = true
            }
            Spacer()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

private struct SkippedFileRow: View {
    let file: SkippedFile
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(file.folder).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Text(file.explanation).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                Text(file.advice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if file.reason != .missing {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .opacity(hovering ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if file.reason != .missing {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }
}
