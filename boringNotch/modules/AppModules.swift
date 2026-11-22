//
//  AppModules.swift
//  boringNotch
//
//  Hosts the NotchKit registry and the built-in modules.
//

import NotchKit
import SwiftUI

@MainActor
enum AppModules {
    /// The one registry shared by every screen's notch.
    static let registry: ModuleRegistry = {
        let registry = ModuleRegistry()
        registry.register(HomeModule())
        registry.register(ShelfModule())
        return registry
    }()

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
    let title = "Home"
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
    let title = "Shelf"
    let systemImage = "tray.fill"
    let tabOrder = 10

    func makeExpandedView() -> AnyView { AnyView(ShelfView()) }
}
