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
    let interval: CandleInterval
    /// Coin shown after the volume in the tooltip (BTC for BTCUSDT).
    let baseAsset: String
    /// How many candles fit across the plot, and the index of the right-most one shown.
    let visibleCount: Int
    let endIndex: Int
    @Binding var hoverIndex: Int?
    @Binding var hoverPoint: CGPoint?

    var body: some View {
        let model = ChartModel(candles: candles, overlays: overlays, sub: sub, up: upColor, down: downColor, hover: hoverIndex,
                               hoverPoint: hoverPoint, interval: interval, visible: visibleCount, endIndex: endIndex)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in model.draw(&context, size: size) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoverPoint = point
                            hoverIndex = model.index(atX: point.x, width: geo.size.width)
                        case .ended:
                            hoverPoint = nil; hoverIndex = nil
                        }
                    }
                // The numbers for the candle under the pointer, on the side away from it so it never covers what is read.
                if let index = hoverIndex, let data = model.tooltip(at: index, baseAsset: baseAsset) {
                    ChartTooltip(data: data)
                        .frame(width: geo.size.width - ChartModel.axisWidth, height: geo.size.height - ChartModel.timeAxisHeight,
                               alignment: (hoverPoint?.x ?? 0) > (geo.size.width - ChartModel.axisWidth) / 2 ? .topLeading : .topTrailing)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ChartTooltipData {
    struct Row: Identifiable {
        let id = UUID()
        var label: String
        var value: String
        var labelColor: Color = .secondary
        var valueColor: Color = .primary
    }
    var time: String
    var rows: [Row]
    var indicators: [Row]
}

private struct ChartTooltip: View {
    let data: ChartTooltipData

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(data.time).font(.system(size: 10, weight: .bold, design: .monospaced))
            Divider().overlay(Color.white.opacity(0.15))
            ForEach(data.rows) { row in line(row) }
            if !data.indicators.isEmpty {
                Divider().overlay(Color.white.opacity(0.15))
                ForEach(data.indicators) { row in line(row) }
            }
        }
        .padding(8)
        .frame(width: 164)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.6))
    }

    private func line(_ row: ChartTooltipData.Row) -> some View {
        HStack(spacing: 6) {
            Text(row.label).foregroundStyle(row.labelColor)
            Spacer(minLength: 4)
            Text(row.value).foregroundStyle(row.valueColor)
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
    }
}

/// Date and time text for the axis and tooltip, in the user's time zone with Latin digits.
enum ChartTime {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    static let hourMinute = formatter("HH:mm")
    static let monthDay = formatter("MM/dd")
    static let monthDayTime = formatter("MM/dd HH:mm")
    static let yearMonth = formatter("yyyy/MM")
    static let year = formatter("yyyy")
    static let yearMonthDay = formatter("yyyy/MM/dd")
    static let full = formatter("yyyy-MM-dd HH:mm")
    static let fullDay = formatter("yyyy-MM-dd")
}

/// Everything the Canvas needs, computed once per render.
struct ChartModel {
    static let axisWidth: CGFloat = 52
    /// Strip along the bottom for the time labels.
    static let timeAxisHeight: CGFloat = 16

    let candles: [Candle]
    let overlays: ChartOverlays
    let sub: SubPanel
    let up: Color
    let down: Color
    let hover: Int?
    let hoverPoint: CGPoint?
    let interval: CandleInterval
    let visible: Int
    let endIndex: Int

    private let closes: [Double]
    private let ma7: [Double?], ma25: [Double?], ema12: [Double?], ema26: [Double?]
    private let boll: Indicators.Bollinger
    private let rsi: [Double?]
    private let macd: Indicators.MACD

