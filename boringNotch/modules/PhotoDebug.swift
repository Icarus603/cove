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

extension PhotoChecks {
    /// The photo editor, checked on pixels and files: turning, flipping, cropping, the direction of every adjustment, the crop
    /// box, and saving a copy without touching the original.
    static func editing() async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cove-edit-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appendingPathComponent("locked").path) }

        // A 200 x 100 picture in four colours: red top left, green top right, blue bottom left, yellow bottom right.
        func quadrants() -> CIImage {
            func block(_ c: CIColor, _ x: CGFloat, _ y: CGFloat) -> CIImage {
                CIImage(color: c).cropped(to: CGRect(x: x, y: y, width: 100, height: 50))
            }
            return block(CIColor(red: 1, green: 0, blue: 0), 0, 50)
                .composited(over: block(CIColor(red: 0, green: 1, blue: 0), 100, 50))
                .composited(over: block(CIColor(red: 0, green: 0, blue: 1), 0, 0))
                .composited(over: block(CIColor(red: 1, green: 1, blue: 0), 100, 0))
                .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let cg = EditPipeline.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { return (-1, -1, -1, -1) }
            var data = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))   // x, y from the top left
            return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
        }
        func isColor(_ p: (r: Int, g: Int, b: Int, a: Int), _ r: Int, _ g: Int, _ b: Int) -> Bool { abs(p.r - r) < 12 && abs(p.g - g) < 12 && abs(p.b - b) < 12 }
        let src = quadrants()

        // ---- geometry
        var p = EditParams()
        var out = EditPipeline.render(src, p, applyCrop: true)
        check("no edit leaves the picture as it was", out.extent.size == CGSize(width: 200, height: 100) && isColor(pixel(out, 5, 5), 255, 0, 0) && isColor(pixel(out, 195, 95), 255, 255, 0))
        p.quarterTurns = 1
        out = EditPipeline.render(src, p, applyCrop: true)
        check("a clockwise quarter turn swaps width and height", out.extent.size == CGSize(width: 100, height: 200), "\(out.extent.size)")
        check("clockwise: the old bottom left (blue) is now top left", isColor(pixel(out, 5, 5), 0, 0, 255))
        check("clockwise: the old top left (red) is now top right", isColor(pixel(out, 95, 5), 255, 0, 0))
        p.quarterTurns = 3
        out = EditPipeline.render(src, p, applyCrop: true)
        check("anticlockwise: the old top right (green) is now top left", isColor(pixel(out, 5, 5), 0, 255, 0))
        p.quarterTurns = 2
        out = EditPipeline.render(src, p, applyCrop: true)
        check("a half turn puts yellow top left", out.extent.size == CGSize(width: 200, height: 100) && isColor(pixel(out, 5, 5), 255, 255, 0))
        p = EditParams(); p.flipped = true
        out = EditPipeline.render(src, p, applyCrop: true)
        check("flip mirrors left to right (green top left, red top right)", isColor(pixel(out, 5, 5), 0, 255, 0) && isColor(pixel(out, 195, 5), 255, 0, 0))
        p = EditParams(); p.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        out = EditPipeline.render(src, p, applyCrop: true)
        check("a crop of the top right quarter is 100 x 50 and green", out.extent.size == CGSize(width: 100, height: 50) && isColor(pixel(out, 50, 25), 0, 255, 0), "\(out.extent.size)")
        out = EditPipeline.render(src, p, applyCrop: false)
        check("while cropping the whole picture is shown", out.extent.size == CGSize(width: 200, height: 100))
        p.quarterTurns = 1; p.crop = CGRect(x: 0, y: 0, width: 1, height: 0.5)   // the top half of the turned picture
        out = EditPipeline.render(src, p, applyCrop: true)
        check("the crop is of the turned picture (top half is blue left, red right)", out.extent.size == CGSize(width: 100, height: 100) && isColor(pixel(out, 5, 50), 0, 0, 255) && isColor(pixel(out, 95, 50), 255, 0, 0), "\(out.extent.size)")

        // ---- adjustments go the way they say
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let rose = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        func edit(_ image: CIImage, _ change: (inout EditParams) -> Void) -> (r: Int, g: Int, b: Int, a: Int) {
            var e = EditParams(); change(&e)
            return pixel(EditPipeline.render(image, e, applyCrop: true), 20, 20)
        }
        let base = edit(grey) { _ in }
        check("brightness up lightens, down darkens", edit(grey) { $0.brightness = 0.6 }.g > base.g + 10 && edit(grey) { $0.brightness = -0.6 }.g < base.g - 10)
        let darkGrey = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        check("contrast up darkens a dark tone and down lifts it", edit(darkGrey) { $0.contrast = 0.8 }.g < edit(darkGrey) { _ in }.g && edit(darkGrey) { $0.contrast = -0.8 }.g > edit(darkGrey) { _ in }.g)
        let plain = edit(rose) { _ in }
        let grey0 = edit(rose) { $0.saturation = -1 }
        check("saturation at minimum is grey", abs(grey0.r - grey0.g) < 6 && abs(grey0.g - grey0.b) < 6, "\(grey0)")
        check("saturation up makes the colour stronger", edit(rose) { $0.saturation = 0.8 }.r - edit(rose) { $0.saturation = 0.8 }.g > plain.r - plain.g)
        let warm = edit(grey) { $0.warmth = 1 }, cool = edit(grey) { $0.warmth = -1 }
        check("warmth up adds red and removes blue", warm.r - warm.b > base.r - base.b + 8, "warm \(warm) base \(base)")
        check("warmth down adds blue and removes red", cool.b - cool.r > base.b - base.r + 8, "cool \(cool)")
        check("sharpness and auto enhance keep the size", EditPipeline.render(src, { var e = EditParams(); e.sharpness = 1; e.autoEnhance = true; return e }(), applyCrop: true).extent.size == CGSize(width: 200, height: 100))
        check("an unchanged edit says so, a changed one says so", EditParams().isUnchanged && !{ var e = EditParams(); e.warmth = 0.1; return e }().isUnchanged && !{ var e = EditParams(); e.flipped = true; return e }().isUnchanged)

        // ---- the crop box
        let bounds = CGSize(width: 1000, height: 600)
        let whole = CGRect(origin: .zero, size: bounds)
        check("fit: a 1:1 box is the largest centred square", CropGeometry.fit(aspect: 1, in: bounds) == CGRect(x: 200, y: 0, width: 600, height: 600))
        check("fit: a free box is the whole picture", CropGeometry.fit(aspect: nil, in: bounds) == whole)
        let tall = CropGeometry.fit(aspect: 9.0 / 16.0, in: bounds)
        check("fit: 9:16 is as tall as the picture", abs(tall.height - 600) < 0.01 && abs(tall.width / tall.height - 9.0 / 16.0) < 0.001)
        let moved = CropGeometry.drag(CGRect(x: 100, y: 100, width: 300, height: 200), handle: .move, by: CGSize(width: 5000, height: -5000), aspect: nil, in: bounds)
        check("moving stops at the edges and keeps the size", moved == CGRect(x: 700, y: 0, width: 300, height: 200), "\(moved)")
        let freeCorner = CropGeometry.drag(CGRect(x: 100, y: 100, width: 300, height: 200), handle: .bottomRight, by: CGSize(width: 60, height: 40), aspect: nil, in: bounds)
        check("a free corner grows by what it is dragged", freeCorner == CGRect(x: 100, y: 100, width: 360, height: 240), "\(freeCorner)")
        let squeezed = CropGeometry.drag(CGRect(x: 100, y: 100, width: 300, height: 200), handle: .topLeft, by: CGSize(width: 900, height: 900), aspect: nil, in: bounds)
        check("a box cannot be made smaller than the minimum", squeezed.width >= CropGeometry.minSide - 0.01 && squeezed.height >= CropGeometry.minSide - 0.01 && squeezed.maxX == 400 && squeezed.maxY == 300, "\(squeezed)")
        let outside = CropGeometry.drag(CGRect(x: 100, y: 100, width: 300, height: 200), handle: .right, by: CGSize(width: 9000, height: 0), aspect: nil, in: bounds)
        check("an edge stops at the picture's edge", outside.maxX == 1000 && outside.minX == 100, "\(outside)")
        for (name, handle) in [("top left", CropHandle.topLeft), ("top right", .topRight), ("bottom left", .bottomLeft), ("bottom right", .bottomRight), ("left", .left), ("right", .right), ("top", .top), ("bottom", .bottom)] {
            let start = CGRect(x: 300, y: 150, width: 400, height: 300)   // 4:3
            var allGood = true
            for t in [CGSize(width: 80, height: 30), CGSize(width: -120, height: -90), CGSize(width: 2000, height: 2000), CGSize(width: -2000, height: -2000), CGSize(width: 0, height: 0), CGSize(width: -40, height: 70)] {
                let r = CropGeometry.drag(start, handle: handle, by: t, aspect: 4.0 / 3.0, in: bounds)
                let inside = r.minX >= -0.01 && r.minY >= -0.01 && r.maxX <= bounds.width + 0.01 && r.maxY <= bounds.height + 0.01
                let keeps = abs(r.width / r.height - 4.0 / 3.0) < 0.005
                if !(inside && keeps && r.width > 0 && r.height > 0) { allGood = false; lines.append("  (\(name) \(t) -> \(r))") }
            }
            check("a 4:3 box dragged by its \(name) keeps its shape and stays inside", allGood)
        }
        check("the handles: a corner, an edge, the inside, and outside", {
            let box = CGRect(x: 100, y: 100, width: 200, height: 150)
            return CropOverlayProbe.handle(CGPoint(x: 102, y: 98), box) == .topLeft && CropOverlayProbe.handle(CGPoint(x: 200, y: 101), box) == .top
                && CropOverlayProbe.handle(CGPoint(x: 299, y: 175), box) == .right && CropOverlayProbe.handle(CGPoint(x: 200, y: 175), box) == .move
                && CropOverlayProbe.handle(CGPoint(x: 20, y: 20), box) == nil
        }())

        // ---- the session
        let photo = Photo(id: 1, path: work.appendingPathComponent("x.jpg").path, name: "x.jpg", width: 4000, height: 2000, taken: Date(), added: Date(), size: 1, isMissing: false)
        let session = await PhotoEditSession(photo: photo)
        await session.use(src); await session.settle()
        await MainActor.run {
            check("a session starts unchanged and without a shape", !session.hasChanges && session.shape == .free)
            session.choose(.ratio(16, 9))
        }
        await session.settle()
        await MainActor.run {
            let box = session.cropRect
            check("choosing 16:9 puts a 16:9 box on the picture", abs(box.width / box.height - 16.0 / 9.0) < 0.01 && session.hasChanges, "\(box)")
            check("the saved size follows the crop (full-size pixels)", abs(session.outputSize.width / session.outputSize.height - 16.0 / 9.0) < 0.01 && session.outputSize.width <= 4000, "\(session.outputSize)")
            check("a ratio lies the same way as the picture (this one is wide)", session.landscape && session.canTurnShape)
            session.setLandscape(false)
            let standing = session.cropRect
            check("Portrait stands the box up: 9:16 on the same picture", !session.landscape && abs(standing.width / standing.height - 9.0 / 16.0) < 0.01 && standing.height <= session.turnedSize.height + 0.01, "\(standing)")
            session.setLandscape(true)
            check("Landscape lays it down again", abs(session.cropRect.width / session.cropRect.height - 16.0 / 9.0) < 0.01)
            session.chooseCustom(width: 4, height: 5)
            check("a custom 4:5 stands up by itself", !session.landscape && abs(session.cropRect.width / session.cropRect.height - 0.8) < 0.01 && session.shape == .ratio(5, 4), "\(session.cropRect)")
            session.chooseCustom(width: 7, height: 3)
            check("a custom 7:3 lies down", session.landscape && abs(session.cropRect.width / session.cropRect.height - 7.0 / 3.0) < 0.01)
            session.chooseCustom(width: 0, height: 3)
            check("a custom ratio with a zero is ignored", session.shape == .ratio(7, 3))
            check("there are twelve shapes to choose from, free and original among them", CropShape.presets.count == 12 && CropShape.presets.contains(.ratio(21, 9)) && CropShape.presets.contains(.ratio(5, 4)))
            check("a button reads 4:3 lying and 3:4 standing", CropShape.ratio(4, 3).label(landscape: true) == "4:3" && CropShape.ratio(4, 3).label(landscape: false) == "3:4")
            session.rotate(clockwise: true)
            check("turning forgets the crop and swaps the output size", session.params.crop == nil && session.outputSize == CGSize(width: 2000, height: 4000), "\(session.outputSize)")
            session.flip()
            check("flipping is an edit", session.params.flipped && session.hasChanges)
            session.resetAll()
            check("reset all puts everything back", !session.hasChanges && session.shape == .free)
            // A shape chosen right after a turn must already see the turned proportions (no waiting for a render).
            session.rotate(clockwise: true); session.choose(.ratio(3, 2))   // the picture now stands, so 3:2 stands too
            let turnedBox = session.cropRect
            check("a shape chosen straight after a turn fits the turned picture", abs(turnedBox.width / turnedBox.height - 2.0 / 3.0) < 0.01 && turnedBox.width <= session.turnedSize.width + 0.01 && session.params.crop != nil, "\(turnedBox) in \(session.turnedSize)")
            session.resetAll()
        }

        // ---- saving a copy
        func jpeg(at url: URL, width: Int, height: Int, orientation: Int) -> Bool {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            guard let image = ctx.makeImage(), let sink = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(sink, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            return CGImageDestinationFinalize(sink)
        }
        func size(of url: URL) -> (w: Int, h: Int, orientation: Int?)? {
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
            return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0, props[kCGImagePropertyOrientation] as? Int)
        }
        let original = work.appendingPathComponent("holiday.jpg")
        check("make a test photo (300 x 200, stored sideways with orientation 6)", jpeg(at: original, width: 300, height: 200, orientation: 6))
        let before = try? Data(contentsOf: original)
        let target = PhotoExporter.suggestedURL(for: original)
        check("the suggested name is next to the original and new", target.deletingLastPathComponent().path == work.path && target.lastPathComponent.hasPrefix("holiday (") && target.pathExtension == "jpg", target.lastPathComponent)
        do {
            try PhotoExporter.export(original: original, params: EditParams(), to: target)
            let result = size(of: target)
            check("an edit with no changes still comes out the right way up (orientation applied, tag cleared)", result?.w == 200 && result?.h == 300 && (result?.orientation == nil || result?.orientation == 1), "\(String(describing: result))")
        } catch { check("export without changes", false, "\(error)") }
        check("the original file is byte for byte the same", (try? Data(contentsOf: original)) == before)
        let second = PhotoExporter.suggestedURL(for: original)
        check("a second copy gets its own name", second != target && second.lastPathComponent.contains("2"), second.lastPathComponent)
        do {
            var e = EditParams(); e.crop = CGRect(x: 0, y: 0, width: 1, height: 0.5); e.flipped = true; e.brightness = 0.2
            try PhotoExporter.export(original: original, params: e, to: second)
            let result = size(of: second)
            check("crop, flip and brightness save at the cropped size (200 x 150)", result?.w == 200 && result?.h == 150, "\(String(describing: result))")
        } catch { check("export with changes", false, "\(error)") }
        check("the original is still untouched after the second copy", (try? Data(contentsOf: original)) == before)
        do {
            try PhotoExporter.export(original: original, params: EditParams(), to: original)
            check("saving over the original is refused", false)
        } catch { check("saving over the original is refused", true) }

        let png = work.appendingPathComponent("logo.png")
        do {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
            let sink = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(sink, ctx.makeImage()!, nil); CGImageDestinationFinalize(sink)
            let copy = work.appendingPathComponent("logo copy.png")
            var e = EditParams(); e.quarterTurns = 1
            try PhotoExporter.export(original: png, params: e, to: copy)
            let back = CIImage(contentsOf: copy)!
            check("a PNG keeps its transparency", pixel(back, 1, 1).a == 0 && pixel(back, 20, 20).a == 255, "\(pixel(back, 1, 1))")
        } catch { check("export a PNG", false, "\(error)") }
        check("WebP and BMP are written as PNG, JPEG and HEIC stay as they are", PhotoExporter.outputType(forExtension: "webp").ext == "png" && PhotoExporter.outputType(forExtension: "bmp").ext == "png" && PhotoExporter.outputType(forExtension: "JPG").ext == "jpg" && PhotoExporter.outputType(forExtension: "heic").ext == "heic")
        check("an animated GIF and a missing file cannot be edited", !PhotoExporter.canEdit(work.appendingPathComponent("a.gif")) && !PhotoExporter.canEdit(work.appendingPathComponent("nothing.jpg")) && PhotoExporter.canEdit(original))
        let locked = work.appendingPathComponent("locked"); try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        do {
            try PhotoExporter.export(original: original, params: EditParams(), to: locked.appendingPathComponent("x.jpg"))
            check("a folder that cannot be written to is reported", false)
        } catch let error as PhotoExporter.ExportError {
            if case .notWritable = error { check("a folder that cannot be written to is reported", true) } else { check("a folder that cannot be written to is reported", false, "\(error)") }
        } catch { check("a folder that cannot be written to is reported", false, "\(error)") }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // ---- saving into the library, and into the albums the original is in
        let library = PhotoLibrary(directory: work.appendingPathComponent("lib"))
        await library.importURLs([original])
        let originalID = await library.ids(scope: .all).first
        let album = await library.createAlbum(named: "Holiday", with: originalID.map { [$0] } ?? [])
        if let originalID, let record = await library.photo(originalID), let album {
            let editor = await PhotoEditSession(photo: record)
            await MainActor.run { editor.params.flipped = true }
            do {
                let saved = try await editor.saveCopy(library: library)
                let inAlbum = await library.ids(scope: .album(album.id))
                check("the saved copy is in the library", await library.photo(saved.id) != nil && saved.url.deletingLastPathComponent().path == work.path, "\(saved.url.path) in \(work.path)")
                check("and in the album the original is in", inAlbum.contains(saved.id) && inAlbum.contains(originalID), "\(inAlbum)")
                check("the original is still there, unchanged", (try? Data(contentsOf: original)) == before)
            } catch { check("save a copy into the library", false, "\(error)") }
        } else { check("prepare the library for the save test", false) }

        // ---- the way in: the browser model opens the editor, and refuses what cannot be edited
        let gif = work.appendingPathComponent("anim.gif")
        try? fm.copyItem(at: original, to: gif)
        await library.importURLs([gif])
        let model = await MainActor.run { PhotoBrowserModel(library: library) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let originalID, let gifID = await library.id(forPath: gif.standardizedFileURL.resolvingSymlinksInPath().path) {
            await MainActor.run { model.edit(originalID) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let opened = await MainActor.run { (model.editing, model.viewing) }
            check("edit opens the editor on that photo (and the viewer under it)", opened.0 == originalID && opened.1 == originalID, "\(opened)")
            await MainActor.run { model.closeEditor() }
            check("closing the editor leaves the viewer open", await MainActor.run { model.editing == nil && model.viewing == originalID })
            await MainActor.run { model.closeViewer() }
            check("closing the viewer closes the editor too", await MainActor.run { model.editing == nil && model.viewing == nil })
            await MainActor.run { model.edit(gifID) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            check("an animated GIF does not open the editor", await MainActor.run { model.editing == nil })
        } else { check("prepare the library for the entry checks", false) }

        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The editor's hit test, reachable from the checks.
enum CropOverlayProbe {
    static func handle(_ p: CGPoint, _ box: CGRect) -> CropHandle? { PhotoEditHitTest.handle(at: p, box: box) }
}
#endif
