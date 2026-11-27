//
//  SettingsWindowController.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults
import Sparkle

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var updaterController: SPUStandardUpdaterController?
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdaterController(_ controller: SPUStandardUpdaterController) {
        self.updaterController = controller
        // Recreate the content view with the proper updater controller
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = ""
        // The title bar is the shared one (see ImmersiveChrome): the window buttons in the standard place, the page's own name
        // drawn by the page.
        MainActor.assumeIsolated { ImmersiveChrome.configure(window, toolbarIdentifier: "CoveSettingsToolbar") }
        // Not movable by its background: the sidebar's divider is dragged, and must not take the window with it.
        window.isMovableByWindowBackground = false
        
        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        // Configure window to be a standard document-style window
        // Position is set explicitly on every open (see `place`); a restored frame is how it ended up at the screen's corner.
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchSettingsWindow")
        
        // Create the SwiftUI content
        let settingsView = SettingsView(updaterController: updaterController)
        let hosting = NSHostingController(rootView: settingsView.coveAccent())
        // The window keeps its own size; a long page (Agents) scrolls inside it instead of stretching the window
        // to the content's full height, which ran off the bottom of the screen.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 700, height: 480)
        if window.frame.height < 520 || window.frame.width < 700 { window.setContentSize(NSSize(width: 700, height: 600)) }
        
        // Handle window closing
        window.delegate = self
    }
    
    /// The screen the pointer is on, else the main one.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Puts the window in the middle of the target screen's usable area, never taller or wider than it.
    /// `NSWindow.center()` is not used: right after ordering a window front its `screen` can still be nil, and then
    /// `center()` does nothing and the window stays at the origin, the bottom-left corner of the screen.
    private func place() {
        guard let window, let visible = targetScreen?.visibleFrame else { return }
        let width = min(window.frame.width, visible.width - 40)
        let height = min(window.frame.height, visible.height - 40)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2 + visible.height * 0.03, width: width, height: height)
        window.setFrame(frame, display: false)
    }

    /// True when most of the window is on some screen's usable area.
    private var isOnScreen: Bool {
        guard let window else { return false }
        return NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(window.frame)
            return !overlap.isNull && overlap.width * overlap.height > window.frame.width * window.frame.height * 0.6
        }
    }

    func showWindow() {
        // Set app to regular mode first
        AppActivation.windowOpened("settings")

        // If the window is already up, bring it forward; but one that has ended up off screen is put back first.
        if window?.isVisible == true {
            if !isOnScreen { place() }
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }

        // Opened afresh, the window is its usual size again, however big it was made last time (the window is only hidden when it is
        // closed, so it would otherwise keep that size until Cove quits).
        window?.setContentSize(NSSize(width: 700, height: 600))
        place()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)

        // Activate the app and ensure window gets focus
        NSApp.activate(ignoringOtherApps: true)

        // Force window to front after activation, and check once more where it landed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isOnScreen { self.place() }
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        
        // Back to accessory mode, unless another real window (the photo library) is still open
        AppActivation.windowClosed("settings")
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure app is in regular mode when window becomes key
        AppActivation.windowOpened("settings")
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
    
}
