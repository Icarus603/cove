import XCTest
import CodeIslandCore
import NotchKit
@testable import AgentHub

@MainActor
final class SmartSuppressAndShortcutTests: XCTestCase {
    private var savedProbe: TerminalVisibilityDetector.Probe!
    private var savedAppleScriptRunner: AppleScriptRunner!

    override func setUp() {
        super.setUp()
        savedProbe = TerminalVisibilityDetector.probe
        savedAppleScriptRunner = AppleScriptRunner.current
    }

    override func tearDown() {
        TerminalVisibilityDetector.probe = savedProbe
        AppleScriptRunner.current = savedAppleScriptRunner
        super.tearDown()
    }

    func testTogglePanelFromShortcutReturnsCollapsedWhenAlreadyExpanded() {
        let state = AppState()
        state.surface = .sessionList

        let outcome = state.togglePanelFromShortcut(islandAway: false)

        XCTAssertEqual(outcome, .collapsed)
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testTogglePanelFromShortcutKeepsOpenWhenIslandAway() {
        let state = AppState()
        state.surface = .approvalCard(sessionId: "s1")

        let outcome = state.togglePanelFromShortcut(islandAway: true)

        XCTAssertEqual(outcome, .keptOpen)
        XCTAssertEqual(state.surface, .approvalCard(sessionId: "s1"))
    }

    func testShouldAutoOpenPendingSurfaceRespectsClaudeDesktopSessionIdWithoutTermBundleId() {
        let state = AppState()
        var snapshot = SessionSnapshot()
        snapshot.claudeDesktopSessionId = "local_123"
        snapshot.termBundleId = nil
        snapshot.termApp = nil
        state.sessions["s1"] = snapshot

        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let shouldOpen = state.shouldAutoOpenPendingSurface(for: "s1") { _ in true }

        XCTAssertFalse(shouldOpen)
    }

    func testAgentsModuleAttentionIsActiveNotNeedsInputWhenSurfaceCollapsedDespitePendingQueues() async throws {
        let state = AgentRuntime.shared.appState
        let originalSurface = state.surface
        let originalSessions = state.sessions
        let originalPermissions = state.permissionQueue

        UserDefaults.standard.set(false, forKey: SettingsKey.desktopPetEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        state.surface = .collapsed

        let json = """
        {"session_id":"test-suppressed","hook_event_name":"PermissionRequest","tool_name":"Bash"}
        """
        let event = try XCTUnwrap(HookEvent(from: Data(json.utf8)))
        var capturedContinuation: CheckedContinuation<Data, Never>?
        let waiter = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                capturedContinuation = cont
            }
        }
        await Task.yield()
        let cont = try XCTUnwrap(capturedContinuation)
        state.permissionQueue = [PermissionRequest(event: event, continuation: cont, hookConnectionId: nil)]

        let module = AgentsModule()
        XCTAssertEqual(module.attention, .active)

        state.permissionQueue = originalPermissions
        state.sessions = originalSessions
        state.surface = originalSurface
        cont.resume(returning: Data())
        _ = await waiter.value
    }

    func testGhosttyTabActiveResolvesGenericDevTtyViaCliPidOrDescendantPid() {
        var session = SessionSnapshot()
        session.termBundleId = "com.mitchellh.ghostty"
        session.ttyPath = "/dev/tty"
        session.cliPid = getpid()
        session.cwd = "/Users/example/projects/cove"

        let resolvedTty = ProcessRunner.ttyForPid(getpid()) ?? ""
        let parentPid = getppid()
        AppleScriptRunner.current = AppleScriptRunner(
            launch: { _ in },
            evaluate: { _, _ in
                "\(resolvedTty)\n\(parentPid)\n/Users/example\nagyyo\n"
            }
        )

        XCTAssertTrue(TerminalVisibilityDetector.isGhosttyTabActive(session))

        // Different tab TTY must return false even if working directory matches.
        AppleScriptRunner.current = AppleScriptRunner(
            launch: { _ in },
            evaluate: { _, _ in
                "/dev/ttys999\n999999\n/Users/example/projects/cove\ncove\n"
            }
        )
        if !resolvedTty.isEmpty {
            XCTAssertFalse(TerminalVisibilityDetector.isGhosttyTabActive(session))
        }
    }

    func testGhosttyActivationScriptSelectsTabAndUsesAncestorPidsAndResolvedTty() {
        let pids = TerminalActivator.ancestorPids(of: getpid())
        XCTAssertTrue(pids.contains(getpid()))
        XCTAssertTrue(pids.contains(getppid()))

        let script = TerminalActivator.buildGhosttyActivationScript(
            cwd: "/Users/example/projects/cove",
            resolvedTty: "/dev/ttys000",
            candidatePids: pids,
            sessionId: "424ddf3d-1ca4",
            source: "google-antigravity",
            tmuxKey: "",
            tmuxSession: ""
        )

        XCTAssertTrue(script.contains(#"set targetTty to "/dev/ttys000""#))
        XCTAssertTrue(script.contains("candidatePids contains tPid"))
        XCTAssertTrue(script.contains("select tab targetTab"))
        XCTAssertTrue(script.contains("focus targetTerm"))
        XCTAssertTrue(script.contains("activate window targetWin"))
    }
}
