import Testing
@testable import NotchKit

private func resolve(
    _ keyCode: UInt16, _ characters: String? = nil, _ modifiers: KeyModifiers = [], isRepeat: Bool = false,
    _ context: NotchKeyContext
) -> NotchKeyResolution {
    NotchKeyboard.resolve(keyCode: keyCode, characters: characters, modifiers: modifiers, isRepeat: isRepeat, context: context)
}

private func player(_ command: PlayerKeyCommand) -> NotchKeyResolution { .perform(.player(command)) }

private let home = NotchKeyContext(tabCount: 4, currentTabIndex: 0)
private let playing = NotchKeyContext(tabCount: 4, currentTabIndex: 2, isPlayerTab: true, hasCurrentMedia: true)
private let emptyPlayer = NotchKeyContext(tabCount: 4, currentTabIndex: 2, isPlayerTab: true)

struct EscapeTests {
    @Test func closesTheNotch() {
        #expect(resolve(53, nil, [], home) == .perform(.closeNotch))
        #expect(resolve(53, nil, [], playing) == .perform(.closeNotch))
    }

    @Test func leavesEscapeToAFullScreenVideo() {
        var context = playing
        context.isPlayerFullScreen = true
        #expect(resolve(53, nil, [], context) == .passThrough)
    }

    @Test func ignoresEscapeWithModifiers() {
        #expect(resolve(53, nil, .shift, home) == .passThrough)
        #expect(resolve(53, nil, .command, home) == .passThrough)
    }
}

struct TabKeyTests {
    @Test func commandDigitSelectsThatTab() {
        #expect(resolve(18, "1", .command, home) == .perform(.selectTab(0)))
        #expect(resolve(21, "4", .command, home) == .perform(.selectTab(3)))
    }

    @Test func digitBeyondTheTabsIsNotHandled() {
        #expect(resolve(25, "9", .command, home) == .passThrough)
        #expect(resolve(29, "0", .command, home) == .passThrough)
    }

    @Test func digitWithoutCommandIsNotHandled() {
        #expect(resolve(18, "1", [], home) == .passThrough)
        #expect(resolve(18, "1", [.command, .shift], home) == .passThrough)
    }

    @Test func bracketsWrapAround() {
        let last = NotchKeyContext(tabCount: 4, currentTabIndex: 3)
        #expect(resolve(30, "]", .command, last) == .perform(.selectTab(0)))
        #expect(resolve(33, "[", .command, home) == .perform(.selectTab(3)))
        #expect(resolve(30, "]", .command, home) == .perform(.selectTab(1)))
    }

    @Test func bracketsStartFromTheFirstTabWhenTheCurrentOneIsHidden() {
        let hidden = NotchKeyContext(tabCount: 4, currentTabIndex: nil)
        #expect(resolve(30, "]", .command, hidden) == .perform(.selectTab(1)))
    }

    @Test func noTabsMeansNothingToDo() {
        let none = NotchKeyContext(tabCount: 0)
        #expect(resolve(30, "]", .command, none) == .passThrough)
        #expect(resolve(18, "1", .command, none) == .passThrough)
    }
}

struct PlayerKeyTests {
    @Test func playerKeysOnlyWorkOnThePlayerTab() {
        #expect(resolve(49, " ", [], home) == .passThrough)
        #expect(resolve(0, "m", [], home) == .passThrough)
    }

    @Test func playerKeysNeedNoModifiers() {
        #expect(resolve(49, " ", .command, playing) == .passThrough)
        #expect(resolve(0, "m", .shift, playing) == .passThrough)
    }

    @Test func spaceTogglesWhenThereIsMedia() {
        #expect(resolve(49, " ", [], playing) == player(.togglePlayPause))
        var queued = emptyPlayer
        queued.hasQueue = true
        #expect(resolve(49, " ", [], queued) == player(.togglePlayPause))
    }

    @Test func spaceStartsTheListWhenNothingIsLoaded() {
        #expect(resolve(49, " ", [], emptyPlayer) == player(.playFirstVisible))
    }

