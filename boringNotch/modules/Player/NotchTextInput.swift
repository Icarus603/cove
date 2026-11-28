//
//  NotchTextInput.swift
//  boringNotch
//
//  Typing inside the notch. The notch window can never become the key window (that is what keeps it from stealing focus),
//  so a text field placed in it cannot receive keystrokes. Instead the field in the notch is a look-alike: clicking it
//  opens a small panel exactly over it that can take the keyboard without activating the app, as Spotlight does, and what
//  is typed is passed back as it changes. The notch is kept open while the panel is up.
//

import AppKit
import SwiftUI

/// Holds the NSView a SwiftUI field sits on, so its place on screen can be worked out when it is clicked.
final class AnchorBox {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// A field that looks like a text field in the notch and types through `NotchTextInputController`.
struct NotchTextField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var symbol: String? = "magnifyingglass"
    var onCommit: (() -> Void)? = nil

    @State private var box = AnchorBox()

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            Group {
                if text.isEmpty { Text(placeholder).foregroundStyle(.secondary) } else { Text(text).foregroundStyle(.white) }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            Spacer(minLength: 0)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(AnchorView(box: box))
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.1)))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let rect = box.screenRect else { return }
            NotchTextInputController.shared.begin(over: rect, text: text, placeholder: placeholder, symbol: symbol,
                                                  onChange: { text = $0 }, onCommit: { onCommit?() }, anchor: box)
        }
        // Switching tab or closing the notch removes the field; the typing panel must go with it.
        .onDisappear { NotchTextInputController.shared.end(ifAnchoredTo: box) }
    }
}

@MainActor
final class NotchTextInputController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = NotchTextInputController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    /// For tests, which send key events to the panel directly.
    var debugPanel: NSPanel? { panel }
    var isEditing: Bool { panel != nil }
    private var field: NSTextField?
    private var onChange: ((String) -> Void)?
    private var onCommit: (() -> Void)?
    private var holdsInteraction = false
    private weak var anchor: AnchorBox?
    private var monitors: [Any] = []

    func begin(over rect: NSRect, text: String, placeholder: LocalizedStringKey, symbol: String?,
               onChange: @escaping (String) -> Void, onCommit: @escaping () -> Void, anchor: AnchorBox? = nil) {
        end(commit: false)
        self.anchor = anchor
        self.onChange = onChange
        self.onCommit = onCommit

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
        background.layer?.cornerRadius = 7
        background.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        // A quiet outline, not the system accent: the notch has its own look, and the user may have picked their own colour.
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        background.layer?.borderWidth = 1

        let field = NSTextField(frame: NSRect(x: 8, y: 0, width: rect.width - 16, height: rect.height))
        let cell = CenteredTextFieldCell(textCell: "")
        cell.isEditable = true
        cell.isScrollable = true
        cell.lineBreakMode = .byClipping
        field.cell = cell
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = .systemFont(ofSize: 11)
        field.stringValue = text
        field.delegate = self
        background.addSubview(field)
        panel.contentView = background

        self.panel = panel
        self.field = field
        SharingStateManager.shared.beginInteraction()
        holdsInteraction = true
        // Taking the keyboard makes Cove the active app, and over a full-screen app macOS answers by sliding the hidden menu
        // bar down for an instant. Keeping it hidden for the time the panel is up stops that flash.
        KeyboardPresentation.acquire(self)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        installMonitors()
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = .white
            editor.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.28), .foregroundColor: NSColor.white]
            editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
    }

    /// Closes the panel. `commit` is true for Return, false for Escape or when it lost the keyboard.
    func end(commit: Bool) {
        guard let panel else { return }
        let commitHandler = onCommit
        self.panel = nil; self.field = nil; self.onChange = nil; self.onCommit = nil
        panel.delegate = nil
        panel.orderOut(nil)
        removeMonitors()
        anchor = nil
        KeyboardPresentation.release(self)
        if holdsInteraction { holdsInteraction = false; SharingStateManager.shared.endInteraction() }
        if commit { commitHandler?() }
    }

    /// Ends typing if the panel belongs to this field (which has just left the screen).
    func end(ifAnchoredTo box: AnchorBox) {
        if anchor === box { end(commit: false) }
    }

    /// The panel never loses the keyboard when the notch (which cannot take it) or another app is clicked, so a click
    /// anywhere outside the panel is what ends typing.
    private func installMonitors() {
        removeMonitors()
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            Task { @MainActor in self?.end(commit: false) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            if let self, let panel = self.panel, event.window !== panel { self.end(commit: false) }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field?.stringValue ?? "")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { end(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { end(commit: false); return true }
        return false
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // A click elsewhere ends typing, keeping what was typed.
        end(commit: false)
    }
}


/// A text field cell that keeps its text, and the caret while editing, in the vertical middle of the field. The stock cell
/// draws at the top of any space taller than the text, which left the caret riding high in the notch's search box.
private final class CenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let height = cellSize(forBounds: rect).height
        return NSRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: rect.width, height: height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: centered(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
