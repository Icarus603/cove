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
        .navigationTitle("Modules")
    }
}

struct AgentsSettings: View {
    var body: some View {
        AgentSettingsView()
            .navigationTitle("Agents")
    }
}

/// The agents' settings pages beyond the main one, each reached from its own sidebar row.
struct AgentSettingsPage: View {
    let id: String

    var body: some View {
        switch id {
        case "AgentDisplay": AgentAppearanceSettingsView().navigationTitle("Agent Display")
        case "AgentMascots": AgentMascotSettingsView().navigationTitle("Mascots")
        case "AgentSound": AgentSoundSettingsView().navigationTitle("Sounds")
        case "AgentAutomation": AgentAutomationSettingsView().navigationTitle("Automation")
        case "AgentRemote": AgentRemoteSettingsView().navigationTitle("Remote Hosts")
        case "AgentBuddy": AgentBuddySettingsView().navigationTitle("Buddy")
        default: AgentHooksSettingsView().navigationTitle("Hooks")
        }
    }
}
