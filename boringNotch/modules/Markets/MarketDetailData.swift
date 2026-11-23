//
//  MarketDetailData.swift
//  boringNotch
//
//  Public Binance data for the detail view: candles, order book and USDⓈ-M futures statistics. All of it is
//  unauthenticated market data.
//

import Foundation

struct Candle: Equatable, Identifiable {
    var openTime: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
    /// Base-asset volume bought by takers (market buys); the rest of `volume` was sold.
    var takerBuyVolume: Double

    var id: Date { openTime }
    var isUp: Bool { close >= open }
}

struct BookLevel: Equatable {
    var price: Double
    var quantity: Double
}

struct OrderBook: Equatable {
    var bids: [BookLevel]
    var asks: [BookLevel]

    var spread: Double? {
        guard let bid = bids.first?.price, let ask = asks.first?.price else { return nil }
        return ask - bid
    }

    /// Share of resting size on the bid side within a band around the mid price, 0...1. Counting a fixed number of
    /// levels says little (they can be a cent apart), so the band is a percentage of price, narrowed to what both
    /// sides of the fetched book actually cover.
    func bidShare(withinPercent percent: Double = 0.1) -> Double? {
        guard let bestBid = bids.first?.price, let bestAsk = asks.first?.price,
              let lowestBid = bids.last?.price, let highestAsk = asks.last?.price else { return nil }
        let mid = (bestBid + bestAsk) / 2
        let window = min(mid * percent / 100, mid - lowestBid, highestAsk - mid)
        guard window > 0 else { return nil }
        let bid = bids.filter { $0.price >= mid - window }.reduce(0) { $0 + $1.quantity }
        let ask = asks.filter { $0.price <= mid + window }.reduce(0) { $0 + $1.quantity }
        guard bid + ask > 0 else { return nil }
        return bid / (bid + ask)
    }
}

/// One `depthUpdate` frame: level changes covering update ids `first...last`; a quantity of 0 removes the level.
struct DepthDiff {
    var first: Int
    var last: Int
    var bids: [BookLevel]
    var asks: [BookLevel]
}

/// The order book kept locally the way Binance documents it: a REST snapshot, then every depth diff applied in order.
/// A diff that does not follow on from the last one means the book is stale and has to be fetched again.
struct LocalOrderBook {
    private(set) var lastUpdateId: Int
    private var bids: [Double: Double] = [:]
    private var asks: [Double: Double] = [:]

    init(lastUpdateId: Int, bids: [BookLevel], asks: [BookLevel]) {
        self.lastUpdateId = lastUpdateId
        bids.forEach { self.bids[$0.price] = $0.quantity }
        asks.forEach { self.asks[$0.price] = $0.quantity }
    }

    mutating func apply(_ diff: DepthDiff) {
        for level in diff.bids { bids[level.price] = level.quantity > 0 ? level.quantity : nil }
        for level in diff.asks { asks[level.price] = level.quantity > 0 ? level.quantity : nil }
        lastUpdateId = diff.last
    }

    /// Sorted best-first, within 1% of the middle so levels left far behind do not pile up.
    func snapshot() -> OrderBook {
        guard let bestBid = bids.keys.max(), let bestAsk = asks.keys.min() else { return OrderBook(bids: [], asks: []) }
        let mid = (bestBid + bestAsk) / 2
        let band = mid * 0.01
        return OrderBook(
            bids: bids.filter { $0.key >= mid - band }.sorted { $0.key > $1.key }.map { BookLevel(price: $0.key, quantity: $0.value) },
            asks: asks.filter { $0.key <= mid + band }.sorted { $0.key < $1.key }.map { BookLevel(price: $0.key, quantity: $0.value) })
    }
}

struct DerivativesStats: Equatable {
    var markPrice: Double?
    /// Per funding interval, e.g. 0.0001 = 0.01%.
    var fundingRate: Double?
    var nextFunding: Date?
    /// Open interest in base-asset units.
    var openInterest: Double?
    var longAccountShare: Double?
    var longShortRatio: Double?
    var takerBuySellRatio: Double?

    var isEmpty: Bool {
        fundingRate == nil && openInterest == nil && longShortRatio == nil && takerBuySellRatio == nil
    }
}

enum CandleInterval: String, CaseIterable, Identifiable {
    case m5 = "5m", m15 = "15m", h1 = "1h", h4 = "4h", d1 = "1d", w1 = "1w"
    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m5: return 300
        case .m15: return 900
        case .h1: return 3600
        case .h4: return 14_400
        case .d1: return 86_400
        case .w1: return 604_800
        }
    }
}

