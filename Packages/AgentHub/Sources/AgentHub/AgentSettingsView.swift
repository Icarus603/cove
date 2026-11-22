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

    // Content
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @AppStorage(SettingsKey.sessionListDensity) private var density = SettingsDefaults.sessionListDensity
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.aiMessageLines) private var aiMessageLines = SettingsDefaults.aiMessageLines
    @AppStorage(SettingsKey.showAgentDetails) private var showAgentDetails = SettingsDefaults.showAgentDetails
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus
    @AppStorage(SettingsKey.showProjectName) private var showProjectName = SettingsDefaults.showProjectName
    @AppStorage(SettingsKey.showGitBranch) private var showGitBranch = SettingsDefaults.showGitBranch
    @AppStorage(SettingsKey.showTaskProgress) private var showTaskProgress = SettingsDefaults.showTaskProgress
    @AppStorage(SettingsKey.showSessionRecap) private var showSessionRecap = SettingsDefaults.showSessionRecap
    @AppStorage(SettingsKey.showModelLabel) private var showModelLabel = SettingsDefaults.showModelLabel
    @AppStorage(SettingsKey.showUsageStats) private var showUsageStats = SettingsDefaults.showUsageStats
    @AppStorage(SettingsKey.showClaudeQuota) private var showClaudeQuota = SettingsDefaults.showClaudeQuota
    @AppStorage(SettingsKey.claudeQuotaChip) private var claudeQuotaChip = SettingsDefaults.claudeQuotaChip

    // Sound
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @AppStorage(SettingsKey.soundVolume) private var soundVolume = SettingsDefaults.soundVolume
    @AppStorage(SettingsKey.soundSessionStart) private var soundSessionStart = SettingsDefaults.soundSessionStart
    @AppStorage(SettingsKey.soundTaskComplete) private var soundTaskComplete = SettingsDefaults.soundTaskComplete
    @AppStorage(SettingsKey.soundTaskError) private var soundTaskError = SettingsDefaults.soundTaskError
    @AppStorage(SettingsKey.soundApprovalNeeded) private var soundApprovalNeeded = SettingsDefaults.soundApprovalNeeded
    @AppStorage(SettingsKey.soundPromptSubmit) private var soundPromptSubmit = SettingsDefaults.soundPromptSubmit
    @AppStorage(SettingsKey.quietHoursEnabled) private var quietHoursEnabled = SettingsDefaults.quietHoursEnabled
    @AppStorage(SettingsKey.quietHoursStart) private var quietHoursStart = SettingsDefaults.quietHoursStart
    @AppStorage(SettingsKey.quietHoursEnd) private var quietHoursEnd = SettingsDefaults.quietHoursEnd
    @AppStorage(SettingsKey.autoMuteWhenAway) private var autoMuteWhenAway = SettingsDefaults.autoMuteWhenAway

    @State private var tools: [AgentRuntime.AgentTool] = []
    @State private var busy = false

    public init() {}

    public var body: some View {
        Form {
            toolsSection
            behaviorSection
            contentSection
            soundSection
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
            described(l10n["follow_up_reminders_desc"]) {
                Picker(l10n["follow_up_reminders"], selection: $followUpReminderMinutes) {
                    ForEach(FollowUpReminderController.intervalChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? l10n["follow_up_off"] : String(format: l10n["follow_up_after_minutes"], minutes)).tag(minutes)
                    }
                }
            }
        }
    }

    // MARK: Content

    private var contentSection: some View {
        Section(l10n["content"]) {
            Picker(l10n["max_visible_sessions"], selection: $maxVisibleSessions) {
                Text("3").tag(3); Text("5").tag(5); Text("8").tag(8); Text("10").tag(10)
                Text(l10n["unlimited"]).tag(99)
            }
            described(l10n["session_list_density_desc"]) {
                Picker(l10n["session_list_density"], selection: $density) {
                    ForEach(SessionListDensity.allCases, id: \.self) { value in
                        Text(l10n[value.titleKey]).tag(value.rawValue)
                    }
                }
            }
            Picker(l10n["content_font_size"], selection: $contentFontSize) {
                ForEach(ContentFontSize.choices, id: \.self) { size in
                    Text(size == SettingsDefaults.contentFontSize ? l10n["11pt_default"] : "\(size)pt").tag(size)
                }
            }
            Picker(l10n["ai_reply_lines"], selection: $aiMessageLines) {
                Text(l10n["1_line_default"]).tag(1); Text(l10n["2_lines"]).tag(2); Text(l10n["3_lines"]).tag(3)
                Text(l10n["5_lines"]).tag(5); Text(l10n["unlimited"]).tag(0)
            }
            Toggle(l10n["show_agent_details"], isOn: $showAgentDetails)
            Toggle(l10n["show_tool_status"], isOn: $showToolStatus)
            described(l10n["show_project_name_desc"]) { Toggle(l10n["show_project_name"], isOn: $showProjectName) }
            described(l10n["show_git_branch_desc"]) { Toggle(l10n["show_git_branch"], isOn: $showGitBranch) }
            described(l10n["show_task_progress_desc"]) { Toggle(l10n["show_task_progress"], isOn: $showTaskProgress) }
            described(l10n["show_session_recap_desc"]) { Toggle(l10n["show_session_recap"], isOn: $showSessionRecap) }
            described(l10n["show_model_label_desc"]) { Toggle(l10n["show_model_label"], isOn: $showModelLabel) }
            described(l10n["show_usage_stats_desc"]) { Toggle(l10n["show_usage_stats"], isOn: $showUsageStats) }
            described(l10n["show_claude_quota_desc"]) { Toggle(l10n["show_claude_quota"], isOn: $showClaudeQuota) }
            Picker(l10n["claude_quota_chip"], selection: $claudeQuotaChip) {
                Text(l10n["quota_chip_off"]).tag(ClaudeQuotaChipMode.off.rawValue)
                Text(l10n["quota_chip_auto"]).tag(ClaudeQuotaChipMode.auto.rawValue)
                Text(l10n["quota_chip_session"]).tag(ClaudeQuotaChipMode.session.rawValue)
                Text(l10n["quota_chip_weekly"]).tag(ClaudeQuotaChipMode.weeklyAll.rawValue)
                Text(l10n["quota_chip_weekly_model"]).tag(ClaudeQuotaChipMode.weeklyScoped.rawValue)
            }
            .disabled(!showClaudeQuota)
        }
    }

    // MARK: Sound

    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var soundSection: some View {
        Section(l10n["agents_sound"]) {
            Toggle(l10n["enable_sound"], isOn: $soundEnabled)
            if soundEnabled {
                HStack {
                    Text(l10n["volume"])
                    Slider(value: Binding(get: { Double(soundVolume) }, set: { soundVolume = Int($0) }), in: 0...100, step: 1)
                    Text("\(soundVolume)%").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle(l10n["session_start"], isOn: $soundSessionStart)
                Toggle(l10n["task_complete"], isOn: $soundTaskComplete)
                Toggle(l10n["task_error"], isOn: $soundTaskError)
                Toggle(l10n["approval_needed"], isOn: $soundApprovalNeeded)
                Toggle(l10n["task_confirmation"], isOn: $soundPromptSubmit)
                described(l10n["quiet_hours_desc"]) { Toggle(l10n["quiet_hours"], isOn: $quietHoursEnabled) }
                if quietHoursEnabled {
                    DatePicker(l10n["quiet_hours_start"], selection: minutesBinding($quietHoursStart), displayedComponents: .hourAndMinute)
                    DatePicker(l10n["quiet_hours_end"], selection: minutesBinding($quietHoursEnd), displayedComponents: .hourAndMinute)
                }
                described(l10n["auto_mute_when_away_desc"]) { Toggle(l10n["auto_mute_when_away"], isOn: $autoMuteWhenAway) }
            }
        }
    }
}
