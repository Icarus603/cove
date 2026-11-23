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

    /// Prices stream only while the tab is showing.
    func activate() {
        MarketsStore.shared.start()
        MarketDetailStore.shared.resume()
    }

    func deactivate() {
        MarketsStore.shared.stop()
        MarketDetailStore.shared.pause()
    }
}
