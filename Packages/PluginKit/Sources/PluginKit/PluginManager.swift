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

    public enum InstallError: LocalizedError {
        case noManifest, invalidManifest(String), alreadyInstalled(String)
        public var errorDescription: String? {
            switch self {
            case .noManifest: return String(localized: "That folder has no manifest.json.", bundle: .module)
            case .invalidManifest(let why): return String(localized: "The manifest is not valid: \(why)", bundle: .module)
            case .alreadyInstalled(let id): return String(localized: "A plugin with the id \(id) is already installed.", bundle: .module)
            }
        }
    }

    /// Copies a plugin folder into the plugins directory. It is installed switched off.
    @discardableResult
    public func install(from source: URL) throws -> PluginManifest {
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw InstallError.noManifest }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch { throw InstallError.invalidManifest(error.localizedDescription) }
        if discovered.contains(where: { $0.manifest?.id == manifest.id }) { throw InstallError.alreadyInstalled(manifest.id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { target = directory.appendingPathComponent(manifest.id) }
        try FileManager.default.copyItem(at: source, to: target)
        reload()
        return manifest
    }

    /// Stops a plugin and moves its folder to the Trash.
    public func remove(id: String) {
        guard let plugin = discovered.first(where: { $0.id == id }) else { return }
        setEnabled(false, id: id)
        try? FileManager.default.trashItem(at: plugin.folder, resultingItemURL: nil)
        reload()
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
    @State private var pendingRemoval: DiscoveredPlugin?
    @State private var message: String?

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
                    Button(role: .destructive) { pendingRemoval = plugin } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Move to Trash", bundle: .module))
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(String(localized: "Add plugin…", bundle: .module)) { choosePlugin() }
                Button(String(localized: "Open plugins folder", bundle: .module)) { NSWorkspace.shared.open(manager.directory) }
                Button(String(localized: "Reload", bundle: .module)) { manager.reload() }
            }
        }
        .confirmationDialog(
            String(localized: "Move this plugin to the Trash?", bundle: .module),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Move to Trash", bundle: .module), role: .destructive) {
                if let plugin = pendingRemoval { manager.remove(id: plugin.id) }
                pendingRemoval = nil
            }
        }
        .onAppear { manager.reload() }
    }

    private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a plugin folder (it contains manifest.json).", bundle: .module)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try manager.install(from: url); message = nil }
        catch { message = error.localizedDescription }
    }
}