    init(candles: [Candle], overlays: ChartOverlays, sub: SubPanel, up: Color, down: Color, hover: Int?, hoverPoint: CGPoint?,
         interval: CandleInterval, visible: Int, endIndex: Int) {
        self.candles = candles; self.overlays = overlays; self.sub = sub; self.up = up; self.down = down; self.hover = hover
        self.hoverPoint = hoverPoint; self.interval = interval
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
        let usable = size.height - Self.timeAxisHeight
        let priceH = usable * 0.68
        let subTop = priceH + 8
        let subH = max(usable - subTop, 1)

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

        // Time axis: faint vertical lines and labels along the bottom, at round times for the zoom level.
        for tick in timeTicks(step: step) {
            let tx = x(tick.index)
            guard tx > 14, tx < plotW - 14 else { continue }
            var line = Path(); line.move(to: CGPoint(x: tx, y: 0)); line.addLine(to: CGPoint(x: tx, y: usable))
            context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            context.draw(Text(tick.label).font(.system(size: 8.5, design: .monospaced)).foregroundColor(.white.opacity(0.5)),
                         at: CGPoint(x: tx, y: size.height - Self.timeAxisHeight / 2), anchor: .center)
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

        // Crosshair: lines through the pointer, with the price and the time written on the axes.
        if let hover, hover >= start, hover <= endIndex, let point = hoverPoint {
            let cx = x(hover)
            let dash = StrokeStyle(lineWidth: 0.6, dash: [3, 3])
            var vertical = Path(); vertical.move(to: CGPoint(x: cx, y: 0)); vertical.addLine(to: CGPoint(x: cx, y: usable))
            context.stroke(vertical, with: .color(.white.opacity(0.45)), style: dash)
            if point.y >= 0, point.y <= usable {
                var horizontal = Path(); horizontal.move(to: CGPoint(x: 0, y: point.y)); horizontal.addLine(to: CGPoint(x: plotW, y: point.y))
                context.stroke(horizontal, with: .color(.white.opacity(0.45)), style: dash)
                if point.y <= priceH {
                    let price = low + (high - low) * Double(1 - point.y / priceH)
                    tag(&context, MarketsFormat.axisPrice(price), center: CGPoint(x: plotW + Self.axisWidth / 2, y: point.y), width: Self.axisWidth - 1)
                }
            }
            let timeText = (interval.seconds >= 86_400 ? ChartTime.yearMonthDay : ChartTime.monthDayTime).string(from: candles[hover].openTime)
            let tagWidth = CGFloat(timeText.count) * 5.4 + 12
            tag(&context, timeText, center: CGPoint(x: min(max(cx, tagWidth / 2), plotW - tagWidth / 2), y: size.height - Self.timeAxisHeight / 2), width: tagWidth)
        }
    }

    /// A light label with dark text, as the exchange draws on its axes.
    private func tag(_ context: inout GraphicsContext, _ text: String, center: CGPoint, width: CGFloat) {
        let rect = CGRect(x: center.x - width / 2, y: center.y - 7, width: width, height: 14)
        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(0.92)))
        context.draw(Text(text).font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundColor(.black), at: center, anchor: .center)
    }

    /// Candles that start a new period of a round length (an hour, a day, a month…) chosen so labels are about 60 pt apart.
    private func timeTicks(step: CGFloat) -> [(index: Int, label: String)] {
        guard count > 1, step > 0 else { return [] }
        let wanted = 56 / Double(step) * interval.seconds
        let lengths: [TimeInterval] = [300, 900, 1800, 3600, 7200, 14_400, 21_600, 43_200, 86_400, 172_800, 604_800,
                                       1_209_600, 2_592_000, 7_776_000, 15_552_000, 31_536_000]
        let period = lengths.first { $0 >= wanted } ?? 31_536_000
        let calendar = Calendar.current
        var ticks: [(Int, String)] = []
        var previousPeriod: Int?
        for i in start...endIndex {
            let date = candles[i].openTime
            let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
            let block = Int((local / period).rounded(.down))
            defer { previousPeriod = block }
            guard let previous = previousPeriod, block != previous else { continue }
            let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
            let label: String
            if period < 86_400 {
                label = (c.hour == 0 && c.minute == 0) ? ChartTime.monthDay.string(from: date) : ChartTime.hourMinute.string(from: date)
            } else if period < 2_592_000 {
                label = (c.month == 1 && (c.day ?? 0) <= 7 && period >= 604_800) ? ChartTime.year.string(from: date) : ChartTime.monthDay.string(from: date)
            } else {
                label = (c.month == 1) ? ChartTime.year.string(from: date) : ChartTime.yearMonth.string(from: date)
            }
            ticks.append((i, label))
        }
        return ticks
    }

    // MARK: Tooltip

    /// Everything about the candle at `index`: time, prices, change, volume and the indicators currently switched on.
    func tooltip(at index: Int, baseAsset: String) -> ChartTooltipData? {
        guard candles.indices.contains(index) else { return nil }
        let c = candles[index]
        let change = c.open > 0 ? (c.close - c.open) / c.open * 100 : 0
        let amplitude = c.open > 0 ? (c.high - c.low) / c.open * 100 : 0
        let tint = change >= 0 ? up : down
        let time = (interval.seconds >= 86_400 ? ChartTime.fullDay : ChartTime.full).string(from: c.openTime)
        var rows: [ChartTooltipData.Row] = [
            .init(label: String(localized: "Open price"), value: MarketsFormat.price(c.open)),
            .init(label: String(localized: "High"), value: MarketsFormat.price(c.high)),
            .init(label: String(localized: "Low"), value: MarketsFormat.price(c.low)),
            .init(label: String(localized: "Close price"), value: MarketsFormat.price(c.close), valueColor: tint),
            .init(label: String(localized: "Change"), value: MarketsFormat.percent(change), valueColor: tint),
            .init(label: String(localized: "Amplitude"), value: String(format: "%.2f%%", amplitude)),
            .init(label: String(localized: "Trade volume"), value: MarketsFormat.compact(c.volume) + " " + baseAsset),
        ]
        if c.volume > 0, c.takerBuyVolume > 0 {
            rows.append(.init(label: String(localized: "Taker buy"), value: String(format: "%.0f%%", c.takerBuyVolume / c.volume * 100)))
        }

        var indicators: [ChartTooltipData.Row] = []
        func add(_ label: String, _ values: [Double?], _ color: Color) {
            guard values.indices.contains(index), let v = values[index] else { return }
            indicators.append(.init(label: label, value: MarketsFormat.price(v), labelColor: color))
        }
        if overlays.ma { add("MA7", ma7, .yellow); add("MA25", ma25, .purple) }
        if overlays.ema { add("EMA12", ema12, .cyan); add("EMA26", ema26, .orange) }
        if overlays.boll { add("BOLL ▲", boll.upper, .gray); add("BOLL —", boll.middle, .gray); add("BOLL ▼", boll.lower, .gray) }
        switch sub {
        case .rsi:
            if rsi.indices.contains(index), let v = rsi[index] {
                indicators.append(.init(label: "RSI14", value: String(format: "%.1f", v), labelColor: .purple))
            }
        case .macd:
            if macd.line.indices.contains(index), let v = macd.line[index] { indicators.append(.init(label: "DIF", value: String(format: "%.2f", v), labelColor: .yellow)) }
            if macd.signal.indices.contains(index), let v = macd.signal[index] { indicators.append(.init(label: "DEA", value: String(format: "%.2f", v), labelColor: .purple)) }
            if macd.histogram.indices.contains(index), let v = macd.histogram[index] {
                indicators.append(.init(label: "MACD", value: String(format: "%+.2f", v), labelColor: .secondary, valueColor: v >= 0 ? up : down))
            }
        case .volume:
            break
        }
        return ChartTooltipData(time: time, rows: rows, indicators: indicators)
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
