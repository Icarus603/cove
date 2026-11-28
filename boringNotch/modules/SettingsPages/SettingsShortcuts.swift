//
//  SettingsShortcuts.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import KeyboardShortcuts
import SwiftUI

struct Shortcuts: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle Sneak Peek:", name: .toggleSneakPeek)
            } header: {
                Text("Media")
            } footer: {
                Text(
                    "Sneak Peek shows the media title and artist under the notch for a few seconds."
                )
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
                KeyboardShortcuts.Recorder("Quick Note:", name: .quickNote)
            } header: {
                Text("Notch & Notes")
            } footer: {
                Text("When the notch is focused (opened by shortcut or clicked), press Esc to close, ⌘1–⌘7 or ⌘[ / ⌘] to switch tabs, and Space / F / arrow keys to control video.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder("Show Agents:", name: .agentToggle)
                KeyboardShortcuts.Recorder("Approve:", name: .agentApprove)
                KeyboardShortcuts.Recorder("Always Allow:", name: .agentApproveAlways)
                KeyboardShortcuts.Recorder("Deny:", name: .agentDeny)
                KeyboardShortcuts.Recorder("Skip Question:", name: .agentSkipQuestion)
                KeyboardShortcuts.Recorder("Jump to Terminal:", name: .agentJumpToTerminal)
            } header: {
                Text("Agents")
            } footer: {
                Text("Approve, deny and skip act on the request shown in the notch; if it is hidden they bring it up instead.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
    }
}
