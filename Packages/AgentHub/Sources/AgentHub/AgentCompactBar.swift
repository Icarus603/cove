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

    @State private var quotaChipWidth: CGFloat = 0
    @State private var rightWingWidth: CGFloat = 0

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

    private var quotaReserve: QuotaChipLayout.Reserve {
        guard let limit = QuotaChip.limit(appState: appState, enabled: showClaudeQuota, modeRaw: claudeQuotaChip) else { return .none }
        let chipWidth = quotaChipWidth > 0 ? quotaChipWidth : QuotaChip.estimatedWidth(for: limit)
        return QuotaChipLayout.reserve(
            chipWidth: chipWidth, mascotSize: mascotSize, wing: compactWingWidth,
            statusExtra: collapsedStatusExtra, hasNotch: hasNotch, spareWidth: maxPanelWidth - collapsedBarWidth
        )
    }

    private var rightWingReserve: CGFloat {
        CompactRightWingLayout.missing(contentWidth: rightWingWidth, wing: compactWingWidth,
                                       statusExtra: collapsedStatusExtra, hasNotch: hasNotch)
    }

    /// The host centres this bar on the notch and does not shift it, so extra width is always split evenly between
    /// the wings. On a notched screen the bar therefore grows by twice what the needier wing lacks: that wing gets
    /// exactly what it needs and the gap between the wings stays over the notch (growing by only the shortfall would
    /// leave the chip's tail half under the notch). Without a notch the chip just takes its own width.
    private var totalWidth: CGFloat {
        let extra = hasNotch ? 2 * max(quotaReserve.extraWidth, rightWingReserve) : quotaReserve.extraWidth + rightWingReserve
        return collapsedBarWidth + extra
    }

    var body: some View {
        HStack(spacing: 0) {
            CompactLeftWing(appState: appState, expanded: false, mascotSize: mascotSize, hasNotch: hasNotch, showToolStatus: showToolStatus)
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
        .onPreferenceChange(QuotaChipWidthKey.self) { if $0 > 0 { quotaChipWidth = $0 } }
        .onPreferenceChange(CompactRightWingWidthKey.self) { if $0 > 0 { rightWingWidth = $0 } }
    }
}

extension AgentsModule {
    /// There is something to show next to the notch.
    public var isCompactBarVisible: Bool {
        !AgentRuntime.shared.standingAside && !AgentRuntime.shared.appState.sessions.isEmpty
    }

    /// An agent is working or waiting, as opposed to every session sitting idle.
    public var isCompactBarBusy: Bool { AgentRuntime.shared.appState.status != .idle }

    /// CodeIsland's collapsed bar sized for this notch. The host draws it inside the closed notch shape.
    public func makeCompactBar(notchWidth: CGFloat, notchHeight: CGFloat, screenWidth: CGFloat, hasNotch: Bool) -> AnyView {
        AnyView(AgentCompactBar(appState: AgentRuntime.shared.appState, notchWidth: notchWidth, notchHeight: notchHeight,
                                screenWidth: screenWidth, hasNotch: hasNotch))
    }
}
