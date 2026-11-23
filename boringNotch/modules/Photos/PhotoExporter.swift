//
//  PhotoExporter.swift
//  boringNotch
//
//  Writes an edited photo to a new file. The original is only ever read. The file keeps the original's format where it can
//  be written (JPEG, PNG, HEIC, TIFF) and its EXIF, with the orientation tag cleared because the pixels are already turned.
//

import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoExporter {
    enum ExportError: LocalizedError {
        case cannotRead
        case cannotEncode
        case notWritable(URL)

        var errorDescription: String? {
            switch self {
            case .cannotRead: return String(localized: "The original could not be read.")
            case .cannotEncode: return String(localized: "The edited picture could not be saved.")
            case .notWritable(let folder): return String(localized: "Cove cannot write to “\(folder.lastPathComponent)”.")
            }
        }
    }

    /// What the edited copy of a file is written as: the same type when ImageIO can write it, PNG otherwise (WebP, BMP).
    static func outputType(forExtension ext: String) -> (type: UTType, ext: String, lossy: Bool) {
        switch ext.lowercased() {
        case "jpg", "jpeg": return (.jpeg, ext.lowercased(), true)
        case "heic", "heif": return (.heic, ext.lowercased(), true)
        case "tif", "tiff": return (.tiff, ext.lowercased(), false)
        case "png": return (.png, "png", false)
        default: return (.png, "png", false)
        }
    }

    /// Animated GIFs are not edited: a copy would lose the animation without saying so.
    static func canEdit(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() != "gif" else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A name next to the original that does not exist yet: "Photo (edited).jpg", then "(edited 2)", "(edited 3)"…
    static func suggestedURL(for original: URL, in folder: URL? = nil) -> URL {
        let dir = folder ?? original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let ext = outputType(forExtension: original.pathExtension).ext
        let label = String(localized: "edited")
        var candidate = dir.appendingPathComponent("\(base) (\(label)).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(label) \(number)).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Renders the full-resolution picture with the edit and writes it. Throws before writing anything if the folder is
    /// not writable, so the caller can offer a Save panel instead.
    static func export(original: URL, params: EditParams, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw ExportError.notWritable(folder) }
        guard destination.standardizedFileURL != original.standardizedFileURL else { throw ExportError.cannotEncode }

        guard let ci = CIImage(contentsOf: original, options: [.applyOrientationProperty: true]) else { throw ExportError.cannotRead }
        let edited = EditPipeline.render(ci, params, applyCrop: true)
        let colorSpace = ci.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = EditPipeline.context.createCGImage(edited, from: edited.extent, format: .RGBA8, colorSpace: colorSpace) else { throw ExportError.cannotEncode }

        let target = outputType(forExtension: destination.pathExtension)
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, target.type.identifier as CFString, 1, nil) else { throw ExportError.cannotEncode }

        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
           var copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            // The pixels are already the right way up; the old orientation and size would turn them again.
            copied[kCGImagePropertyOrientation] = nil
            copied[kCGImagePropertyPixelWidth] = nil
            copied[kCGImagePropertyPixelHeight] = nil
            if var tiff = copied[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = nil; copied[kCGImagePropertyTIFFDictionary] = tiff }
            if var exif = copied[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = nil; exif[kCGImagePropertyExifPixelYDimension] = nil
                copied[kCGImagePropertyExifDictionary] = exif
            }
            properties = copied
        }
        if target.lossy { properties[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(sink, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.cannotEncode
        }
    }
}

extension PhotoEditSession {
    /// Saves a copy next to the original (or at `destination`), puts it in the library and in every album the original is in,
    /// and returns the new photo's id. The original file is never changed.
    func saveCopy(to destination: URL? = nil, library: PhotoLibrary = .shared) async throws -> (id: Int64, url: URL) {
        isSaving = true
        defer { isSaving = false }
        let original = photo.url
        let target = destination ?? PhotoExporter.suggestedURL(for: original)
        let edit = params
        try await Task.detached(priority: .userInitiated) { try PhotoExporter.export(original: original, params: edit, to: target) }.value

        await library.importURLs([target])
        guard let newID = await library.id(forPath: target.standardizedFileURL.resolvingSymlinksInPath().path) else { throw PhotoExporter.ExportError.cannotEncode }
        for album in await library.albumIDs(containing: photo.id) { await library.add([newID], toAlbum: album) }
        return (newID, target)
    }
}
