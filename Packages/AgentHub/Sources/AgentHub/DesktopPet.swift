import AppKit
import CodeIslandCore
import Combine
import Observation
import SwiftUI

// MARK: - The desktop pet
//
// The default mascot, living on the desktop. It takes the pose of what the agents are doing (asleep, working, waiting for you,
// done) and, while it is on, it is where the agents talk to you: approvals, questions and completions pop up in a bubble beside
// it instead of opening the notch, and the mascot next to the notch is hidden so there is only ever one. Off by default; turned
// on in Settings → Agents → Mascots.

// MARK: Pure decisions (tested)

enum PetSize: Int, CaseIterable {
    case small = 0, medium, large

    var points: CGFloat {
        switch self {
        case .small: return 72
        case .medium: return 96
        case .large: return 128
        }
    }
    var labelKey: String {
        switch self {
        case .small: return "pet_size_small"
        case .medium: return "pet_size_medium"
        case .large: return "pet_size_large"
        }
    }
}

/// Where the pet sits: its distance from the right and bottom edges of the usable area of one display, so it stays in its
/// corner when the screen changes size.
struct PetPosition: Equatable {
    var fromRight: CGFloat = 28
    var fromBottom: CGFloat = 14
    var display: String?

    var text: String { "\(Int(fromRight)),\(Int(fromBottom)),\(display ?? "")" }

    static func parse(_ text: String?) -> PetPosition? {
        guard let text else { return nil }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let right = Double(parts[0]), let bottom = Double(parts[1]) else { return nil }
        return PetPosition(fromRight: CGFloat(right), fromBottom: CGFloat(bottom), display: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }

    /// The pet's window, kept entirely inside the usable area.
    func frame(side: CGFloat, in visible: CGRect) -> CGRect {
        let x = min(max(visible.maxX - fromRight - side, visible.minX), visible.maxX - side)
        let y = min(max(visible.minY + fromBottom, visible.minY), visible.maxY - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    static func from(frame: CGRect, in visible: CGRect, display: String?) -> PetPosition {
        PetPosition(fromRight: max(visible.maxX - frame.maxX, 0), fromBottom: max(frame.minY - visible.minY, 0), display: display)
    }
}

enum PetBubblePlacement {
    struct Result: Equatable {
        var frame: CGRect
        /// Where the little tail points, from the bubble's left edge.
        var tailX: CGFloat
        /// The bubble is above the pet (its tail is at the bottom).
        var above: Bool
    }

    /// A bubble beside the pet: above it when there is room, below otherwise, kept on the screen, its tail pointing at the pet.
    static func place(size: CGSize, pet: CGRect, visible: CGRect, gap: CGFloat = 4, margin: CGFloat = 8) -> Result {
        var x = pet.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        let room = visible.maxY - margin - (pet.maxY + gap)
        let above = size.height <= room || pet.minY - gap - visible.minY < size.height
        var y = above ? pet.maxY + gap : pet.minY - gap - size.height
        y = min(max(y, visible.minY + margin), visible.maxY - margin - size.height)
        let tail = min(max(pet.midX - x, 26), size.width - 26)
        return Result(frame: CGRect(x: x, y: y, width: size.width, height: size.height), tailX: tail, above: above)
    }
}

enum DesktopPetRules {
    /// Whether the bubble opens by itself for what is on the agent surface now. It follows the same choices as the notch's
    /// auto-expand: a user who switched auto-expand off for approvals is not startled by a bubble either (the pet still
    /// shows it is waiting, and a click opens the card).
    static func opensByItself(surface: IslandSurface, wantsPermission: Bool, wantsQuestion: Bool, completion: CompletionStyle) -> Bool {
        switch surface {
        case .approvalCard: return wantsPermission
        case .questionCard: return wantsQuestion
        case .completionCard: return completion == .expand
        case .collapsed, .sessionList: return false
        }
    }

    /// A card that asks something of the user must stay until it is answered; a plain list may be dismissed by a click away.
    static func needsAnswer(surface: IslandSurface) -> Bool {
        switch surface {
        case .approvalCard, .questionCard: return true
        default: return false
        }
    }

    static func isVisible(enabled: Bool, when: String, busy: Bool, bubbleOpen: Bool) -> Bool {
        guard enabled else { return false }
        return when == "busy" ? (busy || bubbleOpen) : true
    }

    /// Whether the pet's per-frame animation runs: while an agent is active, while the pointer is on it, and for a few seconds
    /// after something woke it; then it rests on a still frame (a live animation costs CPU all day).
    static func animates(visible: Bool, reduceMotion: Bool, status: AgentStatus, hovering: Bool, awake: Bool) -> Bool {
        guard visible, !reduceMotion else { return false }
        return status != .idle || hovering || awake
    }

    /// An agent just went from working to idle with nothing waiting: it has finished something, so the pet cheers.
    static func finished(from old: AgentStatus, to new: AgentStatus) -> Bool {
        old != .idle && new == .idle
    }
}

extension Notification.Name {
    /// Posted when the desktop pet is turned on or off, so the notch module re-reads what it shows and when it opens.
    static let desktopPetSettingsChanged = Notification.Name("CoveDesktopPetSettingsChanged")
}

// MARK: - Controller

@MainActor
final class DesktopPetController: NSObject, ObservableObject {
    static let shared = DesktopPetController()

    // What the views draw
    @Published private(set) var status: AgentStatus = .idle
    @Published private(set) var pendingCount = 0
    @Published private(set) var celebratingUntil: Date = .distantPast
    @Published private(set) var animating = false
    @Published var hovering = false { didSet { if hovering != oldValue { wake(for: 8); refreshAnimating() } } }
    @Published private(set) var size: PetSize = .medium
    @Published private(set) var source = SettingsDefaults.defaultSource
    @Published private(set) var bubbleOpen = false
    @Published private(set) var bubbleTail: CGFloat = 60
    @Published private(set) var bubbleAbove = true
    @Published private(set) var bubbleContentHeight: CGFloat = 120

    /// The pet's window is a little larger than the pet, so a raised arm or the tilt on hover is not cut off.
    static let margin: CGFloat = 12
    static let bubbleWidth: CGFloat = 470
    static let tailHeight: CGFloat = 9

    /// For snapshots: keep both windows off the real screen.
    var debugOffscreen = false

    private var petPanel: PetPanel?
    private var bubblePanel: BubblePanel?
    private var started = false
    private var awakeUntil: Date = .distantPast
    private var userOpenedList = false
    private var lastStatus: AgentStatus = .idle
    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var clickMonitors: [Any] = []
    private var restTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private var defaults: UserDefaults { .standard }
    private var appState: AppState { AgentRuntime.shared.appState }

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.desktopPetEnabled) }
    var isEnabled: Bool { Self.isEnabled }

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.defaultsChanged() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        track()
        refresh()
    }

