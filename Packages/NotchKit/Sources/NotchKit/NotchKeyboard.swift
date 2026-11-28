import Foundation

/// The keyboard rules of an open notch, as pure functions of "which key" and "what is on screen". The app turns an `NSEvent` into
/// the plain values below, asks `resolve`, and carries out the answer, so every rule can be tested without a window or a player.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// What the notch looks like at the moment a key is pressed.
public struct NotchKeyContext: Sendable {
    /// Number of visible tabs, in order.
    public var tabCount: Int
    /// Position of the tab on screen, or nil when it is not one of the visible tabs.
    public var currentTabIndex: Int?
    public var isPlayerTab: Bool
    /// The Player is showing a video full screen (Esc belongs to it then).
    public var isPlayerFullScreen: Bool
    /// Something is loaded in the player.
    public var hasCurrentMedia: Bool
    /// Something is waiting in the play queue.
    public var hasQueue: Bool
    /// A video is on screen in the notch right now.
    public var showingVideo: Bool
    /// A video is loaded and could be brought on screen.
    public var canShowVideo: Bool

    public init(
        tabCount: Int, currentTabIndex: Int? = nil, isPlayerTab: Bool = false, isPlayerFullScreen: Bool = false,
        hasCurrentMedia: Bool = false, hasQueue: Bool = false, showingVideo: Bool = false, canShowVideo: Bool = false
    ) {
        self.tabCount = tabCount
        self.currentTabIndex = currentTabIndex
        self.isPlayerTab = isPlayerTab
        self.isPlayerFullScreen = isPlayerFullScreen
        self.hasCurrentMedia = hasCurrentMedia
        self.hasQueue = hasQueue
        self.showingVideo = showingVideo
        self.canShowVideo = canShowVideo
    }
}

public enum PlayerKeyCommand: Equatable, Sendable {
    case togglePlayPause
    /// Nothing is loaded: start the first item of the list on screen.
    case playFirstVisible
    case skip(seconds: Double)
    case volumeUp
    case volumeDown
    case toggleMute
    case toggleFullScreen
    case showVideo
    case next
    case previous
    /// The key belongs to the player but there is nothing to do (a held-down key, say); eat it so it does not beep.
    case none
}

public enum NotchKeyAction: Equatable, Sendable {
    case closeNotch
    case selectTab(Int)
    case player(PlayerKeyCommand)
}

public enum NotchKeyResolution: Equatable, Sendable {
    /// Not ours; let the key carry on.
    case passThrough
    case perform(NotchKeyAction)
}

public enum NotchKeyboard {
    public static let escape: UInt16 = 53
    public static let space: UInt16 = 49
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126

    /// - Parameters:
    ///   - characters: the key's character ignoring modifiers (`charactersIgnoringModifiers`).
    public static func resolve(
        keyCode: UInt16, characters: String?, modifiers: KeyModifiers, isRepeat: Bool, context: NotchKeyContext
    ) -> NotchKeyResolution {
        // Esc closes the notch, unless the Player has a full-screen video that wants it.
        if modifiers.isEmpty, keyCode == escape {
            return context.isPlayerFullScreen ? .passThrough : .perform(.closeNotch)
        }

        // ⌘1–⌘9 jump to a tab; ⌘[ and ⌘] go to the previous and next one, wrapping around.
        if modifiers == .command, let characters {
            if let digit = Int(characters), (1...9).contains(digit), digit <= context.tabCount {
                return .perform(.selectTab(digit - 1))
            }
            if characters == "[" || characters == "]", context.tabCount > 0 {
                let delta = characters == "[" ? -1 : 1
                let next = ((context.currentTabIndex ?? 0) + delta + context.tabCount) % context.tabCount
                return .perform(.selectTab(next))
            }
        }

        guard context.isPlayerTab, modifiers.isEmpty else { return .passThrough }
        let hasMedia = context.hasCurrentMedia || context.hasQueue

        switch keyCode {
        case space:
            guard !isRepeat else { return .perform(.player(.none)) }
            return .perform(.player(hasMedia ? .togglePlayPause : .playFirstVisible))
        case leftArrow:
            if context.hasCurrentMedia { return .perform(.player(.skip(seconds: -5))) }
        case rightArrow:
            if context.hasCurrentMedia { return .perform(.player(.skip(seconds: 5))) }
        case upArrow:
            return .perform(.player(.volumeUp))
        case downArrow:
            return .perform(.player(.volumeDown))
        default:
            break
        }

        switch characters?.lowercased() {
        case "m":
            return .perform(.player(isRepeat ? .none : .toggleMute))
        case "f":
            guard !isRepeat else { return .perform(.player(.none)) }
            if context.showingVideo { return .perform(.player(.toggleFullScreen)) }
            if context.canShowVideo { return .perform(.player(.showVideo)) }
        case "n":
            if hasMedia { return .perform(.player(.next)) }
        case "p":
            if hasMedia { return .perform(.player(.previous)) }
        default:
            break
        }
        return .passThrough
    }
}

/// One screen's notch, as far as closing it by clicking elsewhere is concerned.
public struct NotchScreenState: Sendable {
    public var isPinnedOpen: Bool
    public var isPointerOver: Bool
    public var isDropTargeted: Bool
    public var isPopoverActive: Bool

    public init(isPinnedOpen: Bool, isPointerOver: Bool = false, isDropTargeted: Bool = false, isPopoverActive: Bool = false) {
        self.isPinnedOpen = isPinnedOpen
        self.isPointerOver = isPointerOver
        self.isDropTargeted = isDropTargeted
        self.isPopoverActive = isPopoverActive
    }
}

extension NotchKeyboard {
    /// Whether a click outside should close the notch(es). Only a notch the user pinned open closes this way; one that opened by
    /// itself closes when the pointer leaves.
    /// - Parameter openScreens: one entry for each screen whose notch is open.
    public static func shouldCloseOnOutsideClick(
        openScreens: [NotchScreenState], closeIsBlocked: Bool, isEditingText: Bool
    ) -> Bool {
        guard !openScreens.isEmpty, !closeIsBlocked, !isEditingText else { return false }
        guard openScreens.contains(where: \.isPinnedOpen) else { return false }
        return !openScreens.contains { $0.isPointerOver || $0.isDropTargeted || $0.isPopoverActive }
    }
}
