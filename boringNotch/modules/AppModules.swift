//
//  AppModules.swift
//  boringNotch
//
//  Hosts the NotchKit registry, the built-in modules and agents.
//

import AgentHub
import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import NotchKit
import SwiftUI

@MainActor
enum AppModules {
    static let disabledKey = "modules.disabled"

    /// Kept so the closed notch can draw CodeIsland's collapsed bar from it.
    static let agents = AgentsModule()

    /// The one registry shared by every screen's notch.
    static let registry: ModuleRegistry = {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
        if UserDefaults.standard.object(forKey: Defaults.Keys.boringShelf.name) != nil,
           !Defaults[.boringShelf] {
            disabled.insert(NotchViews.shelf.id)
        }
        let registry = ModuleRegistry(disabledIDs: disabled)
        registry.register(HomeModule())
        registry.register(ShelfModule())
        registry.register(PlayerModule())
        registry.register(PhotosModule())
        registry.register(NotesModule())
        registry.register(MarketsModule())
        registry.register(agents)
        return registry
    }()

    /// What the notch window itself needs to know about agents: only whether the collapsed bar shows and whether it is busy.
    /// The window redraws when these flip, not on every agent event; a redraw mid-drag resets the drop targets, so a file
    /// dragged onto the shelf while an agent was working never landed.
    static let barState = AgentBarState()

    private static var cancellables = Set<AnyCancellable>()
    private static var lastAttention: ModuleAttention = .none
    /// The notch was opened by a module that needed the user, not by the user.
    private static var openedForAttention = false
    static var isOpenedForAttention: Bool { openedForAttention }
    private static var bootstrapped = false

    static func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        _ = registry

        AgentRuntime.shared.presentHost = {
            present(moduleID: "builtin.agents", pinned: true)
            AppDelegate.current?.focusNotchWindowForKeyboard()
        }
        AgentRuntime.shared.dismissHost = {
            openedForAttention = false
            AppDelegate.current?.closeNotchEverywhere()
        }
        // The desktop pet's "Open in the notch": the user asked for it, so it stays open (it is not an attention pop-up).
        AgentsModule.onOpenInNotch = {
            BoringViewCoordinator.shared.currentView = NotchViews(id: "builtin.agents")
            AppDelegate.current?.openNotchEverywhere(pinned: true)
            AppDelegate.current?.focusNotchWindowForKeyboard()
        }
        AgentRuntime.shared.isHostOnScreen = { AppDelegate.current?.isAnyNotchOpen ?? false }

        let shelfEnabled = !registry.disabledIDs.contains(NotchViews.shelf.id)
        if Defaults[.boringShelf] != shelfEnabled {
            Defaults[.boringShelf] = shelfEnabled
        }

        // Agent shortcuts are recorded in Settings → Shortcuts like the host's own.
        let bindings: [(KeyboardShortcuts.Name, AgentRuntime.Shortcut)] = [
            (.agentToggle, .togglePanel), (.agentApprove, .approve), (.agentApproveAlways, .approveAlways),
            (.agentDeny, .deny), (.agentSkipQuestion, .skipQuestion), (.agentJumpToTerminal, .jumpToTerminal),
        ]
        for (name, action) in bindings {
            KeyboardShortcuts.onKeyDown(for: name) { AgentRuntime.shared.perform(action) }
        }
        KeyboardShortcuts.onKeyDown(for: .quickNote) {
            AppDelegate.current?.openNotchForQuickNote()
        }

