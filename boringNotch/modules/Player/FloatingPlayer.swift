//
//  FloatingPlayer.swift
//  boringNotch
//
//  The video popped out of the notch into a window of its own: resizable, optionally above other windows, keeping the
//  video's shape, with keyboard control. Closing it (or "Back to the notch") puts the video back.
//

import AppKit
import Combine
import SwiftUI

final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FloatingPlayerController: NSObject, NSWindowDelegate {
    static let shared = FloatingPlayerController()

    private(set) var panel: PlayerPanel?
    private var observers: Set<AnyCancellable> = []

    func show() {
        if let panel {
            applyLevel(panel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = PlayerPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 405),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .black
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenPrimary, .managed]
        panel.minSize = NSSize(width: 320, height: 180)
        panel.contentView = NSHostingView(rootView: FloatingPlayerView().coveAccent())
        panel.delegate = self
        if !panel.setFrameUsingName("CovePlayerWindow") { panel.center() }
        panel.setFrameAutosaveName("CovePlayerWindow")
        applyLevel(panel)
        self.panel = panel

        // The title follows the video. The window's shape does not: it is as big and as wide or tall as the user makes it, and the
        // picture sits inside it with black bars (a window locked to the picture's shape could not be made taller than the screen's
        // width allowed).
        let engine = PlayerEngine.shared
        engine.$current.compactMap { $0?.title }.sink { [weak panel] title in panel?.title = title }.store(in: &observers)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        guard let panel else { return }
        // Out of full screen first (it takes a moment), then away.
        if panel.styleMask.contains(.fullScreen) {
            wantsHidden = true
            panel.toggleFullScreen(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    /// Set when the window is asked to go away while it is full screen: it leaves once the way out has finished.
    private var wantsHidden = false

    /// Enters or leaves full screen. The window may not be on screen yet when this is asked for (from the notch), so
    /// the request waits for it.
    func toggleFullScreen() {
        guard let panel, panel.isVisible else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.panel?.toggleFullScreen(nil)
            }
            return
        }
        panel.toggleFullScreen(nil)
    }

    private func applyLevel(_ panel: NSPanel) {
        panel.level = UserDefaults.standard.bool(forKey: PlayerSettingsKey.floatOnTop) ? .floating : .normal
    }

    // MARK: NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        // A floating level gets in the way of the full-screen Space.
        panel?.level = .normal
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        PlayerUI.shared.isFullScreen = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        PlayerUI.shared.isFullScreen = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        PlayerUI.shared.isFullScreen = false
        if let panel { applyLevel(panel) }
        if wantsHidden { wantsHidden = false; panel?.orderOut(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        // The close button: the video goes back to the notch and keeps playing.
        let ui = PlayerUI.shared
        ui.isFullScreen = false
        if ui.isPoppedOut { ui.isPoppedOut = false; if PlayerEngine.shared.current?.kind == .video { ui.mode = .video } }
    }
}

struct FloatingPlayerView: View {
    @ObservedObject private var engine = PlayerEngine.shared

    var body: some View {
        PlayerVideoView(engine: engine, showsBack: false, isFloating: true)
            .ignoresSafeArea()
            .onKeyPress { _ in PlayerUI.shared.pokeControls(); return .ignored }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) { engine.togglePlayPause(); return .handled }
            .onKeyPress(.leftArrow) { engine.skip(by: -5); return .handled }
            .onKeyPress(.rightArrow) { engine.skip(by: 5); return .handled }
            .onKeyPress(.upArrow) { engine.isMuted = false; engine.volume = min(engine.volume + 0.05, 1); return .handled }
            .onKeyPress(.downArrow) { engine.volume = max(engine.volume - 0.05, 0); return .handled }
            .onKeyPress("m") { engine.isMuted.toggle(); return .handled }
            .onKeyPress("f") { PlayerUI.shared.toggleFullScreen(); return .handled }
            .onKeyPress(.escape) {
                guard PlayerUI.shared.isFullScreen else { return .ignored }
                FloatingPlayerController.shared.toggleFullScreen()
                return .handled
            }
            .onKeyPress("n") { engine.next(); return .handled }
            .onKeyPress("p") { engine.previous(); return .handled }
    }
}
