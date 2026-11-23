//
//  MarketsView.swift
//  boringNotch
//
//  The Markets tab: one card per watched pair with price, 24h change and a 24-hour sparkline, and, when the user
//  has saved a read-only Binance key, the estimated spot balance in the header.
//

import SwiftUI

struct MarketsView: View {
    @ObservedObject private var store = MarketsStore.shared
    @ObservedObject private var detail = MarketDetailStore.shared
    @AppStorage("markets.redUp") private var redUp = MarketsFormat.defaultRedUp
    @AppStorage("markets.hideBalance") private var hideBalance = false

    var body: some View {
        if let symbol = detail.symbol {
            MarketDetailView(symbol: symbol)
        } else {
            board
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.watchlist.isEmpty {
                Text("Add pairs in Settings → Markets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.watchlist, id: \.self) { symbol in
                            MarketCard(symbol: symbol, ticker: store.tickers[symbol], line: store.sparklines[symbol] ?? [], redUp: redUp)
                                .onTapGesture { detail.open(symbol) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let portfolio = store.portfolio {
                Button { hideBalance.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hideBalance ? "eye.slash" : "wallet.bifold").font(.caption2)
                        Text(hideBalance ? "••••••" : "≈ \(MarketsFormat.money(portfolio.total)) USDT")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .privacySensitive()
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Estimated spot balance. Click to hide or show."))
            } else if store.portfolioError != nil {
                Label("Balance unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(Text(store.portfolioError ?? ""))
            }
        }
    }

    private var statusColor: Color {
        switch store.status {
        case .live: return .green
        case .connecting: return .orange
        case .offline: return .red
        case .idle: return .gray
        }
    }

    private var statusText: LocalizedStringKey {
        switch store.status {
        case .live: return "Live · Binance"
        case .connecting: return "Connecting…"
        case .offline: return "Offline, retrying…"
        case .idle: return "Markets"
        }
    }
}

private struct MarketCard: View {
    let symbol: String
    let ticker: MarketTicker?
    let line: [Double]
    let redUp: Bool

    private var parts: (base: String, quote: String) { BinanceClient.split(symbol) }
    private var change: Double { ticker?.changePercent ?? 0 }
    private var tint: Color {
        if ticker == nil || change == 0 { return .gray }
        return change > 0 ? MarketsPalette.up(redUp: redUp) : MarketsPalette.down(redUp: redUp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.base).font(.system(size: 13, weight: .bold))
                if !parts.quote.isEmpty { Text("/" + parts.quote).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            Text(ticker.map { MarketsFormat.price($0.price) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(ticker == nil ? "" : MarketsFormat.percent(change))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
            Sparkline(values: line, tint: tint)
                .frame(height: 26)
        }
        .padding(8)
        .frame(width: 140, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let low = values.min(), let high = values.max() {
                let span = max(high - low, .leastNonzeroMagnitude)
                let points = values.enumerated().map { index, value in
                    CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(values.count - 1),
                            y: geo.size.height * (1 - CGFloat((value - low) / span)))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
