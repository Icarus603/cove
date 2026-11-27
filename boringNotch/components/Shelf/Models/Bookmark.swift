//
//  Bookmark.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-08.
//

import Foundation
import AppKit

struct Bookmark: Sendable, Equatable, Codable {
    private static let fallbackURLPrefix = "cove-file-url:"
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(url: URL) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Bookmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid file URL or file does not exist at \(url.path)"])
        }

        // Prefer security-scoped bookmarks, but fall back to standard/minimal bookmarks or raw URL
        // when non-sandboxed TCC restrictions deny `open()` during bookmark creation.
        if let bookmark = try? Self.makeBookmarkData(for: url, options: .withSecurityScope) {
            self.data = bookmark
        } else if let bookmark = try? Self.makeBookmarkData(for: url, options: []) {
            self.data = bookmark
        } else if let bookmark = try? Self.makeBookmarkData(for: url, options: .minimalBookmark) {
            self.data = bookmark
        } else {
            NSLog("⚠️ Falling back to raw file URL bookmark for \(url.path)")
            self.data = Data((Self.fallbackURLPrefix + url.absoluteString).utf8)
        }
    }

    private static func makeBookmarkData(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data {
        let bookmark = try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        NSLog("✅ Successfully created bookmark for \(url.path)")
        return bookmark
    }

    func resolve() -> (url: URL?, refreshedData: Data?) {
        guard !data.isEmpty else { return (nil, nil) }

        if let raw = String(data: data, encoding: .utf8), raw.hasPrefix(Self.fallbackURLPrefix) {
            let urlString = String(raw.dropFirst(Self.fallbackURLPrefix.count))
            return (URL(string: urlString), nil)
        }

        for resolveOptions: URL.BookmarkResolutionOptions in [[.withSecurityScope], []] {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: resolveOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    let createOptions: URL.BookmarkCreationOptions = resolveOptions.contains(.withSecurityScope) ? [.withSecurityScope] : []
                    if let newData = try? url.bookmarkData(options: createOptions) {
                        NSLog("⚠️ Bookmark was stale for \(url.path), refreshed")
                        return (url, newData)
                    }
                }
                return (url, nil)
            }
        }

        NSLog("❌ Failed to resolve bookmark")
        return (nil, nil)
    }

    func resolveURL() -> URL? {
        return resolve().url
    }

    var refreshedData: Data? {
        return resolve().refreshedData
    }
    
    static func update(in items: inout [ShelfItem], for item: ShelfItem, newBookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard case .file = items[idx].kind else { return }
        items[idx].kind = ShelfItemKind.file(bookmark: newBookmark)
    }

    func validate() async -> Bool {
        let (url, _) = resolve()
        guard let url = url else { return false }
        return url.accessSecurityScopedResource { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    func withAccess<T: Sendable>(_ block: @Sendable (URL) async throws -> T) async rethrows -> T? {
        let url = resolveURL()
        guard let url = url else { return nil }
        return try await url.accessSecurityScopedResource { url in
            try await block(url)
        }
    }

    func withAccess<T>(_ block: (URL) throws -> T) rethrows -> T? {
        let url = resolveURL()
        guard let url = url else { return nil }
        return try url.accessSecurityScopedResource { url in
            try block(url)
        }
    }
}
