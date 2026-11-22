import CodeIslandCore
import SwiftUI

/// Settings for the agents tab, laid out like the host's own settings pages.
/// (CodeIsland's standalone settings window is not used: everything lives in the host.)
public struct AgentSettingsView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = AgentRuntime.shared

    // Behaviour
    @AppStorage(SettingsKey.smartSuppress) private var smartSuppress = SettingsDefaults.smartSuppress
    @AppStorage(SettingsKey.autoExpandOnPermission) private var autoExpandOnPermission = SettingsDefaults.autoExpandOnPermission
    @AppStorage(SettingsKey.autoExpandOnQuestion) private var autoExpandOnQuestion = SettingsDefaults.autoExpandOnQuestion
    @AppStorage(SettingsKey.completionNotificationStyle) private var completionStyle = AppState.completionStyle().rawValue
    @AppStorage(SettingsKey.followUpReminderMinutes) private var followUpReminderMinutes = SettingsDefaults.followUpReminderMinutes

    @AppStorage(SettingsKey.autoCollapseAfterSessionJump) private var autoCollapseAfterSessionJump = SettingsDefaults.autoCollapseAfterSessionJump
    @AppStorage(SettingsKey.rotationInterval) private var rotationInterval = SettingsDefaults.rotationInterval
    @AppStorage(SettingsKey.pluginSessionMode) private var pluginSessionMode = SettingsDefaults.pluginSessionMode

    @State private var tools: [AgentRuntime.AgentTool] = []
    @State private var busy = false

    public init() {}

    public var body: some View {
        Form {
            toolsSection
            behaviorSection
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadTools)
        .onChange(of: runtime.toolsVersion) { _, _ in reloadTools() }
    }

    // MARK: Tools

    private func reloadTools() { tools = runtime.tools() }

    private var toolsSection: some View {
        let found = tools.filter(\.detected)
        let others = tools.filter { !$0.detected }
        return Section {
            if runtime.standingAside {
                Text(l10n["agents_aside"]).foregroundStyle(.secondary)
            } else {
                Text(l10n["agents_tools_desc"]).font(.callout).foregroundStyle(.secondary)
                if !runtime.hooksEnabled { Text(l10n["agents_hooks_removed"]).font(.callout).foregroundStyle(.orange) }
                Text(l10n["agents_found"]).font(.subheadline.weight(.semibold))
                if found.isEmpty { Text(l10n["agents_none_found"]).foregroundStyle(.secondary) }
                ForEach(found) { toolRow($0) }
                DisclosureGroup(l10n["agents_others"]) {
                    ForEach(others) { toolRow($0) }
                }
                HStack {
                    if runtime.hooksEnabled {
                        Button(l10n["agents_remove_all"], role: .destructive) { run { await runtime.removeAllHooks() } }
                    } else {
                        Button(l10n["agents_restore"]) { run { await runtime.restoreHooks() } }
                    }
                }
                .disabled(busy)
            }
        } header: {
            Text(l10n["agents_tools_title"])
        }
    }

    private func toolRow(_ tool: AgentRuntime.AgentTool) -> some View {
        Toggle(isOn: Binding(
            get: { tool.installed },
            set: { on in run { await runtime.setTool(tool.id, enabled: on) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                Text(tool.installed ? l10n["agents_hooks_on"] : l10n["agents_hooks_off"])
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(busy || !runtime.hooksEnabled)
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false; reloadTools() }
    }

    // MARK: Behaviour

    private func described<C: View>(_ desc: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            control()
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var behaviorSection: some View {
        Section(l10n["agents_behavior"]) {
            described(l10n["auto_expand_on_permission_desc"]) { Toggle(l10n["auto_expand_on_permission"], isOn: $autoExpandOnPermission) }
            described(l10n["auto_expand_on_question_desc"]) { Toggle(l10n["auto_expand_on_question"], isOn: $autoExpandOnQuestion) }
            described(l10n["smart_suppress_desc"]) { Toggle(l10n["smart_suppress"], isOn: $smartSuppress) }
            described(l10n["completion_notification_desc"]) {
                Picker(l10n["completion_notification"], selection: $completionStyle) {
                    Text(l10n["completion_style_expand"]).tag(AppState.CompletionStyle.expand.rawValue)
                    Text(l10n["completion_style_glance"]).tag(AppState.CompletionStyle.glance.rawValue)
                    Text(l10n["completion_style_off"]).tag(AppState.CompletionStyle.off.rawValue)
                }
            }
            described(l10n["auto_collapse_after_session_jump_desc"]) { Toggle(l10n["auto_collapse_after_session_jump"], isOn: $autoCollapseAfterSessionJump) }
            Picker(selection: $rotationInterval) {
                Text(l10n["3_seconds"]).tag(3); Text(l10n["5_seconds"]).tag(5); Text(l10n["8_seconds"]).tag(8); Text(l10n["10_seconds"]).tag(10)
            } label: {
                Text(l10n["rotation_interval"])
                Text(l10n["rotation_interval_desc"])
            }
            Picker(selection: Binding(get: { pluginSessionMode }, set: { mode in
                guard mode != pluginSessionMode else { return }
                pluginSessionMode = mode
                runtime.appState.applyCurrentPluginSessionMode()
            })) {
                Text(l10n["plugin_session_mode_separate"]).tag("separate")
                Text(l10n["plugin_session_mode_merge"]).tag("merge")
                Text(l10n["plugin_session_mode_hide"]).tag("hide")
            } label: {
                Text(l10n["plugin_session_mode"])
                Text(l10n["plugin_session_mode_desc"])
            }
            described(l10n["follow_up_reminders_desc"]) {
                Picker(l10n["follow_up_reminders"], selection: $followUpReminderMinutes) {
                    ForEach(FollowUpReminderController.intervalChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? l10n["follow_up_off"] : String(format: l10n["follow_up_after_minutes"], minutes)).tag(minutes)
                    }
                }
            }
        }
    }
}
