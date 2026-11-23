//
//  MediaProbe.swift
//  boringNotch
//
//  Reads what the library needs from a file: whether the system can play it, its length, tags, cover art (or a frame of a
//  video), and whether it carries a picture track.
//

import AppKit
import AVFoundation

struct MediaProbeResult {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var kind: MediaKind
    /// JPEG data of the cover art or a video frame, already small.
    var thumbnail: Data?
}

enum MediaProbe {
    /// nil when the system cannot play the file.
    static func probe(_ url: URL) async -> MediaProbeResult? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        // A file with neither picture nor sound has nothing to play.
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { return nil }

        // Cover art sits on a track of its own in some containers; those are not "video".
        var isRealVideo = false
        for track in videoTracks {
            let frameRate = (try? await track.load(.nominalFrameRate)) ?? 0
            if frameRate > 1 || videoTracks.count > 1 || audioTracks.isEmpty { isRealVideo = true }
        }
        let kind: MediaKind = isRealVideo ? .video : .audio

        let metadata = ((try? await asset.load(.commonMetadata)) ?? []) + ((try? await asset.load(.metadata)) ?? [])
        func text(_ identifier: AVMetadataIdentifier) async -> String? {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
            }
            return nil
        }
        let title = await text(.commonIdentifierTitle) ?? url.deletingPathExtension().lastPathComponent
        let artist = await text(.commonIdentifierArtist) ?? ""
        let album = await text(.commonIdentifierAlbumName) ?? ""

        var thumbnail: Data?
        if kind == .audio {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
                if let data = try? await item.load(.dataValue), let jpeg = downscaledJPEG(from: data) { thumbnail = jpeg; break }
            }
        } else {
            thumbnail = await videoFrame(asset, duration: duration)
        }
        return MediaProbeResult(title: title, artist: artist, album: album, duration: duration.isFinite ? duration : 0,
                                kind: kind, thumbnail: thumbnail)
    }

    /// A frame a little way in, so it is not the black first frame.
    private static func videoFrame(_ asset: AVURLAsset, duration: TimeInterval) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let at = CMTime(seconds: min(max(duration * 0.1, 0.5), 10), preferredTimescale: 600)
        guard let image = try? await generator.image(at: at).image else { return nil }
        return downscaledJPEG(from: NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data())
    }

    /// At most 320 pt on the long side, as JPEG: enough for the list and the player, small to keep.
    static func downscaledJPEG(from data: Data, maxSide: CGFloat = 320) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
