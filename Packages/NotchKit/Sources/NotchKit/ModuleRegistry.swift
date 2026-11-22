import SwiftUI

/// Holds the modules the host knows about and which tab is selected.
@MainActor
public final class ModuleRegistry: ObservableObject {
    @Published public private(set) var modules: [any NotchModule] = []
    @Published public private(set) var selectedID: String?
    @Published public private(set) var disabledIDs: Set<String>

    private var activated = false
    /// False until `select(id:)` succeeds; until then the default tracks the first visible module.
    private var userChoseTab = false

    public init(disabledIDs: Set<String> = []) {
        self.disabledIDs = disabledIDs
    }

    /// Enabled modules in tab order (ties keep registration order).
    public var visibleModules: [any NotchModule] {
        modules.filter { !disabledIDs.contains($0.id) }
    }

    public var selected: (any NotchModule)? {
        visibleModules.first { $0.id == selectedID }
    }

    /// The highest attention level among visible modules, and who asked for it.
    public var topAttention: (module: any NotchModule, level: ModuleAttention)? {
        visibleModules
            .map { (module: $0, level: $0.attention) }
            .filter { $0.level > .none }
            .max { $0.level < $1.level }
    }

    /// Registers a module. Registering an existing id replaces it in place.
    public func register(_ module: any NotchModule) {
        if let index = modules.firstIndex(where: { $0.id == module.id }) {
            if module.id == selectedID, activated { modules[index].deactivate() }
            modules[index] = module
        } else {
            modules.append(module)
            modules.sort { $0.tabOrder < $1.tabOrder } // stable for equal keys
        }
        refreshDefaultSelection()
    }

    public func unregister(id: String) {
        if id == selectedID, activated { selected?.deactivate() }
        modules.removeAll { $0.id == id }
        if selectedID == id { selectedID = visibleModules.first?.id }
        refreshDefaultSelection()
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        if enabled {
            disabledIDs.remove(id)
        } else {
            if id == selectedID, activated { selected?.deactivate() }
            disabledIDs.insert(id)
            if selectedID == id { selectedID = visibleModules.first?.id }
        }
        refreshDefaultSelection()
    }

    private func refreshDefaultSelection() {
        if selectedID == nil || !userChoseTab { selectedID = visibleModules.first?.id }
    }

    /// Switches tabs. Unknown or disabled ids are ignored.
    public func select(id: String) {
        guard id != selectedID, visibleModules.contains(where: { $0.id == id }) else { return }
        if activated { selected?.deactivate() }
        selectedID = id
        userChoseTab = true
        if activated { selected?.activate() }
    }

    /// The notch opened: the selected module becomes live.
    public func notchDidOpen() {
        guard !activated else { return }
        activated = true
        selected?.activate()
    }

    /// The notch closed: pause the selected module.
    public func notchDidClose() {
        guard activated else { return }
        selected?.deactivate()
        activated = false
    }
}
