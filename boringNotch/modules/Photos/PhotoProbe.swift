//
//  PhotoProbe.swift
//  boringNotch
//
//  What the library reads from an image file with the system's image framework: whether it can be shown, its size as it
//  is displayed (orientation applied), and when it was taken. Reading only the header, not decoding the picture, so
//  adding thousands of photos is quick.
//

import AppKit
import ImageIO

struct PhotoMetadata {
    var width: Int
    var height: Int
    var taken: Date
    var size: Int64
}

enum PhotoProbe {
    /// nil when the file is not an image the system can read.
    static func read(_ url: URL) -> PhotoMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5...8 are turned a quarter: what is shown is the other way round.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5, orientation <= 8 { swap(&width, &height) }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let taken = text.flatMap(parseExifDate) ?? values?.creationDate ?? values?.contentModificationDate ?? Date()
        return PhotoMetadata(width: width, height: height, taken: taken, size: Int64(values?.fileSize ?? 0))
    }

    /// "2019:05:01 14:30:05". The camera's clock has no time zone; the local one is assumed.
    static func parseExifDate(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 6, parts[0] > 1800, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }   // "0000:00:00" is "unknown"
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        components.hour = parts[3]; components.minute = parts[4]; components.second = parts[5]
        return Calendar.current.date(from: components)
    }
}
