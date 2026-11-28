//
//  AppDelegate+Keyboard.swift
//  boringNotch
//
//  Keyboard input for the open notch: taking and giving up key focus, the key monitor, quick note and click-outside.
//

import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import NotchKit
import SwiftUI

extension AppDelegate {
    func notchWindow(forScreenUUID uuid: String?) -> BoringNotchSkyLightWindow? {
        if Defaults[.showOnAllDisplays], let uuid, let win = windows[uuid] as? BoringNotchSkyLightWindow {
            return win
        }
        return window as? BoringNotchSkyLightWindow
    }

    func focusNotchWindowForKeyboard(screenUUID: String? = nil) {
        guard let skyWindow = notchWindow(forScreenUUID: screenUUID) ?? (window as? BoringNotchSkyLightWindow) else { return }
        skyWindow.beginKeyInput()
    }

    func resignNotchKeyInput(for screenUUID: String?) {
        notchWindow(forScreenUUID: screenUUID)?.endKeyInput()
    }

    func resignAllNotchKeyInputs() {
        (window as? BoringNotchSkyLightWindow)?.endKeyInput()
        for win in windows.values {
            (win as? BoringNotchSkyLightWindow)?.endKeyInput()
        }
    }

    @MainActor
    func openNotchForQuickNote() {
        guard !onboardingActive else { return }
        if AppModules.registry.disabledIDs.contains(NotesModule.moduleID) {
            AppModules.setEnabled(true, id: NotesModule.moduleID)
        }
        coordinator.currentView = NotchViews(id: NotesModule.moduleID)
        let target = targetScreenContext()
        target.viewModel.open(pinned: true)
        focusNotchWindowForKeyboard(screenUUID: target.viewModel.screenUUID)
        let note = NotesStore.shared.newNote()
        NotesStore.shared.pendingQuickNoteID = note.id
        NotificationCenter.default.post(name: .coveQuickNoteRequested, object: note.id)
    }

    func installNotchKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated {
                if let self { result = self.handleNotchKeyDown(event) }
            }
            return result
        }
    }

    @MainActor
    func handleNotchKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isAnyNotchOpen,
              NSApp.keyWindow is BoringNotchSkyLightWindow,
              !NoteTextInputController.shared.isEditing,
              !NotchTextInputController.shared.isEditing else {
            return event
        }
        let engine = PlayerEngine.shared
        let ui = PlayerUI.shared
        let modules = AppModules.registry.visibleModules
        let currentID = coordinator.currentView.id
        let isLiveVideo = engine.current?.kind == .video && !ui.isPoppedOut && engine.state != .stopped
        let context = NotchKeyContext(
            tabCount: modules.count,
            currentTabIndex: modules.firstIndex { $0.id == currentID },
            isPlayerTab: currentID == PlayerModule.moduleID,
            isPlayerFullScreen: ui.isFullScreen,
            hasCurrentMedia: engine.current != nil,
            hasQueue: !engine.queueOrder.isEmpty,
            showingVideo: ui.mode == .video && isLiveVideo,
            canShowVideo: isLiveVideo
        )
        var modifiers: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        let resolution = NotchKeyboard.resolve(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: modifiers, isRepeat: event.isARepeat, context: context)
        guard case .perform(let action) = resolution else { return event }

        switch action {
        case .closeNotch:
            closeNotchEverywhere()
        case .selectTab(let index):
            withAnimation(.smooth) { coordinator.currentView = NotchViews(id: modules[index].id) }
        case .player(let command):
            perform(command, engine: engine, ui: ui)
        }
        return nil
    }

    @MainActor
    func perform(_ command: PlayerKeyCommand, engine: PlayerEngine, ui: PlayerUI) {
        switch command {
        case .togglePlayPause:
            engine.togglePlayPause()
        case .playFirstVisible:
            if let first = ui.visibleItems.first { ui.play(first, in: ui.visibleItems) }
        case .skip(let seconds):
            engine.skip(by: seconds)
        case .volumeUp:
            engine.isMuted = false
            engine.volume = min(engine.volume + 0.05, 1)
        case .volumeDown:
            engine.volume = max(engine.volume - 0.05, 0)
        case .toggleMute:
            engine.isMuted.toggle()
        case .toggleFullScreen:
            ui.toggleFullScreen()
            return
        case .showVideo:
            ui.mode = .video
        case .next:
            engine.next()
        case .previous:
            engine.previous()
        case .none:
            return
        }
        ui.pokeControls()
    }

    func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideMouseClick()
            }
        }
    }

    @MainActor
    func handleOutsideMouseClick() {
        guard isAnyNotchOpen else { return }
        let openScreens = ([vm] + Array(viewModels.values)).filter { $0.notchState == .open }.map {
            NotchScreenState(
                isPinnedOpen: $0.isPinnedOpen, isPointerOver: $0.isMouseHovering(),
                isDropTargeted: $0.anyDropZoneTargeting, isPopoverActive: $0.isBatteryPopoverActive)
        }
        let isEditingText = NoteTextInputController.shared.isEditing || NotchTextInputController.shared.isEditing
        guard NotchKeyboard.shouldCloseOnOutsideClick(
            openScreens: openScreens, closeIsBlocked: SharingStateManager.shared.preventNotchClose,
            isEditingText: isEditingText) else { return }
        closeNotchEverywhere()
    }
}
