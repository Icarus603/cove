//
//  MarketDetailView.swift
//  boringNotch
//
//  One pair in detail: candlestick chart with indicator switches on the left; 24h range, futures statistics and the
//  order book on the right. Futures figures hide themselves where Binance's futures API is not reachable.
//

import SwiftUI

struct MarketDetailView: View {
    let symbol: String
    @ObservedObject private var detail = MarketDetailStore.shared
    @ObservedObject private var store = MarketsStore.shared
    @AppStorage("markets.redUp") private var redUp = MarketsFormat.defaultRedUp
    @AppStorage("markets.showMA") private var showMA = true
    @AppStorage("markets.showEMA") private var showEMA = false
    @AppStorage("markets.showBoll") private var showBoll = false
    @AppStorage("markets.subPanel") private var subRaw = SubPanel.volume.rawValue
    @State private var hover: Int?
    @State private var hoverPoint: CGPoint?
    /// The chart's window onto the candles: how many fit across, and the time of the right-most one (nil follows live).
    @State private var visible = 72
    @State private var anchor: Date?
    @State private var chartWidth: CGFloat = 420
    @State private var panCarry: CGFloat = 0
    @State private var dragStartEnd: Int?

    private var up: Color { MarketsPalette.up(redUp: redUp) }
    private var down: Color { MarketsPalette.down(redUp: redUp) }
    private var sub: SubPanel { SubPanel(rawValue: subRaw) ?? .volume }
    private var ticker: MarketTicker? { store.tickers[symbol] }
    private var parts: (base: String, quote: String) { BinanceClient.split(symbol) }

    // MARK: Viewport

    private var endIndex: Int {
        let candles = detail.candles
        guard !candles.isEmpty else { return 0 }
        if let anchor, let index = candles.lastIndex(where: { $0.openTime <= anchor }) { return index }
        return candles.count - 1
    }

    /// Points per candle at the current zoom.
    private var step: CGFloat { max((chartWidth - ChartModel.axisWidth) / CGFloat(visible), 1) }

    private func setEnd(_ proposed: Int) {
        let candles = detail.candles
        guard !candles.isEmpty else { return }
        let lowest = max(min(visible, candles.count) - 1, 0)
        let end = min(max(proposed, lowest), candles.count - 1)
        anchor = end >= candles.count - 1 ? nil : candles[end].openTime
        loadOlderIfNeeded()
    }

    private func pan(byCandles delta: CGFloat) {
        panCarry += delta
        let whole = Int(panCarry.rounded(.towardZero))
        guard whole != 0 else { return }
        panCarry -= CGFloat(whole)
        setEnd(endIndex - whole)
    }

    private func zoom(by factor: CGFloat) {
        visible = min(max(Int((CGFloat(visible) * factor).rounded()), 15), 400)
        loadOlderIfNeeded()
    }

    private func resetViewport() {
        visible = 72; anchor = nil; panCarry = 0; dragStartEnd = nil
    }

