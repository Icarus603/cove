import CodeIslandCore
import Combine
import NotchKit
import Observation
import SwiftUI

/// The notch tab for every coding agent CodeIsland understands (Claude Code,
/// Codex, Gemini CLI, Cursor and 30+ more).
@MainActor
public final class AgentsModule: NotchModule {
    public let id = "builtin.agents"
    public let systemImage = "sparkles"
    public let tabOrder = 20

    private let runtime = AgentRuntime.shared
    private let subject = PassthroughSubject<Void, Never>()
    private var trackingActive = true
    /// Natural height of the tab's content, measured by its view.
    private var measuredHeight: CGFloat = 0

    /// Tallest content the notch can hold below its tab bar; taller content scrolls.
    static let maxContentHeight: CGFloat = 410

    public var title: String { L10n.shared["agents_tab"] }

    public var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    public var attention: ModuleAttention {
        let state = runtime.appState
        let defaults = UserDefaults.standard
        let wantsPermission = defaults.object(forKey: SettingsKey.autoExpandOnPermission) as? Bool ?? SettingsDefaults.autoExpandOnPermission
        let wantsQuestion = defaults.object(forKey: SettingsKey.autoExpandOnQuestion) as? Bool ?? SettingsDefaults.autoExpandOnQuestion
        switch state.surface {
        case .approvalCard: return wantsPermission ? .needsInput : .active
        case .questionCard: return wantsQuestion ? .needsInput : .active
        case .completionCard: return AppState.completionStyle() == .expand ? .needsInput : .active
        default: break
        }
        if !state.permissionQueue.isEmpty { return wantsPermission ? .needsInput : .active }
        if !state.questionQueue.isEmpty { return wantsQuestion ? .needsInput : .active }
        return state.sessions.values.contains { $0.status != .idle } ? .active : .none
    }

    public init() {
        runtime.start()
        observe()
    }

    /// Re-arms Observation tracking: AppState is @Observable, so any change to what
    /// `attention` or `closedAccessory` read fires once and must be re-registered.
    private func observe() {
        guard trackingActive else { return }
        withObservationTracking {
            _ = self.attention
            _ = self.isCompactBarVisible
            _ = self.isCompactBarBusy
            _ = AgentRuntime.shared.appState.sessions.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.subject.send()
                self.observe()
            }
        }
    }

    /// The notch grows to the content (a pending approval is taller than an empty list) up to a cap.
    public var preferredContentSize: CGSize? {
        guard measuredHeight > 0 else { return nil }
        return CGSize(width: 600, height: min(measuredHeight + 12, Self.maxContentHeight))
    }

    func reportContentHeight(_ height: CGFloat) {
        guard abs(height - measuredHeight) > 1 else { return }
        measuredHeight = height
        subject.send()
    }

    public func makeExpandedView() -> AnyView {
        AnyView(AgentsExpandedView(runtime: runtime) { [weak self] in self?.reportContentHeight($0) })
    }

    public func activate() {
        if runtime.appState.surface == .collapsed { runtime.appState.surface = .sessionList }
    }

    public func deactivate() {
        // A pending approval or question stays up; only the plain list folds away.
        if runtime.appState.surface == .sessionList { runtime.appState.surface = .collapsed }
    }
}

// MARK: - Expanded view

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AgentsExpandedView: View {
    @ObservedObject var runtime: AgentRuntime
    var onHeight: (CGFloat) -> Void = { _ in }
    @ObservedObject private var l10n = L10n.shared
    var appState: AppState { runtime.appState }
    @State private var removalBannerHeight: CGFloat = 50

    var body: some View {
        // The content reports its natural height so the notch can grow to fit it; whatever does not fit scrolls.
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                if runtime.standingAside {
                    notice(icon: "exclamationmark.triangle", text: l10n["agents_aside"])
                } else {
                    surfaceContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeightKey.self) { onHeight($0) }
    }

    private var emptyState: some View {
        let watching = runtime.tools().filter(\.detected).map(\.name)
        return VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.gray)
            Text(l10n["agents_empty"]).font(.system(size: 11)).foregroundStyle(.gray).multilineTextAlignment(.center)
            if !watching.isEmpty {
                Text(String(format: l10n["agents_watching"], watching.prefix(6).joined(separator: " · ")))
                    .font(.system(size: 10)).foregroundStyle(.gray.opacity(0.7)).multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func notice(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.gray)
            Text(text).font(.system(size: 11)).foregroundStyle(.gray).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A card whose request is gone (just answered, or expired) is not drawn: the list takes over,
    /// so the notch never shows an empty black area.
    private var effectiveSurface: IslandSurface {
        switch appState.surface {
        case .approvalCard(let sid) where appState.pendingPermission(forSession: sid) == nil: return .sessionList
        case .questionCard(let sid) where appState.pendingQuestion(forSession: sid) == nil && appState.previewQuestionPayload == nil: return .sessionList
        case .completionCard where appState.justCompletedSessionId.map({ appState.sessions[$0] == nil }) ?? true: return .sessionList
        default: return appState.surface
        }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch effectiveSurface {
        case .approvalCard(let sid):
            if let pending = appState.pendingPermission(forSession: sid) {
                ApprovalBar(
                    tool: pending.event.toolName ?? "Unknown",
                    toolInput: pending.event.toolInput,
                    queuePosition: appState.permissionQueuePosition(forSession: sid),
                    queueTotal: appState.permissionQueue.count,
                    session: appState.sessions[sid],
                    sessionId: sid,
                    appState: appState,
                    alwaysScope: pending.alwaysScope,
                    onAllow: { appState.approvePermission(always: false, expectedSessionId: sid) },
                    onAlwaysAllow: { appState.approvePermission(always: true, expectedSessionId: sid) },
                    onDeny: { appState.denyPermission(expectedSessionId: sid) },
                    onDismiss: { appState.dismissPermissionPrompt(expectedSessionId: sid) }
                )
            }
        case .questionCard(let sid):
            let session = appState.sessions[sid]
            if let q = appState.pendingQuestion(forSession: sid) {
                QuestionBar(
                    question: q.question.question,
                    options: q.question.options,
                    descriptions: q.question.descriptions,
                    allQuestions: q.askUserQuestionState?.items ?? [],
                    requestId: q.id,
                    sessionSource: session?.source,
                    sessionContext: session?.cwd,
                    session: session,
                    sessionId: sid,
                    appState: appState,
                    queuePosition: appState.questionQueuePosition(forSession: sid),
                    queueTotal: appState.questionQueue.count,
                    onAnswer: { appState.answerQuestion($0, expectedSessionId: sid) },
                    onAnswerMulti: { appState.answerQuestionMulti($0, expectedSessionId: sid) },
                    onSkip: { appState.skipQuestion(expectedSessionId: sid) },
                    onDismiss: { appState.dismissQuestion(expectedSessionId: sid) }
                )
                .id(q.id)
            }
        case .completionCard:
            SessionListView(appState: appState, onlySessionId: appState.justCompletedSessionId)
        case .sessionList, .collapsed:
            if appState.sessions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if let pending = appState.pendingIdleSessionRemoval {
                        IdleSessionRemovalBanner(
                            count: pending.cardCount,
                            onCancel: appState.cancelIdleSessionRemoval,
                            onRemove: appState.confirmIdleSessionRemoval
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { removalBannerHeight = $0 }
                    }
                    SessionListView(
                        appState: appState,
                        onlySessionId: nil,
                        reservedHeight: appState.pendingIdleSessionRemoval == nil ? 0 : removalBannerHeight
                    )
                }
            }
        }
    }
}