extension BinanceClient {
    static let futuresBase = "https://fapi.binance.com"

    /// Candles ending at `endTime` (or now), oldest first. Paging back in time is just a smaller `endTime` each call.
    static func candles(_ symbol: String, interval: CandleInterval, limit: Int = 300, endTime: Date? = nil) async throws -> [Candle] {
        var components = URLComponents(string: publicBase + "/api/v3/klines")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "interval", value: interval.rawValue),
                                 URLQueryItem(name: "limit", value: String(limit))]
        if let endTime { components.queryItems?.append(URLQueryItem(name: "endTime", value: String(Int(endTime.timeIntervalSince1970 * 1000)))) }
        let data = try await fetch(components.url!)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { throw BinanceError.badResponse }
        return rows.compactMap { row in
            guard row.count > 9, let time = (row[0] as? NSNumber)?.doubleValue, let open = parse(row[1]), let high = parse(row[2]),
                  let low = parse(row[3]), let close = parse(row[4]), let volume = parse(row[5]) else { return nil }
            return Candle(openTime: Date(timeIntervalSince1970: time / 1000), open: open, high: high, low: low, close: close,
                          volume: volume, takerBuyVolume: parse(row[9]) ?? 0)
        }
    }

    /// REST snapshot the local book starts from.
    static func orderBookSnapshot(_ symbol: String, depth: Int = 1000) async throws -> LocalOrderBook {
        var components = URLComponents(string: publicBase + "/api/v3/depth")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "limit", value: String(depth))]
        let data = try await fetch(components.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (root["lastUpdateId"] as? NSNumber)?.intValue else { throw BinanceError.badResponse }
        func levels(_ key: String) -> [BookLevel] {
            (root[key] as? [[Any]] ?? []).compactMap { row in
                guard row.count > 1, let price = parse(row[0]), let quantity = parse(row[1]) else { return nil }
                return BookLevel(price: price, quantity: quantity)
            }
        }
        return LocalOrderBook(lastUpdateId: id, bids: levels("bids"), asks: levels("asks"))
    }

    /// Futures statistics for a USDT or USDC pair; nil when the pair has no perpetual or the endpoint is not
    /// reachable from here. Each figure is fetched on its own so one failure does not hide the others.
    static func derivatives(_ symbol: String) async -> DerivativesStats? {
        guard symbol.hasSuffix("USDT") || symbol.hasSuffix("USDC") else { return nil }
        async let premium = futuresObject("/fapi/v1/premiumIndex", symbol: symbol)
        async let interest = futuresObject("/fapi/v1/openInterest", symbol: symbol)
        async let ratio = futuresRows("/futures/data/globalLongShortAccountRatio", symbol: symbol)
        async let taker = futuresRows("/futures/data/takerlongshortRatio", symbol: symbol)
        let (p, i, r, t) = await (premium, interest, ratio, taker)

        var stats = DerivativesStats()
        stats.markPrice = parse(p?["markPrice"])
        stats.fundingRate = parse(p?["lastFundingRate"])
        stats.nextFunding = (p?["nextFundingTime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        stats.openInterest = parse(i?["openInterest"])
        stats.longAccountShare = parse(r?.last?["longAccount"])
        stats.longShortRatio = parse(r?.last?["longShortRatio"])
        stats.takerBuySellRatio = parse(t?.last?["buySellRatio"])
        return stats.isEmpty ? nil : stats
    }

    // MARK: Streams

    /// Candles, every trade and the order book's 100 ms diffs for the open pair, in one combined stream.
    static func detailStreamURL(symbol: String, interval: CandleInterval) -> URL? {
        let name = symbol.lowercased()
        return URL(string: streamBase + "/stream?streams=" + name + "@kline_" + interval.rawValue + "/" + name + "@trade/" + name + "@depth@100ms")
    }

    // MARK: Plumbing

    private static func futuresObject(_ path: String, symbol: String) async -> [String: Any]? {
        guard let url = futuresURL(path, symbol: symbol), let data = try? await fetch(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func futuresRows(_ path: String, symbol: String) async -> [[String: Any]]? {
        guard let url = futuresURL(path, symbol: symbol, period: true), let data = try? await fetch(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private static func futuresURL(_ path: String, symbol: String, period: Bool = false) -> URL? {
        var components = URLComponents(string: futuresBase + path)
        var items = [URLQueryItem(name: "symbol", value: symbol)]
        if period { items += [URLQueryItem(name: "period", value: "1h"), URLQueryItem(name: "limit", value: "1")] }
        components?.queryItems = items
        return components?.url
    }
}
