import AppKit
import CodeIslandCore
import Combine
import os.log
import SwiftUI

/// Owns the agent engine inside a host app: the hook socket, session discovery,
/// remote hosts and global shortcuts. It replaces CodeIsland's AppDelegate, so
/// the host provides the window (the notch) and this provides the behaviour.
///
/// Hooks install themselves for the tools found on this Mac. A backup of a tool's config is
/// taken before the first time its hooks are written, and switching a tool off in Settings
/// removes its hooks again.
@MainActor
public final class AgentRuntime: ObservableObject {
    public static let shared = AgentRuntime()
    nonisolated private static let log = Logger(subsystem: "com.notchhub.agenthub", category: "AgentRuntime")

    static let hooksOptInKey = "agenthub.hooksOptIn"

    let appState = AppState()
    /// CodeIsland's own panel window is never created here; kept so ported code compiles.
    var panelController: PanelWindowController?

    /// Another CodeIsland already serves the hook socket, so this runtime stays passive.
    @Published public private(set) var standingAside = false
    @Published public private(set) var hooksEnabled: Bool
    @Published public private(set) var started = false

    /// The host sets these so shortcuts can bring the notch up.
    public var presentHost: (() -> Void)?
    public var isHostOnScreen: () -> Bool = { true }

    private var hookServer: HookServer?
    private var hookRecoveryTimer: Timer?
    private var lastHookCheck: Date = .distantPast
    private var activationObserver: NSObjectProtocol?

    private init() {
        // On unless the user switched every hook off in Settings.
        let stored = UserDefaults.standard.object(forKey: Self.hooksOptInKey) as? Bool
        hooksEnabled = stored ?? true
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        if let problem = RuntimeEnvironment.isolationProblem(ProcessInfo.processInfo.environment) {
            Self.log.error("\(problem, privacy: .public): not starting")
            standingAside = true
            return
        }
        let isolated = RuntimeEnvironment.isIsolated
        // One island per hook socket: a second listener would take it from the first.
        if let other = HookSocketListener.islandListening(at: HookServer.socketPath) {
            Self.log.error("Another CodeIsland (pid \(other)) already serves the hook socket; staying passive")
            standingAside = true
            return
        }
        started = true

        // Listen before any hook is installed, or a permission hook gets no answer.
        HookSocketListener.raiseDescriptorLimit()
        let server = HookServer(appState: appState)
        hookServer = server
        HookSocketHealth.shared.start(server)
        RemoteManager.shared.onDisconnect = { [weak appState] hostId in
            appState?.removeRemoteSessions(hostId: hostId)
        }
        RemoteManager.shared.hookSockets = RemoteHookSockets(appState: appState)

        if !isolated {
            Task { @MainActor [weak appState] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                appState?.refreshClaudeUsageIfStale()
            }
        }

        MascotAnimationGate.shared.start()
        SceneMuteMonitor.shared.start()
        SceneMuteMonitor.shared.onQuietChanged = { [weak appState] isQuiet in
            if isQuiet { PushNotifier.shared.userLeft() } else { appState?.followUps.wake() }
        }
        appState.connectPushToFollowUps()

        if !isolated {
            appState.startSessionDiscovery()
            appState.startCodexAppServerWatcher()
            appState.startAiWorkWatcher()
            appState.startCoworkWatcher()
            RemoteManager.shared.startup()
        }

        ESP32StatePublisher.shared.attach(appState)
        ESP32BridgeManager.shared.onFocusRequest = { [weak appState] mascot in
            guard let appState else { return }
            ESP32FocusCoordinator.handle(mascot: mascot, appState: appState)
        }
        ESP32BridgeManager.shared.onControlCommand = { [weak appState] command in
            appState?.handleBuddyControlCommand(command)
        }
        AppleCompanionPublisher.shared.attach(appState)
        AppleCompanionPublisher.shared.onFocusRequest = { [weak appState] mascot in
            guard let appState else { return }
            ESP32FocusCoordinator.handle(mascot: mascot, appState: appState)
        }
        AppleCompanionPublisher.shared.onControlCommand = { [weak appState] command, sessionId in
            appState?.handleBuddyControlCommand(command, expectedSessionId: sessionId)
        }
        AppleCompanionPublisher.shared.onQuestionAnswer = { [weak appState] answer, sessionId in
            appState?.answerCompanionQuestion(answer, expectedSessionId: sessionId)
        }
        let defaults = UserDefaults.standard
        let beat = defaults.double(forKey: SettingsKey.esp32HeartbeatSeconds)
        let brightness = defaults.double(forKey: SettingsKey.buddyScreenBrightnessPercent)
        ESP32StatePublisher.shared.configure(
            enabled: defaults.bool(forKey: SettingsKey.esp32BridgeEnabled),
            heartbeatSeconds: beat > 0 ? beat : SettingsDefaults.esp32HeartbeatSeconds,
            brightnessPercent: brightness > 0 ? brightness : SettingsDefaults.buddyScreenBrightnessPercent,
            screenOrientation: BuddyScreenOrientation(settingsValue: defaults.string(forKey: SettingsKey.buddyScreenOrientation))
        )
        let companionBeat = defaults.double(forKey: SettingsKey.appleCompanionHeartbeatSeconds)
        AppleCompanionPublisher.shared.configure(
            enabled: defaults.bool(forKey: SettingsKey.appleCompanionEnabled),
            heartbeatSeconds: companionBeat > 0 ? companionBeat : SettingsDefaults.appleCompanionHeartbeatSeconds
        )

        if hooksEnabled && !isolated {
            installDetectedHooks()
            startHookRecovery()
        }
        SettingsWindowController.shared.appState = appState
    }

