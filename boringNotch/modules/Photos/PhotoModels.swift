//
//  PhotoModels.swift
//  boringNotch
//

import Foundation
import UniformTypeIdentifiers

/// One photo the library knows about. The file stays where it is; this is what was read from it.
struct Photo: Identifiable, Hashable {
    let id: Int64
    var path: String
    var name: String
    var width: Int
    var height: Int
    /// When it was taken (the EXIF date), or when the file was made when it has none.
    var taken: Date
    var added: Date
    var size: Int64
    var isMissing: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 1 }
    var folderName: String { url.deletingLastPathComponent().lastPathComponent }
}

struct Album: Identifiable, Hashable {
    let id: Int64
    var name: String
    var created: Date
    var count: Int
}

enum PhotoScope: Hashable {
    case all
    case album(Int64)
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case takenNewest, takenOldest, name, addedNewest
    var id: String { rawValue }
}

/// What a file name says about whether the photo library can show it.
enum PhotoFormats {
    static let supported: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
    /// Formats worth naming when they are skipped, rather than ignoring silently.
    static let knownUnsupported: Set<String> = ["raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "psd", "svg", "ai", "eps", "jxl", "avif"]

    enum Support { case supported, unsupported, notAnImage }

    static func support(of url: URL) -> Support {
        let ext = url.pathExtension.lowercased()
        if supported.contains(ext) { return .supported }
        if knownUnsupported.contains(ext) { return .unsupported }
        return .notAnImage
    }

    static var contentTypes: [UTType] { supported.compactMap { UTType(filenameExtension: $0) } + [.folder] }
}

struct PhotoImportSummary: Equatable {
    var added = 0
    var alreadyInLibrary = 0
    /// Every file that was looked at and left out, with why.
    var skipped: [SkippedFile] = []
    /// Every picture file of the selection, as stored paths, whether it was new or already in the library.
    var candidatePaths: [String] = []
    /// Where they were filed as they were added ("“Trip”", "3 albums"), if an album was chosen.
    var albumNote: String?

    var unsupported: [String] { skipped.filter(\.isFormatProblem).map(\.name) }
    var failed: [String] { skipped.filter { !$0.isFormatProblem }.map(\.name) }

    var isEmpty: Bool { added == 0 && alreadyInLibrary == 0 && skipped.isEmpty && candidatePaths.isEmpty }
    var report: ImportReport { ImportReport(domain: .photo, added: added, alreadyInLibrary: alreadyInLibrary, skipped: skipped, playlistName: albumNote) }
}
