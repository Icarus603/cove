//
//  BinanceClient.swift
//  boringNotch
//
//  Binance market data over HTTPS and WebSocket. Prices need no key: they come from Binance's public market-data
//  hosts. The optional account call is a single signed GET of balances with the user's own read-only key; nothing in
//  Cove places, changes or cancels an order or moves funds.
//

import CryptoKit
import Foundation

struct MarketTicker: Equatable {
    var symbol: String
    var price: Double
    var open: Double
    var high: Double
    var low: Double
    var quoteVolume: Double

    var changePercent: Double { open > 0 ? (price - open) / open * 100 : 0 }
}

struct PortfolioHolding: Equatable, Identifiable {
    var id: String { asset }
    let asset: String
    let amount: Double
    /// In USDT; nil when the asset has no USDT pair.
    let value: Double?
}

struct Portfolio: Equatable {
    var total: Double
    var holdings: [PortfolioHolding]
}

enum BinanceError: LocalizedError {
    case http(Int, String)
    case badResponse
    case noKeys

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if code == 451 { return String(localized: "Binance is not available from this region (HTTP 451).") }
            return message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
        case .badResponse: return String(localized: "Unexpected response from Binance.")
        case .noKeys: return String(localized: "No API key saved.")
        }
    }
}

enum BinanceClient {
    /// Market data only: no account endpoints, usable where api.binance.com is restricted.
    static let publicBase = "https://data-api.binance.vision"
    static let streamBase = "wss://data-stream.binance.vision"
    /// The account endpoint lives on the main host.
    static let accountBase = "https://api.binance.com"

    static let stableQuotes: Set<String> = ["USDT", "USDC", "FDUSD", "BUSD", "TUSD", "USDP", "DAI"]
    static let knownQuotes = ["FDUSD", "USDT", "USDC", "BUSD", "TUSD", "USDP", "TRY", "EUR", "BTC", "ETH", "BNB", "USD"]

    static let apiKeyAccount = "binance.apiKey"
    static let apiSecretAccount = "binance.apiSecret"

    // MARK: Symbols

