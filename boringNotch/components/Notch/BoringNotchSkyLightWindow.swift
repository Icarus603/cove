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
    private var savedPresentation: NSApplication.PresentationOptions?
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
        if !NSMenu.menuBarVisible(), savedPresentation == nil {
            savedPresentation = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if let contentView, firstResponder == nil || firstResponder === self {
            makeFirstResponder(contentView)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppDelegate.current?.handleNotchKeyDown(event) == nil {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if AppDelegate.current?.handleNotchKeyDown(event) == nil {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let delegate = AppDelegate.current,
           delegate.isAnyNotchOpen,
           !NoteTextInputController.shared.isEditing,
           !NotchTextInputController.shared.isEditing {
            delegate.closeNotchEverywhere()
        }
    }

    func endKeyInput(deactivateIfPossible: Bool = true) {
        allowKeyInput = false
        if !NoteTextInputController.shared.isEditing,
           !NotchTextInputController.shared.isEditing,
           let saved = savedPresentation {
            NSApp.presentationOptions = saved
            savedPresentation = nil
        }
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
        if !NoteTextInputController.shared.isEditing,
           !NotchTextInputController.shared.isEditing,
           let saved = savedPresentation {
            NSApp.presentationOptions = saved
            savedPresentation = nil
        }
    }
}
