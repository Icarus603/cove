import CodeIslandCore
import SwiftUI

/// CodeIsland's collapsed bar, for the closed notch: the session mascot (with tool status) on the left,
/// the plan-limit chip and status on the right, and the notch itself in the middle. The sizes follow
/// CodeIsland's own rules, so the mascot is never hidden behind the notch.
struct AgentCompactBar: View {
    var appState: AppState
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let screenWidth: CGFloat
    let hasNotch: Bool

    @ObservedObject private var runtime = AgentRuntime.shared
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus
    @AppStorage(SettingsKey.collapsedWidthScale) private var collapsedWidthScale = SettingsDefaults.collapsedWidthScale
    @AppStorage(SettingsKey.showClaudeQuota) private var showClaudeQuota = SettingsDefaults.showClaudeQuota
    @AppStorage(SettingsKey.claudeQuotaChip) private var claudeQuotaChip = SettingsDefaults.claudeQuotaChip
    @AppStorage(SettingsKey.toolNameWidth) private var toolNameWidth = SettingsDefaults.toolNameWidth

    @State private var quotaChipWidth: CGFloat = 0
    @State private var rightWingWidth: CGFloat = 0
    @State private var leftWingWidth: CGFloat = 0

    private var mascotSize: CGFloat { min(27, notchHeight - 6) }
    private var compactWingWidth: CGFloat { mascotSize + 14 }

    private var effectiveNotchW: CGFloat {
        NotchWidthMetrics.effectiveNotchWidth(notchW: notchWidth, collapsedWidthScale: collapsedWidthScale, hasNotch: hasNotch)
    }

    /// Status and tool-status reserves, split evenly between the two wings.
    private var collapsedStatusExtra: CGFloat {
        let extra: CGFloat = appState.status == .idle ? 0 : 20
        let toolExtra: CGFloat = showToolStatus ? (hasNotch ? screenWidth * 0.03 : screenWidth * 0.04) : 0
        return extra + toolExtra
    }

    private var maxPanelWidth: CGFloat { min(620, screenWidth - 40) }
    private var collapsedBarWidth: CGFloat { effectiveNotchW + compactWingWidth * 2 + collapsedStatusExtra }

    /// Width of whatever sits after the mascot in the left wing: the tool name while a tool runs, else the plan-limit
    /// chip. Measured once laid out; until then the chip's estimate (there is nothing to estimate for a tool name).
    private var leftSlotWidth: CGFloat {
        if quotaChipWidth > 0 { return quotaChipWidth }
        guard let limit = QuotaChip.limit(appState: appState, enabled: showClaudeQuota, modeRaw: claudeQuotaChip) else { return 0 }
        return QuotaChip.estimatedWidth(for: limit)
    }

    /// Fixed width of the slot beside the mascot on a notched screen: the setting, widened to fit the plan-limit chip
    /// when one is shown (the chip has no shortened form). Constant while tools come and go.
    private var slotWidth: CGFloat? {
        guard hasNotch else { return nil }
        let setting = CGFloat(min(max(toolNameWidth, ToolNameSlot.min), ToolNameSlot.max))
        return max(setting, leftSlotWidthForChip)
    }

    private var leftSlotWidthForChip: CGFloat {
        guard let limit = QuotaChip.limit(appState: appState, enabled: showClaudeQuota, modeRaw: claudeQuotaChip) else { return 0 }
        return quotaChipWidth > 0 ? quotaChipWidth : QuotaChip.estimatedWidth(for: limit)
    }

    private var quotaReserve: QuotaChipLayout.Reserve {
        let slot = leftSlotWidth
        guard slot > 0 else { return .none }
        return QuotaChipLayout.reserve(
            chipWidth: slot, mascotSize: mascotSize, wing: compactWingWidth,
            statusExtra: collapsedStatusExtra, hasNotch: hasNotch, spareWidth: maxPanelWidth - collapsedBarWidth
        )
    }

    private var rightWingReserve: CGFloat {
        CompactRightWingLayout.missing(contentWidth: rightWingWidth, wing: compactWingWidth,
                                       statusExtra: collapsedStatusExtra, hasNotch: hasNotch)
    }

    /// The host centres this bar on the notch, so width is always shared evenly between the two wings, and the room
    /// each wing has is (bar width - notch) / 2. On a notched screen the bar is therefore sized from the wings' measured
    /// widths: each side gets whichever is largest of the base wing, the left wing's real content (mascot, tool name or
    /// plan-limit chip) and the right wing's, plus a small gap. Nothing is then estimated, so a long tool name can no
    /// longer slide under the notch. Without a notch the chip just takes its own width.
    private var totalWidth: CGFloat {
        guard hasNotch else { return collapsedBarWidth + quotaReserve.extraWidth + rightWingReserve }
        let gap = QuotaChipLayout.notchGap
        let base = compactWingWidth + collapsedStatusExtra / 2
        let left = leftWingWidth > 0 ? leftWingWidth + gap : 0
        let right = rightWingWidth > 0 ? rightWingWidth + gap : 0
        return effectiveNotchW + 2 * max(base, left, right)
    }

    var body: some View {
        HStack(spacing: 0) {
            CompactLeftWing(appState: appState, expanded: false, mascotSize: mascotSize, hasNotch: hasNotch, showToolStatus: showToolStatus,
                            slotWidth: slotWidth)
            if hasNotch {
                Spacer(minLength: effectiveNotchW)
            } else if showToolStatus {
                CompactToolStatus(appState: appState)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
            CompactRightWing(appState: appState, expanded: false, hasNotch: hasNotch)
        }
        .frame(width: totalWidth, height: notchHeight)
        .onPreferenceChange(QuotaChipWidthKey.self) { quotaChipWidth = $0 }
        .onPreferenceChange(CompactRightWingWidthKey.self) { if $0 > 0 { rightWingWidth = $0 } }
        .onPreferenceChange(CompactLeftWingWidthKey.self) { leftWingWidth = $0 }
    }
}

extension AgentsModule {
    /// There is something to show next to the notch.
    public var isCompactBarVisible: Bool {
        // With the desktop pet on, the mascot lives there and not next to the notch.
        !DesktopPetController.isEnabled && !AgentRuntime.shared.standingAside && !AgentRuntime.shared.appState.sessions.isEmpty
    }

    /// An agent is working or waiting, as opposed to every session sitting idle.
    public var isCompactBarBusy: Bool { !DesktopPetController.isEnabled && AgentRuntime.shared.appState.status != .idle }

    /// CodeIsland's collapsed bar sized for this notch. The host draws it inside the closed notch shape.
    public func makeCompactBar(notchWidth: CGFloat, notchHeight: CGFloat, screenWidth: CGFloat, hasNotch: Bool) -> AnyView {
        AnyView(AgentCompactBar(appState: AgentRuntime.shared.appState, notchWidth: notchWidth, notchHeight: notchHeight,
                                screenWidth: screenWidth, hasNotch: hasNotch))
    }
}
