//
//  AppDelegate+DragDetection.swift
//  boringNotch
//
//  Watching for a drag that reaches the notch, so the Shelf can open under it.
//

import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import NotchKit
import SwiftUI

extension AppDelegate {
    func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    func setupDragDetectors() {
        cleanupDragDetectors()

        guard !onboardingActive, Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        guard !AppModules.registry.disabledIDs.contains(NotchViews.shelf.id) else { return }

        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            guard viewModel.notchState == .closed else { return }
            coordinator.currentView = .shelf
            viewModel.open()
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            guard vm.notchState == .closed else { return }
            coordinator.currentView = .shelf
            vm.open()
        }
    }
}
