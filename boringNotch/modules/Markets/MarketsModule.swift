//
//  MarketsModule.swift
//  boringNotch
//

import Combine
import NotchKit
import SwiftUI

@MainActor
final class MarketsModule: NotchModule {
    static let moduleID = "builtin.markets"

    let id = MarketsModule.moduleID
    var title: String { String(localized: "Markets") }
    let systemImage = "chart.line.uptrend.xyaxis"
    let tabOrder = 20

    init() {
        UserDefaults.standard.register(defaults: ["markets.redUp": MarketsFormat.defaultRedUp])
    }

    /// The detail view needs room for a chart; the card board keeps the default size.
    var preferredContentSize: CGSize? {
        MarketDetailStore.shared.symbol == nil ? nil : CGSize(width: 640, height: 290)
    }

    var changes: AnyPublisher<Void, Never> {
        // Delivered on the next turn so the host reads the size after the symbol has actually changed.
        MarketDetailStore.shared.$symbol.map { _ in () }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    func makeExpandedView() -> AnyView { AnyView(MarketsView()) }

    private var deactivateGraceTask: Task<Void, Never>?

    /// Prices stream while the tab is showing, with a brief grace period across quick close/reopen glances.
    func activate() {
        deactivateGraceTask?.cancel()
        deactivateGraceTask = nil
        MarketsStore.shared.start()
        MarketDetailStore.shared.resume()
    }

    func deactivate() {
        deactivateGraceTask?.cancel()
        deactivateGraceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            MarketsStore.shared.stop()
            MarketDetailStore.shared.pause()
        }
    }
}