    /// Re-arms Observation: AppState is @Observable, so a change to what is read here fires once and must be registered again.
    private func track() {
        withObservationTracking {
            let state = appState
            _ = state.surface
            _ = state.status
            _ = state.permissionQueue.count
            _ = state.questionQueue.count
            _ = state.sessions.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
    }

    private var lastEnabled: Bool?
    private var lastSettingsSnapshot = ""

    private func defaultsChanged() {
        let snapshot = "\(isEnabled)|\(defaults.integer(forKey: SettingsKey.desktopPetSize))|\(defaults.string(forKey: SettingsKey.desktopPetWhen) ?? "")|\(defaults.bool(forKey: SettingsKey.desktopPetHideInFullscreen))|\(defaults.string(forKey: SettingsKey.defaultSource) ?? "")"
        guard snapshot != lastSettingsSnapshot else { return }
        lastSettingsSnapshot = snapshot
        refresh()
    }

    // MARK: State

    func refresh() {
        let enabled = isEnabled
        if lastEnabled != enabled {
            lastEnabled = enabled
            NotificationCenter.default.post(name: .desktopPetSettingsChanged, object: nil)
            if !enabled { userOpenedList = false }
        }
        size = PetSize(rawValue: defaults.integer(forKey: SettingsKey.desktopPetSize)) ?? .medium
        source = defaults.string(forKey: SettingsKey.defaultSource) ?? SettingsDefaults.defaultSource

        let state = appState
        let newStatus = state.status
        pendingCount = state.permissionQueue.count + state.questionQueue.count
        if DesktopPetRules.finished(from: lastStatus, to: newStatus), pendingCount == 0 {
            celebratingUntil = Date().addingTimeInterval(2.8)
            wake(for: 6)
        }
        if newStatus != lastStatus { wake(for: 8) }
        lastStatus = newStatus
        status = newStatus

        // A list the user opened is closed once the surface has gone back to collapsed by other means.
        if userOpenedList, state.surface == .collapsed { userOpenedList = false }

        let autoOpen = DesktopPetRules.opensByItself(surface: state.surface, wantsPermission: bool(SettingsKey.autoExpandOnPermission, true),
                                                     wantsQuestion: bool(SettingsKey.autoExpandOnQuestion, true), completion: AppState.completionStyle())
        bubbleOpen = enabled && (autoOpen || userOpenedList)

        let visible = DesktopPetRules.isVisible(enabled: enabled, when: defaults.string(forKey: SettingsKey.desktopPetWhen) ?? "always",
                                                busy: newStatus != .idle, bubbleOpen: bubbleOpen)
        if visible { ensurePanels() } else { hidePanels() }
        refreshAnimating(visible: visible)
        if visible { layout() }
        updateClickMonitors()
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }

    private var isVisibleNow: Bool { petPanel?.isVisible == true }

    private func wake(for seconds: TimeInterval) {
        awakeUntil = max(awakeUntil, Date().addingTimeInterval(seconds))
        refreshAnimating()
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: seconds + 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshAnimating() }
        }
    }

    private func refreshAnimating(visible: Bool? = nil) {
        let now = DesktopPetRules.animates(visible: visible ?? isVisibleNow, reduceMotion: MascotAnimationGate.shared.reduceMotion,
                                           status: status, hovering: hovering, awake: awakeUntil > Date())
        if now != animating { animating = now }
    }

    var celebrating: Bool { celebratingUntil > Date() }

    // MARK: Windows

    private var panelSide: CGFloat { size.points + Self.margin * 2 }

    private func ensurePanels() {
        if petPanel == nil {
            let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: panelSide, height: panelSide), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = false
            panel.setAccessibilityLabel("Desktop pet")
            let host = NSHostingView(rootView: DesktopPetView(controller: self))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            petPanel = panel
        }
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !bool(SettingsKey.desktopPetHideInFullscreen, true) { behavior.insert(.fullScreenAuxiliary) }   // without it, a full-screen app's space does not show the pet
        petPanel?.collectionBehavior = behavior
        if bubblePanel == nil {
            let panel = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: Self.bubbleWidth, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: PetBubbleView(controller: self, runtime: AgentRuntime.shared))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            bubblePanel = panel
        }
        bubblePanel?.collectionBehavior = petPanel?.collectionBehavior ?? [.canJoinAllSpaces]
    }

    private func hidePanels() {
        petPanel?.orderOut(nil)
        bubblePanel?.orderOut(nil)
        hovering = false
    }

    private var currentScreen: NSScreen {
        let position = PetPosition.parse(defaults.string(forKey: SettingsKey.desktopPetPosition))
        if let id = position?.display, let match = NSScreen.screens.first(where: { ScreenDetector.displayUUID(for: $0) == id }) { return match }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Puts the pet at its saved place (or in the lower right corner) and the bubble beside it.
    func layout() {
        guard let petPanel else { return }
        let screen = currentScreen
        let visible = screen.visibleFrame
        let position = PetPosition.parse(defaults.string(forKey: SettingsKey.desktopPetPosition)) ?? PetPosition()
        if dragStartMouse == nil {
            var frame = position.frame(side: panelSide, in: visible)
            if debugOffscreen { frame.origin = CGPoint(x: -20_000, y: -20_000) }
            if petPanel.frame != frame { petPanel.setFrame(frame, display: true) }
        }
        petPanel.orderFrontRegardless()
        layoutBubble()
    }

    private func layoutBubble() {
        guard let bubblePanel, let petPanel else { return }
        guard bubbleOpen else { bubblePanel.orderOut(nil); return }
        let size = CGSize(width: Self.bubbleWidth, height: bubbleContentHeight + Self.tailHeight)
        let petInner = petPanel.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let visible = (petPanel.screen ?? currentScreen).visibleFrame
        let reference = debugOffscreen ? CGRect(x: 0, y: 0, width: 1600, height: 1000) : visible
        let pet = debugOffscreen ? CGRect(x: 1100, y: 40, width: petInner.width, height: petInner.height) : petInner
        let placed = PetBubblePlacement.place(size: size, pet: pet, visible: reference)
        bubbleTail = placed.tailX
        bubbleAbove = placed.above
        var frame = placed.frame
        if debugOffscreen { frame.origin = CGPoint(x: -20_000 + (frame.minX - 0), y: -20_000 + frame.minY) }
        if bubblePanel.frame != frame { bubblePanel.setFrame(frame, display: true) }
        bubblePanel.orderFrontRegardless()
    }

    func setBubbleContentHeight(_ height: CGFloat) {
        let clamped = min(max(height, 60), 430)
        guard abs(clamped - bubbleContentHeight) > 1 else { return }
        bubbleContentHeight = clamped
        layoutBubble()
    }

    // MARK: What the user does with the pet

    /// A click: open the list of sessions, or close it (a card that waits for an answer stays).
    func toggleList() {
        guard isEnabled else { return }
        let state = appState
        if bubbleOpen {
            guard !DesktopPetRules.needsAnswer(surface: state.surface) else { return }
            closeList()
        } else {
            userOpenedList = true
            if state.surface == .collapsed { state.surface = .sessionList }
            refresh()
        }
    }

    func closeList() {
        userOpenedList = false
        if appState.surface == .sessionList { appState.surface = .collapsed }
        refresh()
    }

    func openInNotch() {
        closeList()
        AgentsModule.onOpenInNotch?()
    }

    func hide() { defaults.set(false, forKey: SettingsKey.desktopPetEnabled) }

    func setSize(_ new: PetSize) { defaults.set(new.rawValue, forKey: SettingsKey.desktopPetSize) }

    func resetPosition() {
        defaults.removeObject(forKey: SettingsKey.desktopPetPosition)
        layout()
    }

    // MARK: Dragging

    func dragMoved() {
        guard let petPanel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil { dragStartMouse = mouse; dragStartOrigin = petPanel.frame.origin }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let origin = CGPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y)
        petPanel.setFrameOrigin(origin)
        layoutBubble()
    }

    func dragEnded() {
        defer { dragStartMouse = nil; dragStartOrigin = nil }
        guard let petPanel else { return }
        // Which display is the pet on now, and where in it: remembered so it comes back to the same corner.
        let centre = CGPoint(x: petPanel.frame.midX, y: petPanel.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) ?? currentScreen
        let position = PetPosition.from(frame: petPanel.frame, in: screen.visibleFrame, display: ScreenDetector.displayUUID(for: screen))
        defaults.set(position.text, forKey: SettingsKey.desktopPetPosition)
        layout()
    }

    // MARK: Clicking away closes a plain list

    private func updateClickMonitors() {
        let wanted = bubbleOpen && !DesktopPetRules.needsAnswer(surface: appState.surface)
        if wanted, clickMonitors.isEmpty {
            let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
                Task { @MainActor in self?.clickAway() }
            }) { clickMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
                if let self, event.window !== self.bubblePanel, event.window !== self.petPanel { self.clickAway() }
                return event
            }) { clickMonitors.append(local) }
        } else if !wanted, !clickMonitors.isEmpty {
            clickMonitors.forEach { NSEvent.removeMonitor($0) }
            clickMonitors = []
        }
    }

    private func clickAway() {
        guard bubbleOpen, !DesktopPetRules.needsAnswer(surface: appState.surface) else { return }
        closeList()
    }

    // MARK: Snapshots

    func debugCelebrate() { celebratingUntil = Date().addingTimeInterval(2.8); wake(for: 6) }

    var debugPetWindow: NSWindow? { petPanel }
    var debugBubbleWindow: NSWindow? { bubblePanel }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bubble can take the keyboard (a question may be answered in words) without making Cove the active app.
