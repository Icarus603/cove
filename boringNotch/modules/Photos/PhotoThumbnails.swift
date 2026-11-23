//
//  PhotoThumbnails.swift
//  boringNotch
//
//  Small pictures for the grid. Made the first time a photo is shown (not when it is added, so adding stays quick), kept
//  on disk so they are never made twice, and in memory while in use. At most a few are made at once.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Lets only a few jobs run at a time.
private actor Gate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

final class PhotoThumbnails: @unchecked Sendable {
    /// The long side, in pixels. Enough for a 180 pt cell on a retina display.
    static let maxPixel = 360

    private let directory: URL
    private let memory = NSCache<NSNumber, NSImage>()
    private let gate = Gate(limit: 4)

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 1500
    }

    private func file(for id: Int64) -> URL {
        directory.appendingPathComponent("\(id % 256)", isDirectory: true).appendingPathComponent("\(id).jpg")
    }

    func cached(_ id: Int64) -> NSImage? { memory.object(forKey: NSNumber(value: id)) }

    /// The thumbnail of a photo: from memory, from disk, or made now. nil when the file cannot be read.
    func thumbnail(id: Int64, url: URL) async -> NSImage? {
        if let image = cached(id) { return image }
        await gate.enter()
        defer { Task { await gate.leave() } }
        if Task.isCancelled { return nil }
        let path = file(for: id)
        if let image = NSImage(contentsOf: path) {
            memory.setObject(image, forKey: NSNumber(value: id))
            return image
        }
        guard let image = Self.makeThumbnail(url: url, maxPixel: Self.maxPixel) else { return nil }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        memory.setObject(result, forKey: NSNumber(value: id))
        return result
    }

    /// Decodes a scaled-down copy straight from the file, with the orientation applied.
    static func makeThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    func remove(_ ids: [Int64]) {
        for id in ids {
            memory.removeObject(forKey: NSNumber(value: id))
            try? FileManager.default.removeItem(at: file(for: id))
        }
    }

    /// Disk space the thumbnails take.
    func diskSize() -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Throws them all away; they are made again when needed.
    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
