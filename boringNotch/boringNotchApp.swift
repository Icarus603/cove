//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import NotchKit
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        // Debug builds do not run the updater: they share this app's preferences (and so its update schedule) with the
        // installed copy, and one would otherwise reset the installed copy's "last checked" time on every run.
        #if DEBUG
        let startUpdater = false
        #else
        let startUpdater = true
        #endif
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startUpdater, updaterDelegate: AutoUpdater.shared, userDriverDelegate: nil)
        // Sparkle's own schedule only checks once the interval has passed since the last check, so a release made a few
        // minutes after it was never picked up on launch. Check in the background at every launch too. With automatic
        // downloads on this is silent, and `AutoUpdater` then installs the update at the next quiet moment.
        if startUpdater { updaterController.updater.checkForUpdatesInBackground() }

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("Cove", image: "MenuBarCove", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Restart Cove") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApp.delegate` is SwiftUI's adaptor wrapper, so code outside the class reaches the real delegate here.
    static weak var current: AppDelegate?

    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var previousScreens: [NSScreen]?
    var onboardingWindowController: NSWindowController?
    /// While the first-run setup is on screen the notch stays out of the way: nothing is created or shown until it is done.
    private(set) var onboardingActive = false
    var screenLockedObserver: Any?
    var screenUnlockedObserver: Any?
    var isScreenLocked: Bool = false
    var windowScreenDidChangeObserver: Any?
    var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector
    var keyMonitor: Any?
    var outsideClickMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Opens the notch on every screen it is shown on, for requests that need the user (approvals).
    func openNotchEverywhere(pinned: Bool = false) {
        if onboardingActive { return }
        if Defaults[.showOnAllDisplays] {
            viewModels.values.forEach { $0.open(pinned: pinned) }
        } else {
            vm.open(pinned: pinned)
        }
    }

    func closeNotchEverywhere() {
        vm.close()
        viewModels.values.forEach { $0.close() }
        resignAllNotchKeyInputs()
    }

    func targetScreenContext() -> (viewModel: BoringViewModel, window: NSWindow?) {
        let mouseLocation = NSEvent.mouseLocation
        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
                if let uuid = screen.displayUUID, let screenViewModel = viewModels[uuid] {
                    return (screenViewModel, windows[uuid])
                }
            }
        }
        return (vm, window)
    }









    /// The pointer is over the notch window, so closing it would be rude.
    var isPointerOverNotch: Bool {
        let location = NSEvent.mouseLocation
        return NSApp.windows.contains { $0 is BoringNotchSkyLightWindow && $0.frame.contains(location) }
    }

    var isAnyNotchOpen: Bool {
        vm.notchState == .open || viewModels.values.contains { $0.notchState == .open }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModules.shutdown()
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        MusicManager.shared.destroy()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }


    
    










    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.current = self
        AccentSelection.install()
        // Agents must be listening for hooks from launch, not from the first time the notch opens.
        AppModules.bootstrap()
        installNotchKeyMonitor()
        installOutsideClickMonitor()
        #if DEBUG
        UISnapshot.runIfRequested()
        #endif

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.onboardingActive else { return }
                let target = self.targetScreenContext()
                switch target.viewModel.notchState {
                case .closed:
                    target.viewModel.open(pinned: true)
                    self.focusNotchWindowForKeyboard(screenUUID: target.viewModel.screenUUID)
                case .open:
                    target.viewModel.close()
                }
            }
        }

        if coordinator.firstLaunch {
            onboardingActive = true
            DispatchQueue.main.async { self.showOnboardingWindow() }
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            onboardingActive = true
            DispatchQueue.main.async { self.showOnboardingWindow(step: .musicPermission) }
        }

        if onboardingActive {
            // Nothing to build yet; `finishOnboarding()` brings the notch up.
        } else if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createBoringNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        previousScreens = NSScreen.screens
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }


    /// Called when the first-run setup closes: only now does the notch appear.
    func finishOnboarding() {
        guard onboardingActive else { return }
        onboardingActive = false
        adjustWindowPosition(changeAlpha: true)
        setupDragDetectors()
    }


    @objc func togglePopover(_ sender: Any?) {
        if onboardingActive { return }
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                        self.finishOnboarding()
                    },
                    onOpenSettings: {
                        window.close()
                        self.finishOnboarding()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
    static let coveQuickNoteRequested = Notification.Name("CoveQuickNoteRequested")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