    /// Asks for the page of older candles once the left edge of the window gets close to the oldest one held.
    private func loadOlderIfNeeded() {
        if endIndex - visible + 1 < 40 { detail.loadOlder() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topBar
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    chips
                    readout
                    CandleChart(candles: detail.candles,
                                overlays: ChartOverlays(ma: showMA, ema: showEMA, boll: showBoll),
                                sub: sub, upColor: up, downColor: down, interval: detail.interval, baseAsset: parts.base,
                                visibleCount: visible, endIndex: endIndex, hoverIndex: $hover, hoverPoint: $hoverPoint)
                        .background(GeometryReader { geo in
                            Color.clear
                                .onAppear { chartWidth = geo.size.width }
                                .onChange(of: geo.size.width) { _, width in chartWidth = width }
                        })
                        .background(ChartInput(
                            onScroll: { dx, dy, precise in
                                if abs(dx) > abs(dy) { pan(byCandles: dx / step) }
                                else { zoom(by: exp(-dy * (precise ? 0.01 : 0.08))) }
                            },
                            onMagnify: { zoom(by: max(1 - $0, 0.2)) }))
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { value in
                                if dragStartEnd == nil { dragStartEnd = endIndex }
                                setEnd((dragStartEnd ?? endIndex) - Int((value.translation.width / step).rounded()))
                            }
                            .onEnded { _ in dragStartEnd = nil })
                        .onTapGesture(count: 2) { resetViewport() }
                        .help(Text("Drag to move through history, scroll or pinch to zoom, double-click to reset."))
                        .overlay(alignment: .topLeading) {
                            if detail.isLoadingOlder { ProgressView().controlSize(.mini).padding(4) }
                        }
                        .overlay {
                            if detail.candles.isEmpty {
                                if detail.loadFailed {
                                    VStack(spacing: 6) {
                                        Text("Could not load the chart.").font(.callout).foregroundStyle(.secondary)
                                        Button("Retry") { detail.retry() }.controlSize(.small)
                                    }
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                sidePanel
                    .frame(width: 190)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if DEBUG
        // scripts/shots.sh drives the chart through this: userInfo "pan" (candles back in time), "zoom" (factor), "reset".
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CoveChartCommand"))) { note in
            if let candles = note.userInfo?["pan"] as? Int { setEnd(endIndex - candles) }
            if let factor = note.userInfo?["zoom"] as? Double { zoom(by: CGFloat(factor)) }
            if note.userInfo?["reset"] != nil { resetViewport() }
            if let fraction = note.userInfo?["hover"] as? Double {
                let point = CGPoint(x: (chartWidth - ChartModel.axisWidth) * fraction, y: 70)
                hoverPoint = point
                let count = detail.candles.count
                hover = count == 0 ? nil : max(0, min(endIndex, endIndex - Int((1 - fraction) * Double(visible))))
            }
        }
        #endif
        .onChange(of: detail.interval) { _, _ in resetViewport() }
        .onChange(of: symbol) { _, _ in resetViewport() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { detail.close() } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.base).font(.system(size: 14, weight: .bold))
                if !parts.quote.isEmpty { Text("/" + parts.quote).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if let ticker {
                Text(MarketsFormat.price(ticker.price)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(MarketsFormat.percent(ticker.changePercent))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ticker.changePercent == 0 ? Color.gray : (ticker.changePercent > 0 ? up : down))
            }
            Spacer()
            Picker("", selection: Binding(get: { detail.interval }, set: { detail.setInterval($0) })) {
                ForEach(CandleInterval.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 232)
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            chip("MA", isOn: $showMA, color: .yellow)
            chip("EMA", isOn: $showEMA, color: .cyan)
            chip("BOLL", isOn: $showBoll, color: .gray)
            if anchor != nil {
                Button { anchor = nil; panCarry = 0 } label: {
                    Label("Latest", systemImage: "forward.end.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.effectiveAccent.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            ForEach(SubPanel.allCases) { panel in
                chip(panel.rawValue, isOn: Binding(get: { sub == panel }, set: { _ in subRaw = panel.rawValue }), color: .white)
            }
        }
    }

    private func chip(_ title: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(isOn.wrappedValue ? Color.black : Color.secondary)
                .background(Capsule().fill(isOn.wrappedValue ? color.opacity(0.9) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    /// OHLC of the hovered candle, or of the latest one.
    private var readout: some View {
        let candle = hover.flatMap { detail.candles.indices.contains($0) ? detail.candles[$0] : nil }
            ?? (detail.candles.indices.contains(endIndex) ? detail.candles[endIndex] : nil)
        // The numbers change with every candle the pointer passes over, and so does how wide the text wants to be. This column is
        // tight, so a width that moved with the digits moved everything beside it (the interval picker at the top right swung
        // left and right as the pointer crossed the chart). The text is therefore an overlay on a row of fixed height that takes
        // whatever width the column has, and has no say in it.
        return Color.clear
            .frame(maxWidth: .infinity, minHeight: 11, maxHeight: 11)
            .overlay(alignment: .leading) {
                Group {
                    if let c = candle {
                        Text("O \(MarketsFormat.price(c.open))  H \(MarketsFormat.price(c.high))  L \(MarketsFormat.price(c.low))  C \(MarketsFormat.price(c.close))  V \(MarketsFormat.compact(c.volume))")
                    } else {
                        Text(" ")
                    }
                }
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    // MARK: Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("24h") {
                row("High", ticker.map { MarketsFormat.price($0.high) })
                row("Low", ticker.map { MarketsFormat.price($0.low) })
                row("Turnover", ticker.map { MarketsFormat.compact($0.quoteVolume) + " " + parts.quote })
            }
            if let stats = detail.derivatives {
                section("Futures") {
                    row("Funding", stats.fundingRate.map { String(format: "%+.4f%%", $0 * 100) },
                        tint: stats.fundingRate.map { $0 > 0 ? up : ($0 < 0 ? down : .secondary) })
                    if let next = stats.nextFunding {
                        row("Next funding", next.formatted(date: .omitted, time: .shortened))
                    }
                    row("Open interest", stats.openInterest.map { MarketsFormat.compact($0 * (stats.markPrice ?? 0)) + " USDT" })
                    if let longShare = stats.longAccountShare {
                        VStack(alignment: .leading, spacing: 2) {
                            row("Long/short", stats.longShortRatio.map { String(format: "%.2f", $0) })
                            splitBar(left: longShare, leftColor: up, rightColor: down)
                        }
                    }
                    row("Taker buy/sell", stats.takerBuySellRatio.map { String(format: "%.2f", $0) })
                }
            } else if detail.derivativesChecked {
                Text("Futures data is not available for this pair or region.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let book = detail.book, let share = book.bidShare() {  // ±0.1% of the mid price
                section("Order book") {
                    splitBar(left: share, leftColor: up, rightColor: down)
                    HStack {
                        Text(String(format: "%.0f%%", share * 100)).foregroundStyle(up)
                        Spacer()
                        Text(String(format: "%.0f%%", (1 - share) * 100)).foregroundStyle(down)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    row("Bid", book.bids.first.map { MarketsFormat.price($0.price) }, tint: up)
                    row("Ask", book.asks.first.map { MarketsFormat.price($0.price) }, tint: down)
                    if let spread = book.spread { row("Spread", MarketsFormat.spread(spread)) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String?, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value ?? "—")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func splitBar(left: Double, leftColor: Color, rightColor: Color) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                Rectangle().fill(leftColor.opacity(0.8)).frame(width: max(geo.size.width * CGFloat(left) - 0.5, 0))
                Rectangle().fill(rightColor.opacity(0.8))
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}
