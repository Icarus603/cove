//
//  CandleChart.swift
//  boringNotch
//
//  Candlestick chart drawn with Canvas: candles, optional MA / EMA / Bollinger overlays, and one sub-panel
//  (volume, RSI or MACD). Indicators are computed over every candle loaded and then cut to the visible window, so
//  the lines are already warm at the left edge.
//

import SwiftUI

enum SubPanel: String, CaseIterable, Identifiable {
    case volume = "VOL", rsi = "RSI", macd = "MACD"
    var id: String { rawValue }
}

struct ChartOverlays: Equatable {
    var ma = true
    var ema = false
    var boll = false
}

struct CandleChart: View {
    let candles: [Candle]
    let overlays: ChartOverlays
    let sub: SubPanel
    let upColor: Color
    let downColor: Color
    /// How many candles fit across the plot, and the index of the right-most one shown.
    let visibleCount: Int
    let endIndex: Int
    @Binding var hoverIndex: Int?

    var body: some View {
        let model = ChartModel(candles: candles, overlays: overlays, sub: sub, up: upColor, down: downColor, hover: hoverIndex,
                               visible: visibleCount, endIndex: endIndex)
        GeometryReader { geo in
            Canvas { context, size in model.draw(&context, size: size) }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverIndex = model.index(atX: point.x, width: geo.size.width)
                    case .ended: hoverIndex = nil
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// Everything the Canvas needs, computed once per render.
struct ChartModel {
    static let axisWidth: CGFloat = 52

    let candles: [Candle]
    let overlays: ChartOverlays
    let sub: SubPanel
    let up: Color
    let down: Color
    let hover: Int?
    let visible: Int
    let endIndex: Int

    private let closes: [Double]
    private let ma7: [Double?], ma25: [Double?], ema12: [Double?], ema26: [Double?]
    private let boll: Indicators.Bollinger
    private let rsi: [Double?]
    private let macd: Indicators.MACD

    init(candles: [Candle], overlays: ChartOverlays, sub: SubPanel, up: Color, down: Color, hover: Int?, visible: Int, endIndex: Int) {
        self.candles = candles; self.overlays = overlays; self.sub = sub; self.up = up; self.down = down; self.hover = hover
        self.visible = max(visible, 1); self.endIndex = min(max(endIndex, 0), max(candles.count - 1, 0))
        closes = candles.map(\.close)
        ma7 = overlays.ma ? Indicators.sma(closes, period: 7) : []
        ma25 = overlays.ma ? Indicators.sma(closes, period: 25) : []
        ema12 = overlays.ema ? Indicators.ema(closes, period: 12) : []
        ema26 = overlays.ema ? Indicators.ema(closes, period: 26) : []
        boll = overlays.boll ? Indicators.bollinger(closes) : Indicators.Bollinger(middle: [], upper: [], lower: [])
        rsi = sub == .rsi ? Indicators.rsi(closes) : []
        macd = sub == .macd ? Indicators.macd(closes) : Indicators.MACD(line: [], signal: [], histogram: [])
    }

    /// Candles actually drawn, and the index of the first of them. Fewer than `visible` near the start of history.
    private var count: Int { candles.isEmpty ? 0 : min(visible, endIndex + 1) }
    private var start: Int { endIndex + 1 - count }

    /// Maps a horizontal position in a canvas `width` wide to a candle index. The newest candle sits at the right edge
    /// of the plot, so a short history leaves the gap on the left.
    func index(atX x: CGFloat, width: CGFloat) -> Int? {
        guard count > 0, width > Self.axisWidth else { return nil }
        let plotWidth = width - Self.axisWidth
        let step = plotWidth / CGFloat(visible)
        let index = endIndex - Int(((plotWidth - x) / step).rounded(.down))
        return (start...endIndex).contains(index) ? index : nil
    }

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard count > 0 else { return }
        let plotW = size.width - Self.axisWidth
        let step = plotW / CGFloat(visible)
        let priceH = size.height * 0.68
        let subTop = priceH + 8
        let subH = max(size.height - subTop, 1)

        // Price range over what is visible (bands included when shown).
        let shown = candles[start...endIndex]
        var low = shown.map(\.low).min() ?? 0
        var high = shown.map(\.high).max() ?? 1
        if overlays.boll {
            for i in start...endIndex {
                if let u = boll.upper[i] { high = max(high, u) }
                if let l = boll.lower[i] { low = min(low, l) }
            }
        }
        let pad = (high - low) * 0.06
        low -= pad; high += pad
        if high - low <= 0 { high = low + 1 }
        func y(_ price: Double) -> CGFloat { priceH * CGFloat(1 - (price - low) / (high - low)) }
        func x(_ index: Int) -> CGFloat { plotW - (CGFloat(endIndex - index) + 0.5) * step }

        // Grid and price labels.
        for k in 0...3 {
            let price = low + (high - low) * Double(k) / 3
            let yy = y(price)
            var line = Path(); line.move(to: CGPoint(x: 0, y: yy)); line.addLine(to: CGPoint(x: plotW, y: yy))
            context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
            context.draw(Text(MarketsFormat.axisPrice(price)).font(.system(size: 8, design: .monospaced)).foregroundColor(.white.opacity(0.45)),
                         at: CGPoint(x: plotW + 4, y: min(max(yy, 6), priceH - 6)), anchor: .leading)
        }

        // Candles.
        let bodyWidth = max(step * 0.62, 1)
        for i in start...endIndex {
            let c = candles[i]
            let color = c.isUp ? up : down
            let cx = x(i)
            var wick = Path()
            wick.move(to: CGPoint(x: cx, y: y(c.high))); wick.addLine(to: CGPoint(x: cx, y: y(c.low)))
            context.stroke(wick, with: .color(color), lineWidth: 1)
            let top = y(max(c.open, c.close)), bottom = y(min(c.open, c.close))
            context.fill(Path(CGRect(x: cx - bodyWidth / 2, y: top, width: bodyWidth, height: max(bottom - top, 1))), with: .color(color))
        }

        // Overlays.
        func plot(_ values: [Double?], _ color: Color, width: CGFloat = 1) {
            guard values.count == candles.count else { return }
            var path = Path(); var started = false
            for i in start...endIndex {
                guard let v = values[i] else { continue }
                let point = CGPoint(x: x(i), y: y(v))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        if overlays.ma { plot(ma7, .yellow); plot(ma25, .purple) }
        if overlays.ema { plot(ema12, .cyan); plot(ema26, .orange) }
        if overlays.boll { plot(boll.upper, .gray); plot(boll.middle, .gray.opacity(0.6), width: 0.7); plot(boll.lower, .gray) }

        // Latest price: a dashed line across the plot and a tag on the axis, like the exchange's own chart.
        if let last = candles.last {
            let yy = y(last.close)
            if yy >= 0, yy <= priceH {
                let tint = last.isUp ? up : down
                var line = Path(); line.move(to: CGPoint(x: 0, y: yy)); line.addLine(to: CGPoint(x: plotW, y: yy))
                context.stroke(line, with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                let tag = CGRect(x: plotW + 1, y: yy - 6, width: Self.axisWidth - 1, height: 12)
                context.fill(Path(roundedRect: tag, cornerRadius: 2), with: .color(tint))
                context.draw(Text(MarketsFormat.axisPrice(last.close)).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(.white),
                             at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
            }
        }

        drawSub(&context, plotW: plotW, step: step, top: subTop, height: subH, x: x)

        if let hover, hover >= start, hover <= endIndex {
            var line = Path(); line.move(to: CGPoint(x: x(hover), y: 0)); line.addLine(to: CGPoint(x: x(hover), y: size.height))
            context.stroke(line, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
        }
    }

    private func drawSub(_ context: inout GraphicsContext, plotW: CGFloat, step: CGFloat, top: CGFloat, height: CGFloat,
                         x: (Int) -> CGFloat) {
        let label = Text(sub.rawValue).font(.system(size: 8, weight: .medium)).foregroundColor(.white.opacity(0.4))
        context.draw(label, at: CGPoint(x: plotW + 4, y: top + 6), anchor: .leading)
        let barWidth = max(step * 0.62, 1)

        switch sub {
        case .volume:
            let maxVolume = candles[start...endIndex].map(\.volume).max() ?? 1
            for i in start...endIndex {
                let c = candles[i]
                let h = height * CGFloat(c.volume / max(maxVolume, .leastNonzeroMagnitude))
                context.fill(Path(CGRect(x: x(i) - barWidth / 2, y: top + height - h, width: barWidth, height: h)),
                             with: .color((c.isUp ? up : down).opacity(0.55)))
            }
        case .rsi:
            func y(_ v: Double) -> CGFloat { top + height * CGFloat(1 - v / 100) }
            for level in [30.0, 70.0] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y(level))); line.addLine(to: CGPoint(x: plotW, y: y(level)))
                context.stroke(line, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
            var path = Path(); var started = false
            for i in start...endIndex {
                guard i < rsi.count, let v = rsi[i] else { continue }
                let point = CGPoint(x: x(i), y: y(v))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            context.stroke(path, with: .color(.purple), lineWidth: 1)
            if endIndex < rsi.count, let last = rsi[endIndex] {
                context.draw(Text(String(format: "%.0f", last)).font(.system(size: 8, design: .monospaced)).foregroundColor(.purple),
                             at: CGPoint(x: plotW + 4, y: top + 18), anchor: .leading)
            }
        case .macd:
            let values = (start...endIndex).flatMap { i -> [Double] in
                [macd.line[i], macd.signal[i], macd.histogram[i]].compactMap { $0 }
            }
            let bound = max(values.map { abs($0) }.max() ?? 1, .leastNonzeroMagnitude)
            func y(_ v: Double) -> CGFloat { top + height / 2 * CGFloat(1 - v / bound) }
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: plotW, y: y(0)))
            context.stroke(zero, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            for i in start...endIndex {
                guard let h = macd.histogram[i] else { continue }
                let y0 = y(0), y1 = y(h)
                context.fill(Path(CGRect(x: x(i) - barWidth / 2, y: min(y0, y1), width: barWidth, height: max(abs(y1 - y0), 0.5))),
                             with: .color((h >= 0 ? up : down).opacity(0.6)))
            }
            for (series, color) in [(macd.line, Color.yellow), (macd.signal, Color.purple)] {
                var path = Path(); var started = false
                for i in start...endIndex {
                    guard let v = series[i] else { continue }
                    let point = CGPoint(x: x(i), y: y(v))
                    if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                }
                context.stroke(path, with: .color(color), lineWidth: 1)
            }
        }
    }
}
