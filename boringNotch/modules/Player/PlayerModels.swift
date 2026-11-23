//
//  PlayerModels.swift
//  boringNotch
//

import Foundation
import UniformTypeIdentifiers

enum MediaKind: String, Codable {
    case audio, video
}

/// One file in the library. The library stores where it is and what was read from it; the file itself is never copied.
struct MediaItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    /// A bookmark of the file, so it can still be found after it is moved or renamed.
    var bookmark: Data?
    var title: String
    var artist = ""
    var album = ""
    var duration: TimeInterval = 0
    var kind: MediaKind
    var addedAt = Date()
    /// Where playback stopped, to resume from.
    var lastPosition: TimeInterval = 0
    var playCount = 0
    var lastPlayedAt: Date?
    var hasArtwork = false
    var fileSize: Int64 = 0

    var url: URL { URL(fileURLWithPath: path) }
    var fileName: String { url.lastPathComponent }

    /// Subtitle line under the title: artist and album, or the folder for a video.
    var detail: String {
        if kind == .video { return url.deletingLastPathComponent().lastPathComponent }
        return [artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A track that was left more than a few seconds in, and not at its very end, resumes where it stopped. "The very end"
    /// is the last 10 seconds, or the last tenth of a short clip.
    var resumePosition: TimeInterval {
        guard duration > 0, lastPosition > 5, lastPosition < duration - min(10, duration * 0.1) else { return 0 }
        return lastPosition
    }

    /// How much has been played, 0...1, for the thin bar in the list.
    var progress: Double { duration > 0 ? min(max(lastPosition / duration, 0), 1) : 0 }
}

struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var itemIDs: [UUID] = []
}

/// What a file name says about whether it can be played.
enum MediaFormats {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    /// Common formats the system player cannot decode; they are named in the import summary rather than silently ignored.
    static let knownUnsupported: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "rmvb", "ogv", "ogg", "oga", "opus", "ape", "wma", "ts", "mts", "m2ts", "3gp", "mpg", "mpeg", "wv", "dsf", "dff"]

    static var supported: Set<String> { audioExtensions.union(videoExtensions) }

    enum Support { case supported, unsupported, notMedia }

    static func support(of url: URL) -> Support {
        let ext = url.pathExtension.lowercased()
        if supported.contains(ext) { return .supported }
        if knownUnsupported.contains(ext) { return .unsupported }
        return .notMedia
    }

    /// Types for the open panel.
    static var contentTypes: [UTType] {
        supported.compactMap { UTType(filenameExtension: $0) } + [.folder]
    }
}

struct ImportSummary: Equatable {
    var added = 0
    var alreadyInLibrary = 0
    /// Every file that was looked at and left out, with why.
    var skipped: [SkippedFile] = []
    /// Every playable file of the selection that is in the library afterwards, new or already there, in selection order.
    var itemIDs: [UUID] = []
    /// The playlist they were put into at the same time, if one was chosen.
    var playlistName: String?

    /// Names of files in formats the system cannot play (mkv, webm…).
    var unsupported: [String] { skipped.filter(\.isFormatProblem).map(\.name) }
    /// Names of files that looked playable but could not be read.
    var failed: [String] { skipped.filter { !$0.isFormatProblem }.map(\.name) }

    var isEmpty: Bool { added == 0 && alreadyInLibrary == 0 && skipped.isEmpty && itemIDs.isEmpty }
    var report: ImportReport { ImportReport(domain: .media, added: added, alreadyInLibrary: alreadyInLibrary, skipped: skipped, playlistName: playlistName) }
}

enum LibraryFilter: Hashable {
    case all, audio, video
    case playlist(UUID)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded, title, artist, duration, recentlyPlayed
    var id: String { rawValue }
}
