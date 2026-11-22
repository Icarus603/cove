import Foundation
import NotchKit
import SwiftUI

/// A plugin folder found on disk.
public struct DiscoveredPlugin: Identifiable, Equatable {
    public var id: String { manifest?.id ?? folder.lastPathComponent }
    public let folder: URL
    public let manifest: PluginManifest?
    /// Why the folder is not a usable plugin, when it is not.
    public let problem: String?
}

/// Finds plugins in a folder and puts the enabled ones into the notch as tabs.
///
/// Nothing runs until the user switches a plugin on: a plugin is a program with the
/// user's own permissions, so dropping a folder in is not consent to run it.
@MainActor
public final class PluginManager: ObservableObject {
    public static let enabledKey = "pluginkit.enabled"

    @Published public private(set) var discovered: [DiscoveredPlugin] = []
    @Published public private(set) var enabledIDs: Set<String>

    public let directory: URL
    private let registry: ModuleRegistry
    private let defaults: UserDefaults
    private let language: String
    private var running: [String: PluginModule] = [:]

    public init(directory: URL, registry: ModuleRegistry, defaults: UserDefaults = .standard,
                language: String = Locale.preferredLanguages.first ?? "en") {
        self.directory = directory
        self.registry = registry
        self.defaults = defaults
        self.language = language
        self.enabledIDs = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
    }

    /// Rescans the folder and (re)starts enabled plugins that are not running yet.
    public func reload() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var found: [DiscoveredPlugin] = []
        var seen = Set<String>()
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else {
                found.append(.init(folder: folder, manifest: nil, problem: "manifest.json not found"))
                continue
            }
            do {
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                guard seen.insert(manifest.id).inserted else {
                    found.append(.init(folder: folder, manifest: nil, problem: "duplicate id \(manifest.id)"))
                    continue
                }
                found.append(.init(folder: folder, manifest: manifest, problem: nil))
            } catch {
                found.append(.init(folder: folder, manifest: nil, problem: "invalid manifest: \(error.localizedDescription)"))
            }
        }
        discovered = found

        let present = Set(found.compactMap(\.manifest?.id))
        for id in running.keys where !present.contains(id) || !enabledIDs.contains(id) { stop(id) }
        for plugin in found {
            guard let manifest = plugin.manifest, enabledIDs.contains(manifest.id), running[manifest.id] == nil else { continue }
            start(manifest, folder: plugin.folder)
        }
    }

    public func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    public func setEnabled(_ enabled: Bool, id: String) {
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(enabledIDs.sorted(), forKey: Self.enabledKey)
        if enabled {
            if let plugin = discovered.first(where: { $0.manifest?.id == id }), let manifest = plugin.manifest, running[id] == nil {
                start(manifest, folder: plugin.folder)
            }
        } else {
            stop(id)
        }
    }

    public func shutdown() {
        for id in Array(running.keys) { stop(id) }
    }

    private func start(_ manifest: PluginManifest, folder: URL) {
        let module = PluginModule(manifest: manifest, directory: folder, language: language)
        running[manifest.id] = module
        registry.register(module)
        module.start()
    }

    private func stop(_ id: String) {
        guard let module = running.removeValue(forKey: id) else { return }
        module.stop()
        registry.unregister(id: module.id)
    }
}

/// A list of the plugins found, each with an on/off switch.
public struct PluginSettingsView: View {
    @ObservedObject var manager: PluginManager
    @State private var reloadTick = 0

    public init(manager: PluginManager) { self.manager = manager }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plugins run as programs with your user permissions. Only switch on ones you trust.",
                 bundle: .module)
                .font(.callout).foregroundStyle(.secondary)
            if manager.discovered.isEmpty {
                Text("No plugins found in the plugins folder.", bundle: .module).foregroundStyle(.secondary)
            }
            ForEach(manager.discovered) { plugin in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.manifest?.name.resolve(for: Locale.preferredLanguages.first ?? "en") ?? plugin.folder.lastPathComponent)
                        if let problem = plugin.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                        else if let id = plugin.manifest?.id { Text(id).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let id = plugin.manifest?.id {
                        Toggle("", isOn: Binding(get: { manager.isEnabled(id) }, set: { manager.setEnabled($0, id: id) }))
                            .labelsHidden()
                    }
                }
            }
            HStack {
                Button(String(localized: "Open plugins folder", bundle: .module)) {
                    NSWorkspace.shared.open(manager.directory)
                }
                Button(String(localized: "Reload", bundle: .module)) { manager.reload() }
            }
        }
        .onAppear { manager.reload() }
    }
}
