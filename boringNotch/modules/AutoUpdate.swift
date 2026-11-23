//
//  AutoUpdate.swift
//  boringNotch
//
//  Makes automatic updates actually automatic for an app that never quits.
//
//  Sparkle's silent update downloads the new version and then installs it "when the app quits". Cove lives in the menu bar
//  and is almost never quit, so a downloaded update just sat there: the app looked as though it did not update by itself.
//  Sparkle's answer for background apps is this delegate method: it is told an update is ready and hands over a block that
//  installs it and relaunches straight away. The install waits for a quiet moment so it never interrupts anything.
//

import AppKit
import Sparkle

final class AutoUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AutoUpdater()

    /// Longest an update waits for a quiet moment before it is installed anyway.
    private let longestWait: TimeInterval = 6 * 3600

    private var install: (() -> Void)?
    private var waitingSince = Date()
    private var timer: Timer?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async { [self] in
            install = immediateInstallHandler
            waitingSince = Date()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.installIfQuiet() }
            installIfQuiet()
        }
        return true   // we take it from here; Sparkle would otherwise wait for a quit that never comes
    }

    private func installIfQuiet() {
        guard let handler = install else { return }
        guard isQuiet || Date().timeIntervalSince(waitingSince) > longestWait else { return }
        timer?.invalidate(); timer = nil
        install = nil
        handler()   // installs and relaunches without showing anything
    }

    /// Nothing is in use: the notch is closed, Settings is not open, and no agent is waiting for an answer.
    private var isQuiet: Bool {
        MainActor.assumeIsolated {
            let notchOpen = AppDelegate.current?.isAnyNotchOpen ?? false
            let settingsOpen = SettingsWindowController.shared.window?.isVisible == true
            let needsAnswer = AppModules.registry.topAttention?.level == .needsInput
            return !notchOpen && !settingsOpen && !needsAnswer
        }
    }
}
