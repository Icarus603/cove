//
//  SymbolDirectory.swift
//  boringNotch
//
//  Every spot pair Binance lists, with its last price, fetched once when Settings → Markets opens. It backs the search
//  box (so only pairs that exist are offered) and the prices shown beside the watchlist.
//

import Foundation

@MainActor
final class SymbolDirectory: ObservableObject {
    static let shared = SymbolDirectory()

    /// Quote currencies worth offering; Binance also lists pairs against many local currencies.
    private static let offeredQuotes: Set<String> = ["USDT", "USDC", "FDUSD", "BTC", "ETH", "BNB", "EUR", "TRY"]
    static let popularBases = ["BTC", "ETH", "SOL", "BNB", "XRP", "DOGE", "ADA", "TON", "LINK", "AVAX"]

    @Published private(set) var prices: [String: Double] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private init() {}

    func loadIfNeeded() async {
        guard prices.isEmpty else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true; failed = false
        do { prices = try await BinanceClient.allPrices() } catch { failed = prices.isEmpty }
        isLoading = false
    }

    /// Pairs matching what was typed, best first: an exact pair, then USDT pairs whose coin starts with the text, then
    /// other quotes, then anything containing it.
    func suggestions(for query: String, excluding: [String], limit: Int = 8) -> [String] {
        let typed = query.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !typed.isEmpty else { return [] }
        func rank(_ symbol: String) -> Int? {
            let (base, quote) = BinanceClient.split(symbol)
            guard Self.offeredQuotes.contains(quote) else { return nil }
            if symbol == typed { return 0 }
            if base == typed { return quote == "USDT" ? 1 : 3 }
            if base.hasPrefix(typed) { return quote == "USDT" ? 2 : 4 }
            if symbol.hasPrefix(typed) { return 5 }
            if symbol.contains(typed) { return 6 }
            return nil
        }
        return prices.keys
            .filter { !excluding.contains($0) && !isLeveragedToken($0) }
            .compactMap { symbol in rank(symbol).map { (symbol, $0) } }
            .sorted { ($0.1, $0.0.count, $0.0) < ($1.1, $1.0.count, $1.0) }
            .prefix(limit)
            .map(\.0)
    }

    /// Binance's old leveraged tokens (ETHUP, ETHDOWN, ETHBULL, ETHBEAR): a coin's name plus one of those suffixes. A coin
    /// that merely ends in UP (JUP) is kept, because what is left of its name is not itself a coin.
    private func isLeveragedToken(_ symbol: String) -> Bool {
        let (base, _) = BinanceClient.split(symbol)
        for suffix in ["UP", "DOWN", "BULL", "BEAR"] where base.hasSuffix(suffix) && base.count > suffix.count {
            if prices[String(base.dropLast(suffix.count)) + "USDT"] != nil { return true }
        }
        return false
    }

    func popular(excluding: [String]) -> [String] {
        Self.popularBases.map { $0 + "USDT" }.filter { prices[$0] != nil && !excluding.contains($0) }
    }
}
