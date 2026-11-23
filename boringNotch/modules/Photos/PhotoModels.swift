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

    /// The album (or All Photos) the user was last looking at, so the tab and the window open where they were left.
    private static let key = "photos.scope"
    static var saved: PhotoScope {
        get {
            let id = UserDefaults.standard.object(forKey: key) as? Int
            return id.map { PhotoScope.album(Int64($0)) } ?? .all
        }
        set {
            if case .album(let id) = newValue { UserDefaults.standard.set(Int(id), forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case takenNewest, takenOldest, name, addedNewest
    /// The order the user arranged inside an album (only meaningful there).
    case manual
    var id: String { rawValue }

    /// What the sort menu offers: the arranged order only inside an album.
    static func choices(inAlbum: Bool) -> [PhotoSort] {
        inAlbum ? [.manual, .takenNewest, .takenOldest, .name, .addedNewest] : [.takenNewest, .takenOldest, .name, .addedNewest]
    }
}

/// Where photos moved by hand go in an album.
enum PhotoMove: Equatable {
    case before(Int64), start, end, earlier, later
}

enum PhotoOrder {
    /// The album order after moving `moving` as asked. Moved photos keep their order among themselves.
    static func moved(_ order: [Int64], moving: Set<Int64>, _ move: PhotoMove) -> [Int64] {
        let picked = order.filter { moving.contains($0) }
        guard !picked.isEmpty else { return order }
        let rest = order.filter { !moving.contains($0) }
        switch move {
        case .start: return picked + rest
        case .end: return rest + picked
        case .before(let target):
            guard let index = rest.firstIndex(of: target) else { return order }
            return Array(rest[..<index]) + picked + Array(rest[index...])
        case .earlier:
            var a = order
            for i in 1..<max(a.count, 1) where moving.contains(a[i]) && !moving.contains(a[i - 1]) { a.swapAt(i, i - 1) }
            return a
        case .later:
            var a = order
            for i in stride(from: a.count - 2, through: 0, by: -1) where moving.contains(a[i]) && !moving.contains(a[i + 1]) { a.swapAt(i, i + 1) }
            return a
        }
    }
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