private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The pet

struct DesktopPetView: View {
    @ObservedObject var controller: DesktopPetController

    var body: some View {
        let side = controller.size.points
        ZStack {
            PetMotion(controller: controller) {
                MascotView(source: controller.source, status: controller.status, size: side, animating: controller.animating)
                    .frame(width: side, height: side)
            }
            .scaleEffect(controller.hovering ? 1.07 : 1, anchor: .bottom)
            .rotationEffect(.degrees(controller.hovering ? -3 : 0), anchor: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: controller.hovering)

            if controller.pendingCount > 0 {
                Text(verbatim: "\(controller.pendingCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color(red: 1, green: 0.24, blue: 0)))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                    .offset(x: side / 2 - 6, y: -side / 2 + 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side + DesktopPetController.margin * 2, height: side + DesktopPetController.margin * 2)
        .contentShape(Rectangle())
        .onHover { controller.hovering = $0 }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in controller.dragMoved() }
            .onEnded { _ in controller.dragEnded() })
        .onTapGesture(count: 2) { controller.openInNotch() }
        .onTapGesture { controller.toggleList() }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        let l10n = L10n.shared
        Button(l10n["pet_menu_open_notch"]) { controller.openInNotch() }
        Menu(l10n["pet_menu_size"]) {
            ForEach(PetSize.allCases, id: \.rawValue) { size in
                Button { controller.setSize(size) } label: {
                    if controller.size == size { Label(l10n[size.labelKey], systemImage: "checkmark") } else { Text(l10n[size.labelKey]) }
                }
            }
        }
        Divider()
        Button(l10n["pet_menu_hide"]) { controller.hide() }
    }
}

/// What the pet does besides what the mascot's own pixels do: a small hop while it waits for you, and a jump with a few stars
/// when something has finished. Drawn only while it is needed; an idle pet has no timeline running.
private struct PetMotion<Content: View>: View {
    @ObservedObject var controller: DesktopPetController
    @ViewBuilder var content: () -> Content

