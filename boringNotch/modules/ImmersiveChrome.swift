//
//  ImmersiveChrome.swift
//  boringNotch
//
//  The title bar of the windows that are mostly a picture (the photo window, the popped-out video). Built once and never changed
//  afterwards, so the window buttons are always in the one standard place: an empty toolbar gives the title bar the height of the
//  other Cove windows, and the bar is see-through so the picture can run to the top edge. Controls floating over the picture are
//  centred on the window buttons with `ImmersiveChrome.controlsTopInset`.
//
//  Full screen has no window buttons, and an empty toolbar would show there as a blank strip across the top, so it is hidden before
//  the window starts to grow. Hiding it moves the window buttons to the corner (measured: 19 pt becomes 9 pt), so they are made
//  invisible first and only shown again once the toolbar is back and they are in their one place. Nothing wrong is ever on screen.
//

import AppKit
import SwiftUI

@MainActor
enum ImmersiveChrome {
    /// Space above a 28 pt control (ToolbarMetrics.height) so that it is level with the window buttons.
    static let controlsTopInset: CGFloat = 9
    /// The band along the top that the title bar owns (measured: the content starts 66 pt down). A press in it is the window's to take,
    /// to drag the window by, so anything that is dragged (the crop box) must stay below it.
    static let titleBarBand: CGFloat = 66
    /// Space to leave at the left, for the window buttons, in front of anything that starts at the left edge.
    static let leadingInsetForButtons: CGFloat = 86

    /// Call once when the window is made.
    static func configure(_ window: NSWindow, toolbarIdentifier: String) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: Full screen (call from the window delegate)

    static func willEnterFullScreen(_ window: NSWindow?) {
        setButtonsVisible(false, in: window)
        window?.toolbar?.isVisible = false
    }

    static func willExitFullScreen(_ window: NSWindow?) {
        // The system hands the buttons back to the window as it starts to shrink; they are made invisible again from the first
        // moment (and again a turn and a moment later, in case it hands them over late).
        setButtonsVisible(false, in: window)
        window?.toolbar?.isVisible = true
        DispatchQueue.main.async { setButtonsVisible(false, in: window) }
        for delay in [0.05, 0.15, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { setButtonsVisible(false, in: window) } }
    }

    static func didExitFullScreen(_ window: NSWindow?) {
        window?.toolbar?.isVisible = true
        restoreToolbar(window)
        // One turn later, when the title bar has laid itself out.
        DispatchQueue.main.async {
            restoreToolbar(window)
            setButtonsVisible(true, in: window)
        }
    }

    private static func setButtonsVisible(_ visible: Bool, in window: NSWindow?) {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = visible ? 1 : 0
        }
    }

    private static func restoreToolbar(_ window: NSWindow?) {
        guard let window, let toolbar = window.toolbar else { return }
        window.toolbar = nil
        window.toolbar = toolbar
        toolbar.isVisible = true
        window.toolbarStyle = .unified
    }
}
