//
//  ModulesSettings.swift
//  boringNotch
//
//  Settings pages for notch tabs, coding agents and plugins.
//

import AgentHub
import NotchKit
import PluginKit
import SwiftUI

/// Which tabs appear in the notch.
struct ModulesSettings: View {
    @ObservedObject private var registry = AppModules.registry
    @ObservedObject private var plugins = AppModules.plugins

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

            Section {
                PluginSettingsView(manager: plugins)
            } header: {
                Text("Plugins")
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
