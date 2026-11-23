//
//  PhotoStore.swift
//  boringNotch
//
//  The photo library's database: photos (path, size, date taken), albums, and which photos are in which album. SQLite,
//  because a library can hold tens of thousands of photos and must stay quick to open, query and change. Every call runs
//  on one serial queue, off the main thread.
//

import Foundation

struct PhotoRecord {
    var path: String
    var bookmark: Data?
    var name: String
    var width: Int
    var height: Int
    var taken: Date
    var added: Date
    var size: Int64
}

final class PhotoStore: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let queue = DispatchQueue(label: "app.cove.photos.database", qos: .userInitiated)

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        try database.transaction {
            try database.exec("""
                CREATE TABLE IF NOT EXISTS photos(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL UNIQUE,
                    bookmark BLOB,
                    name TEXT NOT NULL,
                    width INTEGER NOT NULL DEFAULT 0,
                    height INTEGER NOT NULL DEFAULT 0,
                    taken REAL NOT NULL,
                    added REAL NOT NULL,
                    size INTEGER NOT NULL DEFAULT 0,
                    missing INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS photos_taken ON photos(taken DESC, id DESC);
                CREATE INDEX IF NOT EXISTS photos_added ON photos(added DESC, id DESC);
                CREATE TABLE IF NOT EXISTS albums(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    created REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS album_photos(
                    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    added REAL NOT NULL,
                    PRIMARY KEY(album_id, photo_id)
                );
                CREATE INDEX IF NOT EXISTS album_photos_photo ON album_photos(photo_id);
                """)
            if database.userVersion == 0 { database.userVersion = 1 }
        }
    }

    /// Runs `body` on the database queue.
    private func perform<T>(_ body: @escaping (SQLiteDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body(self.database)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Photos

    /// Adds photos; a path already present is left alone. Returns how many were new.
    func insert(_ records: [PhotoRecord]) async throws -> Int {
        try await perform { db in
            try db.transaction {
                let statement = try db.prepare("INSERT OR IGNORE INTO photos(path, bookmark, name, width, height, taken, added, size) VALUES (?,?,?,?,?,?,?,?)")
                var inserted = 0
                for record in records {
                    statement.reset()
                    try statement.bind([.text(record.path), record.bookmark.map { .blob($0) } ?? .null, .text(record.name), .int(Int64(record.width)),
                                        .int(Int64(record.height)), .double(record.taken.timeIntervalSince1970), .double(record.added.timeIntervalSince1970),
                                        .int(record.size)])
                    try statement.step()
                    inserted += db.changes
                }
                return inserted
            }
        }
    }

    /// Which of `paths` are already in the library.
    func knownPaths(among paths: [String]) async throws -> Set<String> {
        try await perform { db in
            var known = Set<String>()
            for chunk in paths.chunked(into: 500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let statement = try db.prepare("SELECT path FROM photos WHERE path IN (\(marks))")
                known.formUnion(try statement.rows(chunk.map { .text($0) }) { $0.text(0) })
            }
            return known
        }
    }

    /// The ids of what to show, in order. Search matches anywhere in the path (file and folder names).
    func ids(scope: PhotoScope, search: String, sort: PhotoSort) async throws -> [Int64] {
        try await perform { db in
            var values: [SQLiteValue] = []
            var sql = "SELECT p.id FROM photos p"
            var conditions: [String] = []
            if case .album(let id) = scope {
                sql += " JOIN album_photos ap ON ap.photo_id = p.id"
                conditions.append("ap.album_id = ?")
                values.append(.int(id))
            }
            for word in search.split(separator: " ") {
                conditions.append("p.path LIKE ? ESCAPE '\\'")
                values.append(.text("%" + Self.escapeLike(String(word)) + "%"))
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            switch sort {
            case .takenNewest: sql += " ORDER BY p.taken DESC, p.id DESC"
            case .takenOldest: sql += " ORDER BY p.taken ASC, p.id ASC"
            case .name: sql += " ORDER BY p.name COLLATE NOCASE ASC, p.id ASC"
            case .addedNewest: sql += " ORDER BY p.added DESC, p.id DESC"
            }
            return try db.prepare(sql).rows(values) { $0.int(0) }
        }
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    func photos(ids: [Int64]) async throws -> [Int64: Photo] {
        try await perform { db in
            var result: [Int64: Photo] = [:]
            for chunk in ids.chunked(into: 500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let statement = try db.prepare("SELECT id, path, name, width, height, taken, added, size, missing FROM photos WHERE id IN (\(marks))")
                for photo in try statement.rows(chunk.map { .int($0) }, Self.photo(from:)) { result[photo.id] = photo }
            }
            return result
        }
    }

    private static func photo(from row: SQLiteStatement) -> Photo {
        Photo(id: row.int(0), path: row.text(1), name: row.text(2), width: Int(row.int(3)), height: Int(row.int(4)),
              taken: Date(timeIntervalSince1970: row.double(5)), added: Date(timeIntervalSince1970: row.double(6)),
              size: row.int(7), isMissing: row.int(8) != 0)
    }

    func counts() async throws -> (photos: Int, missing: Int) {
        try await perform { db in
            try db.prepare("SELECT COUNT(*), COALESCE(SUM(missing), 0) FROM photos").firstRow { (Int($0.int(0)), Int($0.int(1))) } ?? (0, 0)
        }
    }

    func remove(_ ids: [Int64]) async throws {
        try await perform { db in
            try db.transaction {
                for chunk in ids.chunked(into: 500) {
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    try db.run("DELETE FROM photos WHERE id IN (\(marks))", chunk.map { .int($0) })
                }
            }
        }
    }

    func removeAllPhotos() async throws {
        try await perform { db in try db.run("DELETE FROM photos") }
    }

    // MARK: Files that moved

    func fileReferences() async throws -> [(id: Int64, path: String, bookmark: Data?)] {
        try await perform { db in
            try db.prepare("SELECT id, path, bookmark FROM photos").rows { ($0.int(0), $0.text(1), $0.blob(2)) }
        }
    }

    func setMissing(_ missing: [Int64], found: [Int64]) async throws {
        try await perform { db in
            try db.transaction {
                for (ids, flag) in [(missing, 1), (found, 0)] {
                    for chunk in ids.chunked(into: 500) {
                        let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                        try db.run("UPDATE photos SET missing = \(flag) WHERE id IN (\(marks))", chunk.map { .int($0) })
                    }
                }
            }
        }
    }

    func updateLocation(id: Int64, path: String, bookmark: Data?) async throws {
        try await perform { db in
            // The new path may already belong to another photo; then this record is the duplicate and goes.
            if try db.prepare("SELECT 1 FROM photos WHERE path = ? AND id != ?").firstRow([.text(path), .int(id)], { _ in true }) == true {
                try db.run("DELETE FROM photos WHERE id = ?", [.int(id)])
            } else {
                try db.run("UPDATE photos SET path = ?, bookmark = ?, name = ?, missing = 0 WHERE id = ?",
                           [.text(path), bookmark.map { .blob($0) } ?? .null, .text(URL(fileURLWithPath: path).lastPathComponent), .int(id)])
            }
        }
    }

    // MARK: Albums

    func albums() async throws -> [Album] {
        try await perform { db in
            try db.prepare("""
                SELECT a.id, a.name, a.created, COUNT(ap.photo_id) FROM albums a
                LEFT JOIN album_photos ap ON ap.album_id = a.id GROUP BY a.id ORDER BY a.created ASC, a.id ASC
                """).rows { Album(id: $0.int(0), name: $0.text(1), created: Date(timeIntervalSince1970: $0.double(2)), count: Int($0.int(3))) }
        }
    }

    func createAlbum(named name: String) async throws -> Int64 {
        try await perform { db in
            try db.run("INSERT INTO albums(name, created) VALUES (?, ?)", [.text(name), .double(Date().timeIntervalSince1970)])
            return db.lastInsertRowID
        }
    }

    func renameAlbum(_ id: Int64, to name: String) async throws {
        try await perform { db in try db.run("UPDATE albums SET name = ? WHERE id = ?", [.text(name), .int(id)]) }
    }

    func deleteAlbum(_ id: Int64) async throws {
        try await perform { db in try db.run("DELETE FROM albums WHERE id = ?", [.int(id)]) }
    }

    /// Returns how many were really added (those already in the album are skipped).
    func add(_ photoIDs: [Int64], toAlbum albumID: Int64) async throws -> Int {
        try await perform { db in
            try db.transaction {
                var added = 0
                let now = Date().timeIntervalSince1970
                let statement = try db.prepare("INSERT OR IGNORE INTO album_photos(album_id, photo_id, added) SELECT ?, id, ? FROM photos WHERE id = ?")
                for id in photoIDs {
                    statement.reset()
                    try statement.bind([.int(albumID), .double(now), .int(id)])
                    try statement.step()
                    added += db.changes
                }
                return added
            }
        }
    }

    func remove(_ photoIDs: [Int64], fromAlbum albumID: Int64) async throws {
        try await perform { db in
            try db.transaction {
                for chunk in photoIDs.chunked(into: 500) {
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    try db.run("DELETE FROM album_photos WHERE album_id = ? AND photo_id IN (\(marks))", [.int(albumID)] + chunk.map { .int($0) })
                }
            }
        }
    }

    func albumIDs(containing photoID: Int64) async throws -> Set<Int64> {
        try await perform { db in
            Set(try db.prepare("SELECT album_id FROM album_photos WHERE photo_id = ?").rows([.int(photoID)]) { $0.int(0) })
        }
    }

    /// The photo that stands for an album: the most recently taken one in it.
    func coverPhotoID(ofAlbum albumID: Int64) async throws -> Int64? {
        try await perform { db in
            try db.prepare("SELECT p.id FROM photos p JOIN album_photos ap ON ap.photo_id = p.id WHERE ap.album_id = ? ORDER BY p.taken DESC, p.id DESC LIMIT 1")
                .firstRow([.int(albumID)]) { $0.int(0) }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
