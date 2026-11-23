//
//  WebsiteIconProvider.swift
//  boringNotch
//
//  When a browser is playing audio and the system gives no artwork, the closed notch shows the website's own icon
//  (YouTube's, Bilibili's, …) instead of the browser's.
//

import AppKit
import Foundation

enum WebsiteIconProvider {
    private enum Kind { case chromium, safari }

    /// Browsers whose tabs can be listed with AppleScript: bundle id → (application name, dialect).
    private static let browsers: [String: (name: String, kind: Kind)] = [
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.google.Chrome.beta": ("Google Chrome Beta", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "com.brave.Browser": ("Brave Browser", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.apple.Safari": ("Safari", .safari),
    ]

    static func isBrowser(_ bundleID: String?) -> Bool { bundleID.flatMap { browsers[$0] } != nil }

    // MARK: - Telling a browser's own logo from real artwork

    /// Chrome-family browsers hand the system their own logo as "artwork" when a page has none. This tells that logo from a
    /// real cover: the picture must be roughly square and close to the browser's own icon file.
    static func isBrowserLogo(_ artwork: Data, bundleID: String) -> Bool {
        let parent = bundleID.components(separatedBy: ".app.").first ?? bundleID
        guard browsers[parent] != nil || parent == "org.chromium.Chromium",
              let image = NSImage(data: artwork), image.size.width > 0, image.size.height > 0,
              abs(image.size.width / image.size.height - 1) < 0.06,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parent) else { return false }
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let icnsURL = resources.appendingPathComponent("app.icns")
        let reference = NSImage(contentsOf: icnsURL) ?? NSWorkspace.shared.icon(forFile: appURL.path)
        return averageDifference(image, reference) < 0.2
    }

    /// Mean per-channel difference (0…1) between two pictures shrunk to 24×24 on white.
    private static func averageDifference(_ a: NSImage, _ b: NSImage) -> Double {
        func pixels(_ image: NSImage) -> [Double] {
            let n = 24
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return [] }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: n, height: n).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            var out: [Double] = []
            for y in 0..<n { for x in 0..<n {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                out += [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
            } }
            return out
        }
        let p = pixels(a), q = pixels(b)
        guard !p.isEmpty, p.count == q.count else { return 1 }
        return zip(p, q).map { abs($0 - $1) }.reduce(0, +) / Double(p.count)
    }

    private static let queue = DispatchQueue(label: "app.cove.website-icon")
    private static var cache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    /// The icon of the site playing `title` in the browser, or nil when it cannot be found.
    static func icon(browserBundleID: String, playingTitle: String) async -> NSImage? {
        guard let browser = browsers[browserBundleID], !playingTitle.isEmpty,
              NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleID).first != nil,
              let pageURL = await tabURL(browser: browser, title: playingTitle),
              let host = pageURL.host
        else { return nil }

        if let cached = cacheLock.withLock({ cache[host] }) { return cached }
        guard let icon = await fetchIcon(for: pageURL) else { return nil }
        cacheLock.withLock { cache[host] = icon }
        return icon
    }

    // MARK: - Finding the playing tab

    private static func tabURL(browser: (name: String, kind: Kind), title: String) async -> URL? {
        let titleProperty = browser.kind == .safari ? "name" : "title"
        let source = """
        tell application "\(browser.name)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (\(titleProperty) of t) & "\\t" & (URL of t) & "\\n"
                end repeat
            end repeat
            return out
        end tell
        """
        let listing: String? = await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
        guard let listing else { return nil }
        let wanted = normalise(title)
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, normalise(parts[0]).contains(wanted), let url = URL(string: parts[1]),
                  url.scheme == "https" || url.scheme == "http" else { continue }
            return url
        }
        return nil
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Fetching the icon

    private static func fetchIcon(for pageURL: URL) async -> NSImage? {
        guard var root = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        root.path = "/"; root.query = nil; root.fragment = nil
        guard let home = root.url else { return nil }

        var candidates: [URL] = []
        if let html = await download(home, limit: 300_000).flatMap({ String(decoding: $0, as: UTF8.self) }) {
            candidates = iconLinks(in: html, base: home)
        }
        candidates.append(home.appendingPathComponent("favicon.ico"))

        var best: NSImage?
        for url in candidates.prefix(4) {
            guard let data = await download(url, limit: 2_000_000), let image = NSImage(data: data) else { continue }
            let size = max(image.size.width, image.size.height)
            if best == nil || size > max(best!.size.width, best!.size.height) { best = image }
            if size >= 120 { break }
        }
        return best.map(tile)
    }

    /// <link rel="…icon…" href="…"> targets, largest and touch icons first.
    private static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        var found: [(url: URL, score: Int)] = []
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let element = String(html[range])
            guard let rel = attribute("rel", in: element)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: element), let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            var score = rel.contains("apple-touch") ? 1000 : 0
            if let sizes = attribute("sizes", in: element), let first = sizes.split(separator: "x").first, let n = Int(first) { score += n }
            found.append((url, score))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    private static func attribute(_ name: String, in element: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)) else { return nil }
        for group in 1...2 { if let range = Range(match.range(at: group), in: element) { return String(element[range]) } }
        return nil
    }

    private static func download(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Cove", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, data.count <= limit
        else { return nil }
        return data
    }

    /// Small favicons are set on a light rounded tile so they do not look blurry when the notch scales them up.
    private static func tile(_ icon: NSImage) -> NSImage {
        let side: CGFloat = 256
        if max(icon.size.width, icon.size.height) >= 120 { return icon }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 56, yRadius: 56).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        let target = side * 0.56
        icon.draw(in: NSRect(x: (side - target) / 2, y: (side - target) / 2, width: target, height: target))
        image.unlockFocus()
        return image
    }
}