    public func stop() {
        guard started else { return }
        hookRecoveryTimer?.invalidate()
        hookRecoveryTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        appState.saveSessions()
        RemoteManager.shared.shutdown()
        hookServer?.stop()
        appState.stopCodexAppServerWatcher()
        appState.stopAiWorkWatcher()
        appState.stopSessionDiscovery()
        started = false
    }

    // MARK: - Hooks

    /// A tool whose hooks this app can manage.
    public struct AgentTool: Identifiable, Equatable, Sendable {
        public let id: String      // the bridge's --source value
        public let name: String
        /// The tool looks installed on this Mac.
        public let detected: Bool
        /// Its hooks are currently in place.
        public let installed: Bool
    }

    /// Bumped whenever hooks change, so settings views refresh.
    @Published public private(set) var toolsVersion = 0

    /// Every built-in tool, with whether it is on this Mac and whether its hooks are installed.
    public func tools() -> [AgentTool] {
        ConfigInstaller.allCLIs
            .filter { $0.extraConfigDir == nil }
            .map { AgentTool(id: $0.source, name: $0.name,
                             detected: ConfigInstaller.cliExists(source: $0.source),
                             installed: ConfigInstaller.isInstalled(source: $0.source)) }
    }

    /// Installs hooks for the tools found on this Mac, backing up their configs first.
    /// Runs at launch and is safe to repeat: tools that are already hooked are left alone.
    private func installDetectedHooks() {
        Task.detached(priority: .utility) { [weak self] in
            let pending = ConfigInstaller.allCLIs.filter {
                $0.extraConfigDir == nil && ConfigInstaller.isEnabled(source: $0.source)
                    && ConfigInstaller.cliExists(source: $0.source) && !ConfigInstaller.isInstalled(source: $0.source)
            }
            if !pending.isEmpty { HookConfigBackup.backupAll(clis: pending) }
            let ok = ConfigInstaller.install()
            Self.log.info("Hooks \(ok ? "installed" : "partly failed", privacy: .public) for \(pending.count) new tool(s)")
            await MainActor.run { self?.toolsVersion += 1 }
        }
    }

