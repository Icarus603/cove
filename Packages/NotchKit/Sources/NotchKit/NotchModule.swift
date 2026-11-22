import SwiftUI

/// How urgently a module wants the user's eyes. The host uses this to decide
/// whether to auto-expand the notch or show a glance indicator while closed.
public enum ModuleAttention: Int, Comparable, Sendable {
    case none = 0
    /// Something is happening; show a live indicator while the notch is closed.
    case active = 1
    /// The user must act (approval, question). The host may auto-expand.
    case needsInput = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A small view shown beside the physical notch while it is closed.
public struct ClosedAccessory {
    public enum Side: Sendable { case leading, trailing }
    public var side: Side
    public var width: CGFloat
    public var view: AnyView

    public init(side: Side, width: CGFloat, view: AnyView) {
        self.side = side
        self.width = width
        self.view = view
    }
}

/// A self-contained feature that lives in the notch (music, shelf, Claude Code, games…).
///
/// Modules are registered with `ModuleRegistry`; the host renders one tab per
/// enabled module and shows `expandedView` when that tab is selected.
@MainActor
public protocol NotchModule: AnyObject {
    /// Stable identifier, e.g. "builtin.music". Used for persistence and ordering.
    var id: String { get }
    var title: String { get }
    /// SF Symbol name for the tab button.
    var systemImage: String { get }
    /// Lower values come first in the tab bar.
    var tabOrder: Int { get }
    var attention: ModuleAttention { get }
    var closedAccessory: ClosedAccessory? { get }

    /// Content shown when the notch is open and this module's tab is selected.
    func makeExpandedView() -> AnyView

    /// The module's tab became visible. Start timers/games here.
    func activate()
    /// The tab was left or the notch closed. Pause anything running.
    func deactivate()
}

public extension NotchModule {
    var tabOrder: Int { 100 }
    var attention: ModuleAttention { .none }
    var closedAccessory: ClosedAccessory? { nil }
    func activate() {}
    func deactivate() {}
}