    /// "btc" -> "BTCUSDT", "ethusdt" -> "ETHUSDT", "SOL/USDT" -> "SOLUSDT".
    static func normalize(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return "" }
        if knownQuotes.contains(where: { cleaned.hasSuffix($0) && cleaned.count > $0.count }) { return cleaned }
        return cleaned + "USDT"
    }

    static func split(_ symbol: String) -> (base: String, quote: String) {
        if let quote = knownQuotes.first(where: { symbol.hasSuffix($0) && symbol.count > $0.count }) {
            return (String(symbol.dropLast(quote.count)), quote)
        }
        return (symbol, "")
    }

    // MARK: Public data

    static func tickers(_ symbols: [String]) async throws -> [MarketTicker] {
        guard !symbols.isEmpty else { return [] }
        var components = URLComponents(string: publicBase + "/api/v3/ticker/24hr")!
        components.queryItems = [URLQueryItem(name: "symbols", value: jsonArray(symbols))]
        let data = try await get(components.url!)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BinanceError.badResponse }
        return rows.compactMap { row in
            guard let symbol = row["symbol"] as? String, let price = number(row["lastPrice"]) else { return nil }
            return MarketTicker(symbol: symbol, price: price, open: number(row["openPrice"]) ?? price,
                                high: number(row["highPrice"]) ?? price, low: number(row["lowPrice"]) ?? price,
                                quoteVolume: number(row["quoteVolume"]) ?? 0)
        }
    }

    /// Closing prices of the last 24 hourly candles.
    static func sparkline(_ symbol: String) async throws -> [Double] {
        var components = URLComponents(string: publicBase + "/api/v3/klines")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "interval", value: "1h"),
                                 URLQueryItem(name: "limit", value: "24")]
        let data = try await get(components.url!)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { throw BinanceError.badResponse }
        return rows.compactMap { $0.count > 4 ? number($0[4]) : nil }
    }

    /// Every spot symbol with its last price, in one request. Used to search pairs and to show current prices in Settings.
    static func allPrices() async throws -> [String: Double] {
        let data = try await get(URL(string: publicBase + "/api/v3/ticker/price")!)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BinanceError.badResponse }
        var result: [String: Double] = [:]
        for row in rows { if let symbol = row["symbol"] as? String, let price = number(row["price"]) { result[symbol] = price } }
        return result
    }

    static func exists(_ symbol: String) async -> Bool {
        var components = URLComponents(string: publicBase + "/api/v3/ticker/price")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        return (try? await get(components.url!)) != nil
    }

    /// Combined stream for the board: a 1 s mini-ticker (24h figures) plus every trade as it happens per pair. (The aggregated
    /// trade stream merges fills and is several times slower.)
    static func streamURL(for symbols: [String]) -> URL? {
        guard !symbols.isEmpty else { return nil }
        let streams = symbols.flatMap { [$0.lowercased() + "@miniTicker", $0.lowercased() + "@trade"] }.joined(separator: "/")
        return URL(string: streamBase + "/stream?streams=" + streams)
    }

    /// One frame of a combined stream.
    enum StreamEvent {
        case mini(MarketTicker)
        case trade(symbol: String, price: Double, quantity: Double, time: Date)
        case kline(Candle, eventTime: Date)
        case depth(DepthDiff)
    }

    /// The same, as an async function that is not tied to the main actor: the socket delivers hundreds of messages a second
    /// for a busy pair, and parsing each one on the main thread was a wake-up and a JSON pass per message.
    nonisolated static func parseOffMain(_ text: String) async -> StreamEvent? { parseStreamEvent(text) }

    nonisolated static func parseStreamEvent(_ text: String) -> StreamEvent? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any], let kind = body["e"] as? String else { return nil }
        func date(_ value: Any?) -> Date? { (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        switch kind {
        case "24hrMiniTicker":
            guard let symbol = body["s"] as? String, let price = number(body["c"]) else { return nil }
            return .mini(MarketTicker(symbol: symbol, price: price, open: number(body["o"]) ?? price, high: number(body["h"]) ?? price,
                                      low: number(body["l"]) ?? price, quoteVolume: number(body["q"]) ?? 0))
        case "trade":
            guard let symbol = body["s"] as? String, let price = number(body["p"]), let quantity = number(body["q"]),
                  let time = date(body["T"]) else { return nil }
            return .trade(symbol: symbol, price: price, quantity: quantity, time: time)
        case "kline":
            guard let k = body["k"] as? [String: Any], let opened = date(k["t"]), let open = number(k["o"]), let high = number(k["h"]),
                  let low = number(k["l"]), let close = number(k["c"]), let volume = number(k["v"]) else { return nil }
            let candle = Candle(openTime: opened, open: open, high: high, low: low, close: close, volume: volume, takerBuyVolume: number(k["V"]) ?? 0)
            return .kline(candle, eventTime: date(body["E"]) ?? Date())
        case "depthUpdate":
            guard let first = (body["U"] as? NSNumber)?.intValue, let last = (body["u"] as? NSNumber)?.intValue else { return nil }
            func levels(_ key: String) -> [BookLevel] {
                (body[key] as? [[Any]] ?? []).compactMap { row in
                    guard row.count > 1, let price = number(row[0]), let quantity = number(row[1]) else { return nil }
                    return BookLevel(price: price, quantity: quantity)
                }
            }
            return .depth(DepthDiff(first: first, last: last, bids: levels("b"), asks: levels("a")))
        default:
            return nil
        }
    }

    // MARK: Account (optional, read-only)

    static var hasKeys: Bool {
        KeychainStore.read(apiKeyAccount) != nil && KeychainStore.read(apiSecretAccount) != nil
    }

    /// Spot balances valued in USDT. One signed GET /api/v3/account, then public prices.
    static func portfolio() async throws -> Portfolio {
        guard let key = KeychainStore.read(apiKeyAccount), let secret = KeychainStore.read(apiSecretAccount) else { throw BinanceError.noKeys }
        let query = "timestamp=\(Int(Date().timeIntervalSince1970 * 1000))&recvWindow=10000&omitZeroBalances=true"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: accountBase + "/api/v3/account?" + query + "&signature=" + signature) else { throw BinanceError.badResponse }
        let data = try await get(url, apiKey: key)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balances = root["balances"] as? [[String: Any]] else { throw BinanceError.badResponse }

        var amounts: [String: Double] = [:]
        for balance in balances {
            guard let asset = balance["asset"] as? String else { continue }
            let total = (number(balance["free"]) ?? 0) + (number(balance["locked"]) ?? 0)
            if total > 0 { amounts[asset] = total }
        }
        // Savings products show up as LD-prefixed wrappers of the underlying coin; value them as that coin.
        var merged: [String: Double] = [:]
        for (asset, amount) in amounts {
            let name = asset.hasPrefix("LD") && asset.count > 2 ? String(asset.dropFirst(2)) : asset
            merged[name, default: 0] += amount
        }

        let needPrice = merged.keys.filter { !stableQuotes.contains($0) }
        var prices: [String: Double] = [:]
        if !needPrice.isEmpty {
            var components = URLComponents(string: publicBase + "/api/v3/ticker/price")!
            components.queryItems = [URLQueryItem(name: "symbols", value: jsonArray(needPrice.map { $0 + "USDT" }))]
            if let priceData = try? await get(components.url!), let rows = try? JSONSerialization.jsonObject(with: priceData) as? [[String: Any]] {
                for row in rows { if let symbol = row["symbol"] as? String, let price = number(row["price"]) { prices[String(symbol.dropLast(4))] = price } }
            }
        }
        let holdings = merged.map { asset, amount -> PortfolioHolding in
            if stableQuotes.contains(asset) { return PortfolioHolding(asset: asset, amount: amount, value: amount) }
            return PortfolioHolding(asset: asset, amount: amount, value: prices[asset].map { $0 * amount })
        }.sorted { ($0.value ?? -1) > ($1.value ?? -1) }
        return Portfolio(total: holdings.reduce(0) { $0 + ($1.value ?? 0) }, holdings: holdings)
    }

    // MARK: Plumbing

    static func fetch(_ url: URL, apiKey: String? = nil) async throws -> Data { try await get(url, apiKey: apiKey) }

    private static func get(_ url: URL, apiKey: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BinanceError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String ?? ""
            throw BinanceError.http(http.statusCode, message)
        }
        return data
    }

    private static func jsonArray(_ items: [String]) -> String {
        "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    static func parse(_ value: Any?) -> Double? { number(value) }

    private static func number(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
