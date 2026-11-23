//
//  PhotoDebug.swift
//  boringNotch
//
//  Debug builds only: the photo library run against real files, with no window. scripts/shots.sh runs it with
//  COVE_SHOT_PHOTO_LOGIC=<fixtures dir> [COVE_SHOT_PHOTO_MANY=<dir with thousands of files>], fixtures from
//  scripts/make-photo-fixtures.py.
//

#if DEBUG
import AppKit
import Foundation

@MainActor
enum PhotoChecks {
    static func run(fixtures: URL, many: URL?) async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        func note(_ text: String) { lines.append("NOTE " + text) }
        func timed<T>(_ body: () async -> T) async -> (T, Double) {
            let start = Date(); let value = await body(); return (value, Date().timeIntervalSince(start))
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cove-photo-test-\(UUID().uuidString)")
        let mediaDir = work.appendingPathComponent("media"), libDir = work.appendingPathComponent("lib")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.copyItem(at: fixtures, to: mediaDir)
        defer { try? fm.removeItem(at: work) }

        // ---- import
        let library = PhotoLibrary(directory: libDir)
        let summary = await library.importURLs([mediaDir])
        check("import adds the 12 readable images", summary.added == 12, "added=\(summary.added)")
        check("RAW and PSD are named as unsupported", Set(summary.unsupported) == ["IMG_9999.cr2", "design.psd"], "\(summary.unsupported)")
        check("a broken jpg is reported as failed", summary.failed == ["broken.jpg"], "\(summary.failed)")
        check("text files and hidden folders are ignored", library.photoCount == 12)
        let all = await library.photos(await library.ids(scope: .all))
        func photo(_ name: String) -> Photo? { all.first { $0.name == name } }
        check("a PNG named .jpg is read by its content", photo("disguised.jpg") != nil)
        check("a non-ASCII file name survives", photo("旅行 照片.jpg") != nil)
        check("HEIC, WebP, GIF, TIFF, BMP and PNG are all read", ["photo.heic", "pic.webp", "anim.gif", "scan.tiff", "shot.bmp", "photo.png"].allSatisfy { photo($0) != nil })

        // ---- metadata
        let cal = Calendar.current
        func ymd(_ d: Date?) -> [Int] { d.map { [cal.component(.year, from: $0), cal.component(.month, from: $0), cal.component(.day, from: $0)] } ?? [] }
        check("EXIF date of a JPEG is read", ymd(photo("IMG_0001.jpg")?.taken) == [2019, 5, 1], "\(ymd(photo("IMG_0001.jpg")?.taken))")
        check("the EXIF time is kept too", photo("IMG_0001.jpg").map { cal.component(.hour, from: $0.taken) == 10 } ?? false)
        check("a rotated photo reports the size as shown", photo("IMG_0002.jpg")?.width == 600 && photo("IMG_0002.jpg")?.height == 800, "\(photo("IMG_0002.jpg")?.width ?? 0)x\(photo("IMG_0002.jpg")?.height ?? 0)")
        check("HEIC date is read", ymd(photo("photo.heic")?.taken) == [2021, 7, 4], "\(ymd(photo("photo.heic")?.taken))")
        func fileDate(_ name: String) -> Date {
            let attributes = try? fm.attributesOfItem(atPath: mediaDir.appendingPathComponent(name).path)
            return (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        check("a photo without EXIF uses the file's own date", abs((photo("photo.png")?.taken ?? .distantFuture).timeIntervalSince(fileDate("family/photo.png"))) < 2,
              "\(String(describing: photo("photo.png")?.taken)) vs \(fileDate("family/photo.png"))")
        check("an all-zero EXIF date is treated as unknown", abs((photo("zero_date.jpg")?.taken ?? .distantFuture).timeIntervalSince(fileDate("zero_date.jpg"))) < 2)
        check("file size is recorded", (photo("IMG_0001.jpg")?.size ?? 0) > 1000)

        // ---- importing again
        let again = await library.importURLs([mediaDir, mediaDir.appendingPathComponent("trip/IMG_0001.jpg")])
        check("importing again adds nothing", again.added == 0 && library.photoCount == 12, "added=\(again.added)")
        check("the repeats are counted", again.alreadyInLibrary >= 12, "\(again.alreadyInLibrary)")

        // ---- lists
        let newest = await library.photos(await library.ids(scope: .all, sort: .takenNewest))
        let oldest = await library.photos(await library.ids(scope: .all, sort: .takenOldest))
        check("newest first is ordered by date taken", zip(newest, newest.dropFirst()).allSatisfy { $0.taken >= $1.taken })
        check("oldest first is the reverse", oldest.map(\.id) == newest.map(\.id).reversed())
        check("name order ignores case", (await library.photos(await library.ids(scope: .all, sort: .name))).first?.name == "anim.gif")
        check("search by folder name", await library.ids(scope: .all, search: "trip").count == 3)
        check("search by non-ASCII name", await library.ids(scope: .all, search: "旅行").count == 1)
        check("search words must all match", await library.ids(scope: .all, search: "trip IMG_0002").count == 1)
        check("a % in a search is not a wildcard", await library.ids(scope: .all, search: "%").isEmpty)
        check("no match gives an empty list", await library.ids(scope: .all, search: "zzzz").isEmpty)

        // ---- albums
        let trip = await library.ids(scope: .all, search: "trip")
        let album = await library.createAlbum(named: "  Holiday  ", with: Array(trip.prefix(2)))
        check("album name is trimmed and the photos are in", album?.name == "Holiday" && album?.count == 2, "\(String(describing: album?.count))")
        let addedTwice = await library.add(trip, toAlbum: album!.id)
        check("adding again skips those already in", addedTwice == 1 && library.albums.first?.count == 3, "added=\(addedTwice)")
        check("album list shows only its photos", await library.ids(scope: .album(album!.id)).count == 3)
        check("search works inside an album", await library.ids(scope: .album(album!.id), search: "0002").count == 1)
        check("a photo knows its albums", await library.albumIDs(containing: trip[0]) == [album!.id])
        let second = await library.createAlbum(named: "Second", with: [trip[0]])
        check("a photo can be in several albums", await library.albumIDs(containing: trip[0]) == [album!.id, second!.id])
        check("the cover is the newest photo", await library.coverPhoto(ofAlbum: album!.id) != nil)
        await library.remove([trip[0]], fromAlbum: album!.id)
        check("removing from an album keeps the photo", library.albums.first { $0.id == album!.id }?.count == 2 && library.photoCount == 12)
        await library.renameAlbum(album!.id, to: "Trip")
        check("rename", library.albums.first { $0.id == album!.id }?.name == "Trip")
        await library.renameAlbum(album!.id, to: "   ")
        check("an empty name is refused", library.albums.first { $0.id == album!.id }?.name == "Trip")
        let emptyNamed = await library.createAlbum(named: "")
        check("an empty album name gets a default", emptyNamed?.name == String(localized: "Untitled album"))

        // ---- thumbnails and pictures
        let rotated = photo("IMG_0002.jpg")!
        let thumb = await library.thumbnail(for: rotated)
        check("a thumbnail is made, upright for a rotated photo", (thumb?.size.height ?? 0) > (thumb?.size.width ?? 1) && max(thumb?.size.width ?? 0, thumb?.size.height ?? 0) <= 360,
              "\(thumb?.size ?? .zero)")
        check("it is kept on disk", await library.thumbnailBytes() > 0)
        check("and in memory the second time", library.thumbnails.cached(rotated.id) != nil)
        let gif = await library.thumbnail(for: photo("anim.gif")!)
        check("a GIF has a thumbnail", gif != nil)
        let bigger = await library.image(at: rotated.url, maxPixel: 300)
        check("a picture is scaled to the size asked", max(bigger?.size.width ?? 0, bigger?.size.height ?? 0) <= 300 && (bigger?.size.height ?? 0) > (bigger?.size.width ?? 1))
        library.clearThumbnails()
        check("clearing the thumbnails empties the cache", await library.thumbnailBytes() == 0 && library.thumbnails.cached(rotated.id) == nil)

        // ---- files that move, vanish, return
        // A bookmark follows a file wherever it goes on the same volume, so a moved or renamed file is simply found again.
        let movedPhoto = photo("IMG_0001.jpg")!
        let movedTo = mediaDir.appendingPathComponent("trip/renamed-0001.jpg")
        try? fm.moveItem(at: movedPhoto.url, to: movedTo)
        let acrossFolders = photo("IMG_0003.jpg")!
        let farAway = work.appendingPathComponent("elsewhere/deep/IMG_0003.jpg")
        try? fm.createDirectory(at: farAway.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: acrossFolders.url, to: farAway)
        await library.checkAvailability()
        check("a renamed file is found again through its bookmark", (await library.photo(movedPhoto.id))?.path.hasSuffix("renamed-0001.jpg") == true && library.missingCount == 0,
              "missing=\(library.missingCount)")
        let farPath = (await library.photo(acrossFolders.id))?.path
        check("so is one moved to another folder", farPath?.hasSuffix("elsewhere/deep/IMG_0003.jpg") == true, "\(String(describing: farPath))")

        // A file that is really gone (deleted, or on a disk that is not connected) is marked missing, not dropped.
        let goneSource = photo("IMG_0003.jpg")!
        let kept = work.appendingPathComponent("backup/IMG_0003.jpg")
        try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: farAway, to: kept)
        try? fm.removeItem(at: farAway)
        await library.checkAvailability()
        check("a deleted file is marked missing, not dropped", (await library.photo(goneSource.id))?.isMissing == true && library.photoCount == 12 && library.missingCount == 1,
              "missing=\(library.missingCount) count=\(library.photoCount)")
        check("a missing photo has no thumbnail", await library.thumbnail(for: (await library.photo(goneSource.id))!) == nil)
        let found = await library.relocateMissing(inFolder: work.appendingPathComponent("backup"))
        check("a folder search reconnects a missing file by name", found == 1 && library.missingCount == 0, "found=\(found) missing=\(library.missingCount)")
        // ambiguity: two files with the same name are not guessed between
        let ambiguous = photo("IMG_0002.jpg")!
        try? fm.removeItem(at: ambiguous.url)
        for folder in ["twin1", "twin2"] {
            let target = work.appendingPathComponent("\(folder)/IMG_0002.jpg")
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: fixtures.appendingPathComponent("trip/IMG_0002.jpg"), to: target)
        }
        await library.checkAvailability()
        check("the photo is missing before the search", library.missingCount == 1, "missing=\(library.missingCount)")
        let ambiguousFound = await library.relocateMissing(inFolder: work)
        check("two candidates with the same name are not guessed", ambiguousFound == 0 && library.missingCount == 1, "found=\(ambiguousFound) missing=\(library.missingCount)")
        await library.relocate(ambiguous.id, to: work.appendingPathComponent("twin1/IMG_0002.jpg"))
        check("a file can be located by hand", library.missingCount == 0)

        // ---- removing
        let before = library.photoCount
        let toRemove = Array(await library.ids(scope: .all).prefix(2))
        await library.remove(toRemove)
        check("removing takes photos out and shrinks the albums", library.photoCount == before - 2)
        check("the files themselves are untouched", fm.fileExists(atPath: movedTo.path))
        await library.deleteAlbum(second!.id)
        check("deleting an album keeps its photos", library.albums.count == 2 && library.photoCount == before - 2)

        // ---- persistence and a damaged database
        let countBefore = library.photoCount, albumsBefore = library.albums.count
        let reopened = PhotoLibrary(directory: libDir)
        await reopened.reloadSummary()
        check("the library survives a restart", reopened.photoCount == countBefore && reopened.albums.count == albumsBefore, "\(reopened.photoCount) / \(reopened.albums.count)")
        let garbageDir = work.appendingPathComponent("damaged")
        try? fm.createDirectory(at: garbageDir, withIntermediateDirectories: true)
        try? "this is not a database at all, not even close".write(to: garbageDir.appendingPathComponent("photos.sqlite"), atomically: true, encoding: .utf8)
        let recovered = PhotoLibrary(directory: garbageDir)
        await recovered.reloadSummary()
        let keptAside = (try? fm.contentsOfDirectory(atPath: garbageDir.path))?.contains { $0.hasPrefix("photos.corrupt-") } ?? false
        check("a damaged database starts fresh and is kept aside", recovered.photoCount == 0 && keptAside && recovered.problem == nil)

        // ---- everything removed
        await library.removeEverything()
        check("removing everything empties the library but not the albums", library.photoCount == 0 && library.albums.count == 2, "photos=\(library.photoCount) albums=\(library.albums.count)")

        // ---- scale
        if let many {
            note("scale set: \(many.lastPathComponent)")
            let scale = PhotoLibrary(directory: work.appendingPathComponent("scale"))
            let (summary, importTime) = await timed { await scale.importURLs([many]) }
            note(String(format: "import of %d photos took %.2f s (%.0f per second)", summary.added, importTime, Double(summary.added) / max(importTime, 0.001)))
            check("every photo of the big set is imported", summary.added >= 3000, "added=\(summary.added)")
            check("the import is quick", importTime < 20, String(format: "%.1f s", importTime))
            let (ids, listTime) = await timed { await scale.ids(scope: .all, sort: .takenNewest) }
            check("listing all photos is instant", listTime < 0.15 && ids.count == summary.added, String(format: "%.0f ms for %d", listTime * 1000, ids.count))
            let (_, searchTime) = await timed { await scale.ids(scope: .all, search: "2019 IMG_0012") }
            check("search stays fast", searchTime < 0.2, String(format: "%.0f ms", searchTime * 1000))
            let (page, pageTime) = await timed { await scale.photos(Array(ids.prefix(200))) }
            check("loading a screenful of photos is instant", pageTime < 0.1 && page.count == 200, String(format: "%.0f ms", pageTime * 1000))
            let (albumResult, albumTime) = await timed { () -> Album? in await scale.createAlbum(named: "All of them", with: ids) }
            check("putting thousands of photos in an album is quick", albumTime < 2 && albumResult?.count == ids.count, String(format: "%.0f ms, count=%d", albumTime * 1000, albumResult?.count ?? 0))
            let (madeCount, thumbTime) = await timed { () -> Int in
                var made = 0
                await withTaskGroup(of: Bool.self) { group in
                    for photo in page.prefix(60) { group.addTask { await scale.thumbnail(for: photo) != nil } }
                    for await ok in group where ok { made += 1 }
                }
                return made
            }
            note(String(format: "60 thumbnails took %.2f s", thumbTime))
            check("all 60 thumbnails were really made", madeCount == 60, "made=\(madeCount)")
            check("thumbnails for a screenful come quickly", thumbTime < 6, String(format: "%.1f s", thumbTime))
            let (_, availTime) = await timed { await scale.checkAvailability() }
            check("checking every file takes seconds, not minutes", availTime < 6, String(format: "%.1f s", availTime))
            let size = (try? fm.attributesOfItem(atPath: work.appendingPathComponent("scale/photos.sqlite").path)[.size] as? Int) ?? 0
            note("database file: \(size / 1024) KB for \(ids.count) photos")
        }

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension PhotoChecks {
    /// A small, fast check of album ordering: the arithmetic of moving, and the upgrade of a database made before albums had an
    /// order of their own (a copy of one is built here, with the old table layout).
    static func albumOrder() async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        let a: [Int64] = [1, 2, 3, 4, 5, 6]
        check("move to the start", PhotoOrder.moved(a, moving: [4, 5], .start) == [4, 5, 1, 2, 3, 6])
        check("move to the end", PhotoOrder.moved(a, moving: [2, 3], .end) == [1, 4, 5, 6, 2, 3])
        check("move before another", PhotoOrder.moved(a, moving: [5, 6], .before(2)) == [1, 5, 6, 2, 3, 4])
        check("dropping on itself changes nothing", PhotoOrder.moved(a, moving: [3], .before(3)) == a)
        check("move earlier by one", PhotoOrder.moved(a, moving: [3, 6], .earlier) == [1, 3, 2, 4, 6, 5])
        check("the first one cannot move earlier", PhotoOrder.moved(a, moving: [1, 2], .earlier) == a)
        check("move later by one", PhotoOrder.moved(a, moving: [1, 4], .later) == [2, 1, 3, 5, 4, 6])
        check("the last one cannot move later", PhotoOrder.moved(a, moving: [5, 6], .later) == a)
        check("nothing selected changes nothing", PhotoOrder.moved(a, moving: [], .start) == a)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cove-album-order-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.sqlite")
        do {
            // The layout before this change: no `position`, user_version 1.
            let old = try SQLiteDatabase(url: url)
            try old.exec("""
                CREATE TABLE photos(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE, bookmark BLOB, name TEXT NOT NULL,
                    width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, taken REAL NOT NULL, added REAL NOT NULL,
                    size INTEGER NOT NULL DEFAULT 0, missing INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE albums(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE album_photos(album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE, added REAL NOT NULL, PRIMARY KEY(album_id, photo_id));
                """)
            for i in 1...5 { _ = try old.run("INSERT INTO photos(path, name, taken, added) VALUES (?, ?, ?, ?)", [.text("/x/\(i).jpg"), .text("\(i).jpg"), .double(Double(i * 100)), .double(1)]) }
            _ = try old.run("INSERT INTO albums(name, created) VALUES ('Trip', 1)")
            for i in [1, 2, 3] { _ = try old.run("INSERT INTO album_photos(album_id, photo_id, added) VALUES (1, ?, 1)", [.int(Int64(i))]) }
            old.userVersion = 1
        } catch { check("build an old-format database", false, "\(error)"); lines.append("\(failures) FAILED"); return lines.joined(separator: "\n") + "\n" }

        do {
            let store = try PhotoStore(url: url)
            let first = try await store.ids(scope: .album(1), search: "", sort: .manual)
            check("an old album opens in the order it showed (newest taken first)", first == [3, 2, 1], "\(first)")
            let all = try await store.ids(scope: .all, search: "", sort: .takenNewest)
            check("the library itself is intact", all.count == 5, "\(all)")
            _ = try await store.add([5, 4], toAlbum: 1)
            let added = try await store.ids(scope: .album(1), search: "", sort: .manual)
            check("photos added later go to the end, in the order given", added == [3, 2, 1, 5, 4], "\(added)")
            _ = try await store.add([5], toAlbum: 1)
            check("adding one twice changes nothing", try await store.ids(scope: .album(1), search: "", sort: .manual) == added)
            try await store.setAlbumOrder(1, ordered: PhotoOrder.moved(added, moving: [4], .start))
            let moved = try await store.ids(scope: .album(1), search: "", sort: .manual)
            check("a saved order comes back as saved", moved == [4, 3, 2, 1, 5], "\(moved)")
            let other = try await store.ids(scope: .all, search: "", sort: .manual)
            check("outside an album the custom order falls back to date", other == all, "\(other)")
        } catch { check("open and use the upgraded database", false, "\(error)") }
        do {
            let reopened = try PhotoStore(url: url)
            let again = try await reopened.ids(scope: .album(1), search: "", sort: .manual)
            check("the upgrade is not repeated and the order survives a restart", again == [4, 3, 2, 1, 5], "\(again)")
        } catch { check("reopen the database", false, "\(error)") }
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
