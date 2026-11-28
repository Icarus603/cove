//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    static let quickNote = Self("quickNote")

    // Coding agents: unbound until the user records a key.
    static let agentToggle = Self("agentToggle")
    static let agentApprove = Self("agentApprove")
    static let agentApproveAlways = Self("agentApproveAlways")
    static let agentDeny = Self("agentDeny")
    static let agentSkipQuestion = Self("agentSkipQuestion")
    static let agentJumpToTerminal = Self("agentJumpToTerminal")
}
