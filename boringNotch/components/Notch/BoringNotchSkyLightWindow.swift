//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    weak var notchViewModel: BoringViewModel?
    var allowKeyInput: Bool = false

    override var canBecomeKey: Bool { allowKeyInput }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseDown,
           contentView?.acceptsFirstResponder == true {
            // Clicking inside an automatically popped-up Agent alert must not pin it open.
            let insideAutoAgentAlert = AppModules.isOpenedForAttention
                && BoringViewCoordinator.shared.currentView.id == AppModules.agents.id
            if !insideAutoAgentAlert {
                notchViewModel?.isPinnedOpen = true
            }
            if !isKeyWindow,
               !NoteTextInputController.shared.isEditing,
               !NotchTextInputController.shared.isEditing {
                beginKeyInput()
            }
        }
    }

    func beginKeyInput() {
        allowKeyInput = true
        KeyboardPresentation.acquire(self)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if let contentView, firstResponder == nil || firstResponder === self {
            makeFirstResponder(contentView)
        }
    }

    func endKeyInput(deactivateIfPossible: Bool = true) {
        allowKeyInput = false
        KeyboardPresentation.release(self)
        if isKeyWindow {
            resignKey()
        }
        if deactivateIfPossible,
           NSApp.isActive,
           !AppActivation.hasOpenWindows,
           !NoteTextInputController.shared.isEditing,
           !NotchTextInputController.shared.isEditing {
            NSApp.deactivate()
        }
    }

    override func resignKey() {
        super.resignKey()
        allowKeyInput = false
        KeyboardPresentation.release(self)
    }
}

/// Hides the Dock and menu bar while Cove holds the keyboard over a full-screen app, so activating Cove does not make macOS slide
/// the menu bar down for an instant. The notch window and both text panels need it at the same time, so it is shared and counted:
/// the original options are saved by the first holder and restored only when the last one lets go.
@MainActor
enum KeyboardPresentation {
    private static var holders: Set<ObjectIdentifier> = []
    private static var saved: NSApplication.PresentationOptions?

    static func acquire(_ owner: AnyObject) {
        if holders.isEmpty, !NSMenu.menuBarVisible() {
            saved = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        holders.insert(ObjectIdentifier(owner))
    }

    static func release(_ owner: AnyObject) {
        guard holders.remove(ObjectIdentifier(owner)) != nil, holders.isEmpty, let saved else { return }
        NSApp.presentationOptions = saved
        self.saved = nil
    }
}
