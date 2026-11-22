//
//  UISnapshot.swift
//  boringNotch
//
//  Debug builds only: with COVE_SNAPSHOT_DIR set, the app renders its own windows to PNGs
//  (onboarding steps, every notch tab, every game) and quits. Needs no screen-recording permission,
//  because a process may read back its own views.
//

#if DEBUG
import AgentHub
import AppKit
import Combine
import NotchKit
import SwiftUI

@MainActor
enum UISnapshot {
    /// With COVE_WINDOW_REPORT set, lists every window a few seconds after launch (to catch ones that are too big).
    static func reportWindowsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT"] else { return }
        Task { @MainActor in
            if ProcessInfo.processInfo.environment["COVE_REPORT_SETTINGS"] == "1" { SettingsWindowController.shared.showWindow() }
            // Optionally watch the notch for a few seconds (first launch shows a welcome animation).
            if let pngDir = ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT_PNG_DIR"] {
                try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true)
                for tick in 1...(Int(ProcessInfo.processInfo.environment["COVE_WINDOW_REPORT_TICKS"] ?? "") ?? 6) {
                    await sleep(1)
                    if let window = NSApp.windows.first(where: { $0 is BoringNotchSkyLightWindow }), let content = window.contentView {
                        snapshot(content, to: "\(pngDir)/t\(tick).png")
                        try? "t\(tick): window=\(window.frame) vm=\(String(describing: AppDelegate.current?.vm.notchSize)) state=\(String(describing: AppDelegate.current?.vm.notchState))\n"
                            .appendLine(to: pngDir + "/log.txt")
                    }
                }
            } else {
                await sleep(4)
            }
            var lines: [String] = []
            for screen in NSScreen.screens { lines.append("screen frame=\(screen.frame) visible=\(screen.visibleFrame)") }
            for window in NSApp.windows {
                lines.append("\(type(of: window)) title=\"\(window.title)\" visible=\(window.isVisible) level=\(window.level.rawValue) frame=\(window.frame) contentMin=\(window.contentMinSize) contentMax=\(window.contentMaxSize)")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    static func runIfRequested() {
        reportWindowsIfRequested()
        guard let dir = ProcessInfo.processInfo.environment["COVE_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(into: dir)
            try? "done".write(toFile: dir + "/DONE", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Writes the view's current pixels over a neutral backdrop so transparent areas are visible.
    static func snapshot(_ view: NSView, to path: String, backdrop: NSColor = NSColor(white: 0.62, alpha: 1)) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        backdrop.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Hosts a SwiftUI view in an off-screen titled window and snapshots it.
    private static func render<V: View>(_ root: V, size: CGSize, name: String, dir: String, settle: Double = 0.8) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        await sleep(settle)
        snapshot(host, to: "\(dir)/\(name).png")
        window.close()
    }

    private static func run(into dir: String) async {
        await sleep(3)

        // 1. Onboarding (first launch, permissions not yet granted)
        let steps: [(String, OnboardingStep)] = [
            ("onb-1-welcome", .welcome), ("onb-2-camera", .cameraPermission), ("onb-3-calendar", .calendarPermission),
            ("onb-4-reminders", .remindersPermission), ("onb-5-accessibility", .accessibilityPermission), ("onb-5b-agents", .agents),
            ("onb-6-music", .musicPermission), ("onb-7-finished", .finished),
        ]
        for (name, step) in steps {
            await render(OnboardingView(step: step, onFinish: {}, onOpenSettings: {}),
                         size: CGSize(width: 400, height: 600), name: name, dir: dir)
        }

        // 2. Settings → Modules
        await render(ModulesSettings().frame(width: 560, height: 720), size: CGSize(width: 560, height: 720), name: "settings-modules", dir: dir)
        await render(AgentsSettings().frame(width: 560, height: 1500), size: CGSize(width: 560, height: 1500), name: "settings-agents", dir: dir, settle: 1.2)
        await render(Shortcuts().frame(width: 560, height: 700), size: CGSize(width: 560, height: 700), name: "settings-shortcuts", dir: dir)

        // 3. The notch
        guard let delegate = AppDelegate.current,
              let window = NSApp.windows.first(where: { $0 is BoringNotchSkyLightWindow }),
              let content = window.contentView else {
            try? "no notch window; windows=\(NSApp.windows.map { String(describing: type(of: $0)) }); delegateWindow=\(String(describing: AppDelegate.current?.window)); screens=\(NSScreen.screens.count)".write(toFile: dir + "/ERROR", atomically: true, encoding: .utf8)
            return
        }
        let registry = AppModules.registry
        var geometryLog = ""
        func logGeometry(_ label: String) {
            let hosting = content as? NSHostingView<AnyView>
            _ = hosting
            geometryLog += "\(label): window=\(window.frame) contentMin=\(window.contentMinSize) contentMax=\(window.contentMaxSize) fitting=\(content.fittingSize) vm=\(delegate.vm.notchSize) state=\(delegate.vm.notchState)\n"
            try? geometryLog.write(toFile: dir + "/geometry.txt", atomically: true, encoding: .utf8)
        }
        let screen = window.screen ?? NSScreen.main
        let report = """
        screen.frame=\(String(describing: screen?.frame))
        screen.visibleFrame=\(String(describing: screen?.visibleFrame))
        screen.safeAreaInsets=\(String(describing: screen?.safeAreaInsets))
        window.frame=\(window.frame)
        content.frame=\(content.frame) safeArea=\(content.safeAreaInsets)
        notchSize=\(delegate.vm.notchSize) closed=\(delegate.vm.closedNotchSize)
        """
        try? report.write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
        // Timeline of the notch opening and closing, to see who folds it away.
        let start = Date()
        var timeline = ""
        func mark(_ text: String) { timeline += String(format: "%6.2fs  %@\n", Date().timeIntervalSince(start), text) }
        var cancellables: Set<AnyCancellable> = []
        delegate.vm.$notchState.sink { mark("vm.notchState -> \($0)") }.store(in: &cancellables)
        delegate.vm.$notchSize.sink { mark("vm.notchSize -> \($0)") }.store(in: &cancellables)
        defer { try? timeline.write(toFile: dir + "/timeline.txt", atomically: true, encoding: .utf8) }
        snapshot(content, to: "\(dir)/notch-closed.png")
        logGeometry("notch-closed")
        AgentRuntime.shared.debugApply(scenario: "working")
        await sleep(1.0)
        AgentRuntime.shared.debugApply(scenario: "working") // second pass: accessory appears after the first change publishes
        await sleep(1.0)
        snapshot(content, to: "\(dir)/notch-closed-with-agent.png")
        logGeometry("notch-closed-with-agent")
        // Opening from the mascot must land on the Agents tab.
        delegate.openNotchEverywhere()
        await sleep(1.4)
        try? BoringViewCoordinator.shared.currentView.id.write(toFile: dir + "/open-lands-on.txt", atomically: true, encoding: .utf8)
        snapshot(content, to: "\(dir)/notch-open-from-mascot.png")
        logGeometry("notch-open-from-mascot")
        delegate.closeNotchEverywhere()
        await sleep(0.8)
        AgentRuntime.shared.debugReset()
        await sleep(0.5)

        mark("openNotchEverywhere")
        delegate.openNotchEverywhere()
        await sleep(1.2)
        for module in registry.visibleModules where module.id != "builtin.agents" {
            BoringViewCoordinator.shared.currentView = NotchViews(id: module.id)
            await sleep(1.2)
            snapshot(content, to: "\(dir)/notch-\(module.id).png")
            logGeometry("notch-\(module.id)")
        logGeometry("notch-\(module.id)")
        }

        // Agents: first-run card, then CodeIsland's own preview scenarios.
        BoringViewCoordinator.shared.currentView = NotchViews(id: "builtin.agents")
        await sleep(1.2)
        AgentRuntime.shared.debugReset()
        await sleep(0.8)
        snapshot(content, to: "\(dir)/notch-agents-empty.png")
        logGeometry("notch-agents-empty")
        for scenario in ["working", "multi", "approval", "question", "completion", "allcli"] {
            mark("apply scenario \(scenario)")
            AgentRuntime.shared.debugApply(scenario: scenario)
            await sleep(1.5)
            snapshot(content, to: "\(dir)/notch-agents-\(scenario).png")
            logGeometry("notch-agents-\(scenario) :: \(AgentRuntime.shared.debugSummary()) :: preferred=\(String(describing: AppModules.agents.preferredContentSize))")
        logGeometry("notch-agents-\(scenario)")
        }
        AgentRuntime.shared.debugReset()
        await sleep(0.8)

        // A tool running right now (as in a live session), through the shipped bridge, with the notch closed.
        delegate.closeNotchEverywhere()
        await sleep(0.8)
        func send(_ json: String) async {
            let bridge = Process()
            bridge.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Helpers/codeisland-bridge")
            bridge.arguments = ["--source", "claude"]
            bridge.environment = ProcessInfo.processInfo.environment
            let pipe = Pipe()
            bridge.standardInput = pipe
            bridge.standardOutput = Pipe()
            try? bridge.run()
            pipe.fileHandleForWriting.write(Data(json.utf8))
            try? pipe.fileHandleForWriting.close()
            await sleep(0.6)
            bridge.terminate()
        }
        await send(#"{"hook_event_name":"SessionStart","session_id":"snap-live-1","cwd":"/Users/dev/frontend","source":"startup"}"#)
        await send(#"{"hook_event_name":"UserPromptSubmit","session_id":"snap-live-1","cwd":"/Users/dev/frontend","prompt":"Build the dashboard page"}"#)
        await send(#"{"hook_event_name":"PreToolUse","session_id":"snap-live-1","cwd":"/Users/dev/frontend","tool_name":"Write","tool_input":{"file_path":"/Users/dev/frontend/src/pages/Dashboard.tsx"}}"#)
        await sleep(1.5)
        snapshot(content, to: "\(dir)/notch-closed-live-write.png")
        logGeometry("notch-closed-live-write :: \(AgentRuntime.shared.debugSummary())")
        await send(#"{"hook_event_name":"SessionEnd","session_id":"snap-live-1","cwd":"/Users/dev/frontend","reason":"other"}"#)
        AgentRuntime.shared.debugReset()
        await sleep(0.6)

        // A real approval request through the shipped bridge: tall content, as on a real machine.
        delegate.openNotchEverywhere()
        await sleep(1.0)
        BoringViewCoordinator.shared.currentView = NotchViews(id: "builtin.agents")
        await sleep(0.8)
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"snap-real-1","cwd":"/Users/dev/api-server","tool_name":"Bash","tool_input":{"command":"npm run test -- --coverage && npm run lint -- --max-warnings 0 && npm run build && docker compose -f docker-compose.ci.yml up --abort-on-container-exit --exit-code-from tests && echo finished","description":"Run the whole CI pipeline locally before opening the pull request"},"permission_suggestions":[]}
        """
        let bridge = Process()
        bridge.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Helpers/codeisland-bridge")
        bridge.arguments = ["--source", "claude"]
        bridge.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        bridge.standardInput = pipe
        bridge.standardOutput = Pipe()
        try? bridge.run()
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        try? pipe.fileHandleForWriting.close()
        await sleep(2.5)
        snapshot(content, to: "\(dir)/notch-agents-real-approval.png")
        logGeometry("notch-agents-real-approval")
        bridge.terminate()
        await sleep(0.8)
        AgentRuntime.shared.debugReset()
    }
}
#endif

private extension String {
    func appendLine(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(utf8)); try handle.close() }
        else { try write(to: url, atomically: true, encoding: .utf8) }
    }
}
