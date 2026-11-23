import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") { if !ok { failures += 1 }; print(ok ? "ok  " : "FAIL", name, detail) }
func near(_ a: Double?, _ b: Double, _ tol: Double = 0.01) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

// Wilder's worked RSI example (StockCharts): first RSI 70.53, next 66.32.
let closes: [Double] = [44.34, 44.09, 44.15, 43.61, 44.33, 44.83, 45.10, 45.42, 45.84, 46.08, 45.89, 46.03, 45.61, 46.28, 46.28, 46.00]
let rsi = Indicators.rsi(closes, period: 14)
check("rsi warm-up", rsi[13] == nil && rsi[14] != nil)
check("rsi first (reference calc)", near(rsi[14], 70.4641), "\(rsi[14] ?? -1)")
check("rsi next (reference calc)", near(rsi[15], 66.2496), "\(rsi[15] ?? -1)")
check("rsi flat = 50", near(Indicators.rsi(Array(repeating: 10, count: 20))[19], 50))
check("rsi only up = 100", near(Indicators.rsi((0..<20).map(Double.init))[19], 100))

let sma = Indicators.sma([1, 2, 3, 4, 5], period: 3)
check("sma", sma[1] == nil && near(sma[2], 2) && near(sma[4], 4))
check("sma short input", Indicators.sma([1, 2], period: 3).allSatisfy { $0 == nil })

let ema = Indicators.ema([2, 2, 2, 2, 2, 2], period: 3)
check("ema constant", ema[1] == nil && near(ema[2], 2) && near(ema[5], 2))
// EMA(3) of 1,2,3,4: seed 2 at idx2, k=0.5 -> idx3 = 4*.5 + 2*.5 = 3
check("ema step", near(Indicators.ema([1, 2, 3, 4], period: 3)[3], 3))

let trend = (0..<60).map { Double($0) }
let macd = Indicators.macd(trend)
check("macd warm-up", macd.line[24] == nil && macd.line[25] != nil)
check("macd signal starts 8 later", macd.signal[32] == nil && macd.signal[33] != nil, "")
check("macd rising trend positive", (macd.line[59] ?? 0) > 0)
check("macd length", macd.line.count == 60 && macd.signal.count == 60 && macd.histogram.count == 60)
check("macd hist = line - signal", near(macd.histogram[59], (macd.line[59] ?? 0) - (macd.signal[59] ?? 0), 1e-9))

let flat = Indicators.bollinger(Array(repeating: 5, count: 25))
check("boll flat has zero width", near(flat.upper[24], 5) && near(flat.lower[24], 5))
let b = Indicators.bollinger([1, 2, 3, 4, 5], period: 5, k: 2)  // mean 3, pop sd sqrt(2)
check("boll sd", near(b.upper[4], 3 + 2 * 2.0.squareRoot()) && near(b.lower[4], 3 - 2 * 2.0.squareRoot()))
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
