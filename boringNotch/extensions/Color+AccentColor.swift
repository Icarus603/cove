//
//  Color+AccentColor.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-24.
//

import SwiftUI
import Defaults

extension Color {
    /// Cove azure, the app's own accent when the user has not picked a custom colour.
    static let coveAccent = Color(red: 0.29, green: 0.37, blue: 0.91)
    /// A soft amber for "file missing" and similar warnings: noticeable without shouting like system orange.
    static let coveWarning = Color(red: 0.91, green: 0.66, blue: 0.33)

    static var effectiveAccent: Color {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return Color(nsColor: nsColor)
        }
        return Color.coveAccent
    }
    
    /// Returns a darker version of the accent color suitable for backgrounds
    static var effectiveAccentBackground: Color {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return Color(nsColor: nsColor.withSystemEffect(.disabled))
        }
        return Color.effectiveAccent.opacity(0.25)
    }
}

extension NSColor {
    static let coveAccent = NSColor(srgbRed: 0.29, green: 0.37, blue: 0.91, alpha: 1)

    static var effectiveAccent: NSColor {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return nsColor
        }
        return NSColor.coveAccent
    }
    
    /// Returns a darker version of the accent color as NSColor suitable for backgrounds
    static var effectiveAccentBackground: NSColor {
        if Defaults[.useCustomAccentColor],
           let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return nsColor.withSystemEffect(.disabled)
        }
        return NSColor.coveAccent.withAlphaComponent(0.25)
    }
}


// MARK: - One place for the accent

extension View {
    /// Put on the root of every window and panel. Everything inside that follows the system tint (buttons, toggles, sliders,
    /// pickers, progress bars, focus rings, selected rows) then follows Cove's accent: the user's own colour when they chose
    /// one. A new window needs this one call and nothing else.
    func coveAccent() -> some View {
        self.tint(Color.effectiveAccent).accentColor(Color.effectiveAccent)
    }
}

// MARK: - Selected rows in tables and lists

/// A system table or list paints its selected rows in the system accent colour (blue), whatever the app's tint is. This draws
/// them in Cove's accent instead (the user's own when they chose one), so a selection looks like every other selected thing.
enum AccentSelection {
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let original = #selector(NSTableRowView.drawSelection(in:))
        let replacement = #selector(NSTableRowView.cove_drawSelection(in:))
        guard let a = class_getInstanceMethod(NSTableRowView.self, original),
              let b = class_getInstanceMethod(NSTableRowView.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSTableRowView {
    @objc func cove_drawSelection(in dirtyRect: NSRect) {
        // A source list (the sidebar style) keeps its own, softer selection; only the plain row highlight is replaced.
        guard selectionHighlightStyle != .none else { return }
        let accent = NSColor.effectiveAccent
        (isEmphasized ? accent : accent.withAlphaComponent(0.45)).setFill()
        bounds.fill()
    }
}
