import Combine
import NotchKit
import SwiftUI

/// State shared between a running plugin and the view that draws it.
@MainActor
final class PluginModel: ObservableObject {
    enum Status: Equatable { case starting, running, failed(String) }

    @Published var root: UINode?
    @Published var status: Status = .starting
    var send: (HostMessage) -> Void = { _ in }
}

/// A notch tab backed by an external plugin process.
@MainActor
public final class PluginModule: NotchModule {
    public let id: String
    public let systemImage: String
    public let tabOrder: Int

    private let manifest: PluginManifest
    private let language: String
    private let process: PluginProcess
    private let model = PluginModel()
    private let subject = PassthroughSubject<Void, Never>()
    private var level: ModuleAttention = .none
    private var accessory: (symbol: String, text: String?)?
    private var restarts = 0
    private var active = false
    private var stopped = false

    static let maxRestarts = 5

    public var title: String { manifest.name.resolve(for: language) }
    public var attention: ModuleAttention { level }
    public var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    public var closedAccessory: ClosedAccessory? {
        guard let accessory else { return nil }
        let symbol = accessory.symbol, text = accessory.text
        return ClosedAccessory(side: .trailing, width: text == nil ? 26 : 56, view: AnyView(
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 11))
                if let text { Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1) }
            }.foregroundStyle(.white)
        ))
    }

    init(manifest: PluginManifest, directory: URL, language: String) {
        self.manifest = manifest
        self.language = language
        self.id = "plugin." + manifest.id
        self.systemImage = manifest.symbol
        self.tabOrder = manifest.order
        self.process = PluginProcess(manifest: manifest, directory: directory)
        model.send = { [weak self] in self?.process.send($0) }
        wire()
    }

    private func wire() {
        process.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .ready: self.model.status = .running
            case .render(let node):
                self.model.status = .running
                self.model.root = node
            case .attention(let level):
                self.level = level
                self.subject.send()
            case .accessory(let symbol, let text):
                self.accessory = symbol.isEmpty ? nil : (symbol, text)
                self.subject.send()
            }
        }
        process.onExit = { [weak self] status in self?.processExited(status: status) }
    }

    /// Starts the plugin process. Failure to launch shows in the tab instead of throwing.
    public func start() {
        stopped = false
        do {
            try process.start()
            process.send(.hello(locale: language))
            if active { process.send(.activate) }
        } catch {
            model.status = .failed(String(describing: error))
        }
    }

    public func stop() {
        stopped = true
        process.stop()
    }

    private func processExited(status: Int32) {
        guard !stopped else { return }
        guard restarts < Self.maxRestarts else {
            model.status = .failed("exited with status \(status)")
            return
        }
        restarts += 1
        let delay = Double(1 << min(restarts - 1, 4))
        model.status = .starting
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.start()
        }
    }

    public func makeExpandedView() -> AnyView { AnyView(PluginContentView(model: model)) }

    public func activate() { active = true; process.send(.activate) }
    public func deactivate() { active = false; process.send(.deactivate) }
}

// MARK: - Rendering

struct PluginContentView: View {
    @ObservedObject var model: PluginModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) { content }
            .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        Group {
            switch model.status {
            case .failed(let reason):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                    Text(reason).font(.system(size: 11)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            default:
                if let root = model.root {
                    NodeView(node: root) { model.send(.action(id: $0)) }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NodeView: View {
    let node: UINode
    let onAction: (String) -> Void

    var body: some View {
        switch node {
        case .vstack(let spacing, let children):
            VStack(alignment: .leading, spacing: spacing) { ChildrenView(children: children, onAction: onAction) }
        case .hstack(let spacing, let children):
            HStack(spacing: spacing) { ChildrenView(children: children, onAction: onAction) }
        case .text(let string, let style, let tint):
            Text(verbatim: string).font(Self.font(style)).foregroundStyle(Self.color(tint))
        case .symbol(let name, let size, let tint):
            Image(systemName: name).font(.system(size: size)).foregroundStyle(Self.color(tint))
        case .button(let id, let title, let symbol):
            Button { onAction(id) } label: {
                if let symbol { Label(title, systemImage: symbol) } else { Text(verbatim: title) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        case .progress(let value, let label):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: value)
                if let label { Text(verbatim: label).font(.caption2).foregroundStyle(.secondary) }
            }
        case .spacer: Spacer(minLength: 0)
        case .divider: Divider()
        }
    }

    static func font(_ style: UINode.TextStyle) -> Font {
        switch style {
        case .title: return .system(size: 14, weight: .semibold)
        case .body: return .system(size: 12)
        case .caption: return .system(size: 10)
        case .mono: return .system(size: 11, design: .monospaced)
        }
    }

    static func color(_ tint: UINode.Tint) -> Color {
        switch tint {
        case .primary: return .white
        case .secondary: return .gray
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .blue: return .blue
        case .orange: return .orange
        case .pink: return .pink
        }
    }
}

private struct ChildrenView: View {
    let children: [UINode]
    let onAction: (String) -> Void

    var body: some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            NodeView(node: child, onAction: onAction)
        }
    }
}
