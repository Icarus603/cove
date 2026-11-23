//
//  Indicators.swift
//  boringNotch
//
//  Technical indicators over closing prices. Every function returns an array the same length as its input, with nil
//  where there is not enough history yet, so the results line up with the candles they came from.
//

import Foundation

enum Indicators {
    /// Simple moving average.
    static func sma(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return Array(repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        var sum = values[..<period].reduce(0, +)
        result[period - 1] = sum / Double(period)
        for i in period..<values.count {
            sum += values[i] - values[i - period]
            result[i] = sum / Double(period)
        }
        return result
    }

    /// Exponential moving average, seeded with the simple average of the first `period` values.
    static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return Array(repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        let k = 2.0 / Double(period + 1)
        var previous = values[..<period].reduce(0, +) / Double(period)
        result[period - 1] = previous
        for i in period..<values.count {
            previous = values[i] * k + previous * (1 - k)
            result[i] = previous
        }
        return result
    }

    /// Relative strength index with Wilder's smoothing.
    static func rsi(_ closes: [Double], period: Int = 14) -> [Double?] {
        guard period > 0, closes.count > period else { return Array(repeating: nil, count: closes.count) }
        var result = [Double?](repeating: nil, count: closes.count)
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let change = closes[i] - closes[i - 1]
            if change >= 0 { gain += change } else { loss -= change }
        }
        gain /= Double(period); loss /= Double(period)
        result[period] = value(gain: gain, loss: loss)
        for i in (period + 1)..<closes.count {
            let change = closes[i] - closes[i - 1]
            gain = (gain * Double(period - 1) + max(change, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-change, 0)) / Double(period)
            result[i] = value(gain: gain, loss: loss)
        }
        return result
    }

    private static func value(gain: Double, loss: Double) -> Double {
        if loss == 0 { return gain == 0 ? 50 : 100 }
        return 100 - 100 / (1 + gain / loss)
    }

    struct MACD {
        var line: [Double?]
        var signal: [Double?]
        var histogram: [Double?]
    }

    /// MACD: fast EMA minus slow EMA, its signal EMA, and the difference between them.
    static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> MACD {
        let fastEMA = ema(closes, period: fast), slowEMA = ema(closes, period: slow)
        let line: [Double?] = zip(fastEMA, slowEMA).map { f, s in
            guard let f, let s else { return nil }
            return f - s
        }
        // The signal line starts from the first defined MACD value.
        var signalLine = [Double?](repeating: nil, count: closes.count)
        if let start = line.firstIndex(where: { $0 != nil }) {
            let defined = line[start...].map { $0 ?? 0 }
            for (offset, value) in ema(defined, period: signal).enumerated() { signalLine[start + offset] = value }
        }
        let histogram: [Double?] = zip(line, signalLine).map { m, s in
            guard let m, let s else { return nil }
            return m - s
        }
        return MACD(line: line, signal: signalLine, histogram: histogram)
    }

    struct Bollinger {
        var middle: [Double?]
        var upper: [Double?]
        var lower: [Double?]
    }

    /// Bollinger bands: a moving average plus and minus `k` population standard deviations.
    static func bollinger(_ closes: [Double], period: Int = 20, k: Double = 2) -> Bollinger {
        let middle = sma(closes, period: period)
        var upper = [Double?](repeating: nil, count: closes.count)
        var lower = upper
        guard period > 0 else { return Bollinger(middle: middle, upper: upper, lower: lower) }
        for i in closes.indices {
            guard let mean = middle[i] else { continue }
            let window = closes[(i - period + 1)...i]
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period)
            let deviation = variance.squareRoot()
            upper[i] = mean + k * deviation
            lower[i] = mean - k * deviation
        }
        return Bollinger(middle: middle, upper: upper, lower: lower)
    }
}