        // A module that needs the user (an approval, a question) brings the notch up on its tab.
        registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in DispatchQueue.main.async { handleAttentionChange() } }
            .store(in: &cancellables)
    }

    static func shutdown() {
        AgentRuntime.shared.stop()
    }

    private static func handleAttentionChange() {
        let top = registry.topAttention
        let level = top?.level ?? .none
        defer { lastAttention = level }
        if level != .needsInput, lastAttention == .needsInput, openedForAttention {
            // The request was answered. Fold the notch away again unless the user is using it.
            openedForAttention = false
            if let delegate = AppDelegate.current, !delegate.isPointerOverNotch { delegate.closeNotchEverywhere() }
            return
        }
        guard level == .needsInput, lastAttention != .needsInput, let module = top?.module else { return }
        present(moduleID: module.id)
    }

    static func present(moduleID: String, pinned: Bool = false) {
        BoringViewCoordinator.shared.currentView = NotchViews(id: moduleID)
        let wasOpen = AppDelegate.current?.isAnyNotchOpen ?? false
        AppDelegate.current?.openNotchEverywhere(pinned: pinned)
        if !wasOpen && !pinned { openedForAttention = true }
    }

    // One view model exists per screen but the registry is shared, so modules
    // go live when the first notch opens and pause when the last one closes.
    private static var openNotchCount = 0

    static func notchOpened() {
        openNotchCount += 1
        if openNotchCount == 1 { registry.notchDidOpen() }
    }

    static func notchClosed() {
        guard openNotchCount > 0 else { return }
        openNotchCount -= 1
        if openNotchCount == 0 { registry.notchDidClose() }
    }

    /// Persists the switch for a module tab.
    static func setEnabled(_ enabled: Bool, id: String) {
        registry.setEnabled(enabled, id: id)
        UserDefaults.standard.set(registry.disabledIDs.sorted(), forKey: disabledKey)
        if id == NotchViews.shelf.id, Defaults[.boringShelf] != enabled {
            Defaults[.boringShelf] = enabled
        }
    }

    /// The Agents tab shows CodeIsland's collapsed bar (the mascot) beside the closed notch: while an agent
    /// works or waits, and while nothing else (music) is using the closed notch.
    static func agentBarShown(musicActive: Bool, musicLiveActivityEnabled: Bool) -> Bool {
        guard !registry.disabledIDs.contains(agents.id), agents.isCompactBarVisible else { return false }
        return agents.isCompactBarBusy || !(musicActive && musicLiveActivityEnabled)
    }

    /// Size of the open notch: the default, or what the selected module asks for.
    private static let minContentOpenHeight: CGFloat = 120

    static func openSize() -> CGSize {
        guard let content = registry.selected?.preferredContentSize else { return openNotchSize }
        let headerAllowance: CGFloat = 44
        return CGSize(
            width: min(max(content.width + 40, openNotchSize.width), maxOpenNotchSize.width),
            // A page that reports its own height may be shorter than the default open notch (an agent list with one session
            // needs no more than it holds); the floor only keeps the header and a little body from collapsing.
            height: min(max(content.height + headerAllowance, minContentOpenHeight), maxOpenNotchSize.height)
        )
    }
}

// MARK: - Environment

private struct AlbumArtNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Shared with the closed-notch music view so album art can animate between states.
    var albumArtNamespace: Namespace.ID? {
        get { self[AlbumArtNamespaceKey.self] }
        set { self[AlbumArtNamespaceKey.self] = newValue }
    }
}

// MARK: - Built-in modules

@MainActor
final class HomeModule: NotchModule {
    let id = NotchViews.home.id
    var title: String { String(localized: "Home") }
    let systemImage = "house.fill"
    let tabOrder = 0

    func makeExpandedView() -> AnyView { AnyView(HomeModuleView()) }
}

private struct HomeModuleView: View {
    @Environment(\.albumArtNamespace) private var injectedNamespace
    @Namespace private var fallbackNamespace

    var body: some View {
        NotchHomeView(albumArtNamespace: injectedNamespace ?? fallbackNamespace)
    }
}

@MainActor
final class ShelfModule: NotchModule {
    let id = NotchViews.shelf.id
    var title: String { String(localized: "Shelf") }
    let systemImage = "tray.fill"
    let tabOrder = 10

    func makeExpandedView() -> AnyView { AnyView(ShelfView()) }
}

@MainActor
final class AgentBarState: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var busy = false
    private var cancellable: AnyCancellable?

    init() {
        refresh()
        cancellable = AppModules.registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    private func refresh() {
        let nowVisible = AppModules.agents.isCompactBarVisible, nowBusy = AppModules.agents.isCompactBarBusy
        if nowVisible != visible { visible = nowVisible }
        if nowBusy != busy { busy = nowBusy }
    }
}
