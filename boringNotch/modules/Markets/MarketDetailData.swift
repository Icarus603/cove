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

    static func orderBook(_ symbol: String, depth: Int = 500) async throws -> OrderBook {
        var components = URLComponents(string: publicBase + "/api/v3/depth")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "limit", value: String(depth))]
        let data = try await fetch(components.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BinanceError.badResponse }
        func levels(_ key: String) -> [BookLevel] {
            (root[key] as? [[Any]] ?? []).compactMap { row in
                guard row.count > 1, let price = parse(row[0]), let quantity = parse(row[1]) else { return nil }
                return BookLevel(price: price, quantity: quantity)
            }
        }
        return OrderBook(bids: levels("bids"), asks: levels("asks"))
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

    static func klineStreamURL(symbol: String, interval: CandleInterval) -> URL? {
        URL(string: streamBase + "/ws/" + symbol.lowercased() + "@kline_" + interval.rawValue)
    }

    static func parseKlineMessage(_ text: String) -> Candle? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let k = root["k"] as? [String: Any],
              let time = (k["t"] as? NSNumber)?.doubleValue, let open = parse(k["o"]), let high = parse(k["h"]),
              let low = parse(k["l"]), let close = parse(k["c"]), let volume = parse(k["v"]) else { return nil }
        return Candle(openTime: Date(timeIntervalSince1970: time / 1000), open: open, high: high, low: low, close: close,
                      volume: volume, takerBuyVolume: parse(k["V"]) ?? 0)
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