    private var waiting: Bool { controller.status == .waitingApproval || controller.status == .waitingQuestion }

    var body: some View {
        if controller.animating && (waiting || controller.celebrating) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let side = controller.size.points
                ZStack {
                    content().offset(y: -lift(at: t, side: side))
                    if controller.celebrating { Sparkles(t: controller.celebratingUntil.timeIntervalSince(context.date), side: side) }
                }
            }
        } else {
            content()
        }
    }

    /// Up in points: a quick double hop every couple of seconds while waiting; bigger, steadier jumps while celebrating.
    private func lift(at t: Double, side: CGFloat) -> CGFloat {
        if controller.celebrating {
            let phase = (t * 2.4).truncatingRemainder(dividingBy: 1)
            return CGFloat(abs(sin(phase * .pi))) * side * 0.16
        }
        let cycle = t.truncatingRemainder(dividingBy: 2.2)
        guard cycle < 0.9 else { return 0 }
        return CGFloat(abs(sin(cycle / 0.9 * 2 * .pi))) * side * 0.09
    }
}

/// A few small stars that rise and fade while the pet celebrates. `t` is the time left in the celebration.
private struct Sparkles: View {
    let t: Double
    let side: CGFloat

    var body: some View {
        let progress = max(0, min(1, 1 - t / 2.8))
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                let angle = Double(index) / 6 * 2 * .pi + 0.4
                let spread = side * (0.34 + 0.2 * progress)
                Image(systemName: index % 2 == 0 ? "sparkle" : "star.fill")
                    .font(.system(size: side * (index % 2 == 0 ? 0.17 : 0.1)))
                    .foregroundStyle(index % 3 == 0 ? Color.yellow : Color(red: 1, green: 0.78, blue: 0.5))
                    .offset(x: CGFloat(cos(angle)) * spread, y: CGFloat(sin(angle)) * spread * 0.8 - side * 0.12 - side * 0.15 * progress)
                    .opacity(1 - progress * progress)
                    .scaleEffect(0.7 + 0.5 * (1 - progress))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The bubble

struct PetBubbleView: View {
    @ObservedObject var controller: DesktopPetController
    let runtime: AgentRuntime

    var body: some View {
        let tail = DesktopPetController.tailHeight
        VStack(spacing: 0) {
            if !controller.bubbleAbove { BubbleTail(x: controller.bubbleTail, pointsUp: true).frame(height: tail) }
            AgentsExpandedView(runtime: runtime) { controller.setBubbleContentHeight($0 + 12) }
                .frame(width: DesktopPetController.bubbleWidth, height: controller.bubbleContentHeight)
                .background(Color(white: 0.04).opacity(0.97))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            if controller.bubbleAbove { BubbleTail(x: controller.bubbleTail, pointsUp: false).frame(height: tail) }
        }
        .environment(\.colorScheme, .dark)
        .frame(width: DesktopPetController.bubbleWidth)
    }
}

/// The little triangle that points the bubble at the pet.
private struct BubbleTail: View {
    let x: CGFloat
    let pointsUp: Bool

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let h = geo.size.height
                if pointsUp {
                    path.move(to: CGPoint(x: x - 9, y: h)); path.addLine(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x + 9, y: h))
                } else {
                    path.move(to: CGPoint(x: x - 9, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); path.addLine(to: CGPoint(x: x + 9, y: 0))
                }
                path.closeSubpath()
            }
            .fill(Color(white: 0.04).opacity(0.97))
        }
    }
}

// MARK: - The way in from the app

public enum DesktopPet {
    @MainActor public static func start() { DesktopPetController.shared.start() }
    public static var isEnabled: Bool { DesktopPetController.isEnabled }

    #if DEBUG
    /// Snapshots only: keeps the windows off the real screen and hands out their window numbers.
    @MainActor public static func debugUseOffscreen() { DesktopPetController.shared.debugOffscreen = true; DesktopPetController.shared.refresh() }
    @MainActor public static var debugPetWindowNumber: Int? { DesktopPetController.shared.debugPetWindow?.windowNumber }
    @MainActor public static var debugBubbleWindowNumber: Int? { DesktopPetController.shared.debugBubbleWindow.flatMap { $0.isVisible ? $0.windowNumber : nil } }
    @MainActor public static func debugOpenList() { DesktopPetController.shared.toggleList() }
    @MainActor public static func debugCelebrate() { DesktopPetController.shared.debugCelebrate() }
    @MainActor public static func debugHover(_ on: Bool) { DesktopPetController.shared.hovering = on }
    #endif
}
