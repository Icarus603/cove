//
//  NoteTextInput.swift
//  boringNotch
//
//  Writing a note in the notch. As for the search field (see NotchTextInput), the notch window can never take the keyboard, so the
//  writing area in it is a look-alike: clicking it opens a panel exactly over it, with a real multi-line text view, that can take the
//  keyboard without activating the app. What is typed is passed back as it changes. Escape or a click anywhere else ends it, keeping
//  what was written; the notch is kept open while the panel is up.
//

import AppKit
import SwiftUI

@MainActor
final class NoteTextInputController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = NoteTextInputController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var textView: NSTextView?
    private var currentNoteID: UUID?
    private var savedSelections: [UUID: NSRange] = [:]
    private var onChange: ((String) -> Void)?
    private var onEnd: (() -> Void)?
    private var holdsInteraction = false
    private weak var anchor: AnchorBox?
    private var monitors: [Any] = []

    var isEditing: Bool { panel != nil }

    func begin(over rect: NSRect, noteID: UUID? = nil, text: String, onChange: @escaping (String) -> Void, onEnd: @escaping () -> Void, anchor: AnchorBox? = nil) {
        end()
        self.currentNoteID = noteID
        self.anchor = anchor
        self.onChange = onChange
        self.onEnd = onEnd

        let panel = Panel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 5
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let background = NSView(frame: NSRect(origin: .zero, size: rect.size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        // A quiet outline, not the system accent: the notch has its own look, and the user may have picked their own colour.
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        background.layer?.borderWidth = 1

        let scroll = NSScrollView(frame: background.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .systemFont(ofSize: 12)
        view.textColor = .white
        view.insertionPointColor = .white
        view.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.28), .foregroundColor: NSColor.white]
        view.string = text
        view.delegate = self
        scroll.documentView = view
        background.addSubview(scroll)
        panel.contentView = background

        self.panel = panel
        self.textView = view
        SharingStateManager.shared.beginInteraction()
        holdsInteraction = true
        // Taking the keyboard makes Cove the active app, and over a full-screen app macOS answers by sliding the hidden menu bar
        // down for an instant. Keeping it hidden for the time the panel is up stops that flash.
        KeyboardPresentation.acquire(self)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        installMonitors()
        let textLength = (view.string as NSString).length
        let initialRange: NSRange
        if let noteID, let saved = savedSelections[noteID] {
            let loc = min(max(saved.location, 0), textLength)
            let len = min(max(saved.length, 0), textLength - loc)
            initialRange = NSRange(location: loc, length: len)
        } else {
            initialRange = NSRange(location: textLength, length: 0)
        }
        view.setSelectedRange(initialRange)
        view.scrollRangeToVisible(initialRange)
    }

    /// Closes the panel, keeping what was written.
    func end() {
        guard let panel else { return }
        if let noteID = currentNoteID, let textView {
            savedSelections[noteID] = textView.selectedRange()
        }
        let endHandler = onEnd
        self.panel = nil; self.textView = nil; self.currentNoteID = nil; self.onChange = nil; self.onEnd = nil
        panel.delegate = nil
        panel.orderOut(nil)
        removeMonitors()
        anchor = nil
        KeyboardPresentation.release(self)
        if holdsInteraction { holdsInteraction = false; SharingStateManager.shared.endInteraction() }
        endHandler?()
    }

    /// Ends writing if the panel belongs to this area (which has just left the screen).
    func end(ifAnchoredTo box: AnchorBox) {
        if anchor === box { end() }
    }

    /// The panel never loses the keyboard when the notch (which cannot take it) or another app is clicked, so a click anywhere
    /// outside the panel is what ends writing.
    private func installMonitors() {
        removeMonitors()
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            Task { @MainActor in self?.end() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            if let self, let panel = self.panel, event.window !== panel { self.end() }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onChange?(textView?.string ?? "")
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { end(); return true }
        return false
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) { end() }
}
