//
//  ModulesSettings.swift
//  boringNotch
//
//  Settings pages for notch tabs and coding agents.
//

import AgentHub
import NotchKit
import SwiftUI

/// Which tabs appear in the notch.
struct ModulesSettings: View {
    @ObservedObject private var registry = AppModules.registry

    var body: some View {
        Form {
            Section {
                ForEach(registry.modules, id: \.id) { module in
                    Toggle(isOn: Binding(
                        get: { !registry.disabledIDs.contains(module.id) },
                        set: { AppModules.setEnabled($0, id: module.id) }
                    )) {
                        Label(module.title, systemImage: module.systemImage)
                    }
                    .disabled(module.id == NotchViews.home.id)
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Choose which tabs appear in the notch.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

struct AgentsSettings: View {
    var body: some View {
        AgentSettingsView()
    }
}

/// The agents' settings pages beyond the main one, each reached from its own sidebar row.
struct AgentSettingsPage: View {
    let id: String

    var body: some View {
        switch id {
        case "AgentDisplay": AgentAppearanceSettingsView()
        case "AgentMascots": AgentMascotSettingsView()
        case "AgentSound": AgentSoundSettingsView()
        case "AgentAutomation": AgentAutomationSettingsView()
        case "AgentRemote": AgentRemoteSettingsView()
        case "AgentBuddy": AgentBuddySettingsView()
        default: AgentHooksSettingsView()
        }
    }
}