    /// Switches one tool's hooks on or off from Settings.
    public func setTool(_ source: String, enabled: Bool) async {
        if enabled, let cli = ConfigInstaller.allCLIs.first(where: { $0.source == source }) {
            HookConfigBackup.backupAll(clis: [cli])
        }
        _ = await Task.detached(priority: .userInitiated) {
            ConfigInstaller.setEnabled(source: source, enabled: enabled)
        }.value
        if enabled && !hooksEnabled { setHooksEnabled(true) }
        toolsVersion += 1
    }

    /// Removes every hook this app installed, and keeps them off until switched back on.
    public func removeAllHooks() async {
        hookRecoveryTimer?.invalidate()
        hookRecoveryTimer = nil
        await Task.detached(priority: .userInitiated) { ConfigInstaller.uninstall() }.value
        setHooksEnabled(false)
        toolsVersion += 1
    }

    /// Installs hooks for every detected tool again after `removeAllHooks()`.
    public func restoreHooks() async {
        setHooksEnabled(true)
        installDetectedHooks()
        startHookRecovery()
    }

    private func setHooksEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.hooksOptInKey)
        hooksEnabled = on
    }

    private func startHookRecovery() {
        guard hookRecoveryTimer == nil else { return }
        hookRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndRepairHooks() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkAndRepairHooks() }
        }
    }

    private func checkAndRepairHooks() {
        guard hooksEnabled, Date().timeIntervalSince(lastHookCheck) > 60 else { return }
        lastHookCheck = Date()
        HookSocketHealth.shared.retryIfDown()
        Task.detached(priority: .background) {
            let repaired = ConfigInstaller.verifyAndRepair()
            if !repaired.isEmpty { Self.log.info("Auto-repaired hooks for: \(repaired.joined(separator: ", "))") }
        }
    }

    // MARK: - Settings

    public func showSettings() {
        SettingsWindowController.shared.appState = appState
        SettingsWindowController.shared.show()
    }

    // MARK: - Shortcuts

    /// Actions the host binds to keys (through its own shortcut recorder).
    public enum Shortcut: CaseIterable, Sendable {
        case togglePanel, approve, approveAlways, deny, skipQuestion, jumpToTerminal
    }

    /// Runs one shortcut action. Card shortcuts act only on the card on screen; with the
    /// request hidden they bring it up instead of acting unseen.
    public func perform(_ shortcut: Shortcut) {
        switch shortcut {
        case .togglePanel:
            if appState.togglePanelFromShortcut(islandAway: !isHostOnScreen()) != .collapsed { presentHost?() }
        case .approve:
            card(.approve)
        case .approveAlways:
            card(.approveAlways)
        case .deny:
            card(.deny)
        case .skipQuestion:
            card(.skipQuestion)
        case .jumpToTerminal:
            if let id = appState.activeSessionId, let session = appState.sessions[id] {
                TerminalActivator.activate(session: session, sessionId: id)
            }
        }
    }

    private func card(_ action: ShortcutAction) {
        if case .opened = appState.performCardShortcut(action, islandOnScreen: isHostOnScreen()) { presentHost?() }
    }

    /// Kept for the ported settings view; the host's own recorder owns key bindings.
    func setupGlobalShortcut() {}
}

#if DEBUG
// MARK: - Debug helpers (UI snapshots)

extension AgentRuntime {
    /// Clears every session and request, then shows the plain list.
    public func debugReset() {
        appState.sessions.removeAll()
        appState.permissionQueue.removeAll()
        appState.questionQueue.removeAll()
        appState.previewQuestionPayload = nil
        appState.surface = .sessionList
    }

    /// One line describing what the agents tab is about to draw.
    public func debugSummary() -> String {
        "sessions=\(appState.sessions.count) surface=\(appState.surface) permissionQueue=\(appState.permissionQueue.count) status=\(appState.status)"
    }

    /// Loads one of CodeIsland's preview scenarios (working, approval, question, completion, multi, allcli…).
    public func debugApply(scenario name: String, keepCollapsed: Bool = false) {
        debugReset()
        guard let scenario = PreviewScenario(rawValue: name) else { return }
        DebugHarness.apply(scenario, to: appState)
        if !keepCollapsed, appState.surface == .collapsed { appState.surface = .sessionList }
    }
}
#endif