    @Test func heldSpaceDoesNotToggleAgain() {
        #expect(resolve(49, " ", isRepeat: true, playing) == player(.none))
    }

    @Test func arrowsSkipOnlyWhenSomethingIsLoaded() {
        #expect(resolve(123, nil, [], playing) == player(.skip(seconds: -5)))
        #expect(resolve(124, nil, [], playing) == player(.skip(seconds: 5)))
        #expect(resolve(123, nil, [], emptyPlayer) == .passThrough)
        #expect(resolve(124, nil, [], emptyPlayer) == .passThrough)
    }

    @Test func heldArrowsKeepSkipping() {
        #expect(resolve(124, nil, [], isRepeat: true, playing) == player(.skip(seconds: 5)))
    }

    @Test func upAndDownAlwaysChangeTheVolume() {
        #expect(resolve(126, nil, [], emptyPlayer) == player(.volumeUp))
        #expect(resolve(125, nil, [], emptyPlayer) == player(.volumeDown))
    }

    @Test func muteIgnoresRepeats() {
        #expect(resolve(46, "m", [], playing) == player(.toggleMute))
        #expect(resolve(46, "M", [], playing) == player(.toggleMute))
        #expect(resolve(46, "m", isRepeat: true, playing) == player(.none))
    }

    @Test func fullScreenOnlyForAVideo() {
        var video = playing
        video.showingVideo = true
        video.canShowVideo = true
        #expect(resolve(3, "f", [], video) == player(.toggleFullScreen))

        var hidden = playing
        hidden.canShowVideo = true
        #expect(resolve(3, "f", [], hidden) == player(.showVideo))

        #expect(resolve(3, "f", [], playing) == .passThrough)
        #expect(resolve(3, "f", isRepeat: true, video) == player(.none))
    }

    @Test func nextAndPreviousNeedMedia() {
        #expect(resolve(45, "n", [], playing) == player(.next))
        #expect(resolve(35, "p", [], playing) == player(.previous))
        #expect(resolve(45, "n", [], emptyPlayer) == .passThrough)
        #expect(resolve(35, "p", [], emptyPlayer) == .passThrough)
    }

    @Test func otherKeysPassThrough() {
        #expect(resolve(0, "a", [], playing) == .passThrough)
        #expect(resolve(36, nil, [], playing) == .passThrough)
    }

    @Test func tabKeysStillWorkOnThePlayerTab() {
        #expect(resolve(18, "1", .command, playing) == .perform(.selectTab(0)))
    }
}

struct OutsideClickTests {
    private func close(_ screens: [NotchScreenState], blocked: Bool = false, editing: Bool = false) -> Bool {
        NotchKeyboard.shouldCloseOnOutsideClick(openScreens: screens, closeIsBlocked: blocked, isEditingText: editing)
    }

    @Test func closesAPinnedNotch() {
        #expect(close([NotchScreenState(isPinnedOpen: true)]))
    }

    @Test func leavesANotchThatOpenedByItself() {
        #expect(!close([NotchScreenState(isPinnedOpen: false)]))
    }

    @Test func nothingOpenMeansNothingToClose() {
        #expect(!close([]))
    }

    @Test func staysOpenWhileThePointerIsOverAnyScreen() {
        let pinned = NotchScreenState(isPinnedOpen: true)
        let hovered = NotchScreenState(isPinnedOpen: false, isPointerOver: true)
        #expect(!close([pinned, hovered]))
    }

    @Test func staysOpenForADragOrAPopover() {
        #expect(!close([NotchScreenState(isPinnedOpen: true, isDropTargeted: true)]))
        #expect(!close([NotchScreenState(isPinnedOpen: true, isPopoverActive: true)]))
    }

    @Test func staysOpenWhileSharingOrTyping() {
        let pinned = [NotchScreenState(isPinnedOpen: true)]
        #expect(!close(pinned, blocked: true))
        #expect(!close(pinned, editing: true))
    }
}
