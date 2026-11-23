//
//  MarketsStore.swift
//  boringNotch
//
//  Live prices for the watchlist. It only runs while the Markets tab is on screen: the WebSocket, the hourly
//  sparklines and the optional balance refresh all stop when the notch closes or the tab is left.
//

import Combine
import Foundation

@MainActor
final class MarketsStore: ObservableObject {
    static let shared = MarketsStore()

    enum Status: Equatable { case idle, connecting, live, offline }

    static let watchlistKey = "markets.watchlist"
    static let defaultWatchlist = ["BTCUSDT", "ETHUSDT", "SOLUSDT", "BNBUSDT"]

    @Published private(set) var tickers: [String: MarketTicker] = [:]
    @Published private(set) var sparklines: [String: [Double]] = [:]
    @Published private(set) var status: Status = .idle
    @Published private(set) var portfolio: Portfolio?
    @Published private(set) var portfolioError: String?
    @Published private(set) var portfolioUpdated: Date?

    @Published var watchlist: [String] {
        didSet {
            guard watchlist != oldValue else { return }
            UserDefaults.standard.set(watchlist, forKey: Self.watchlistKey)
            if isActive { relaunchMarketTasks() }
        }
    }

    private var isActive = false
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var portfolioTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Ticks arrive faster than the screen needs: they are collected here and published at most every 100 ms.
    private var pending: [String: MarketTicker] = [:]
    private var lastTrade: [String: Double] = [:]
    private var flushTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.watchlistKey)
        watchlist = (saved?.isEmpty == false) ? saved! : Self.defaultWatchlist
    }

    // MARK: Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        relaunchMarketTasks()
        startPortfolioTask()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        streamTask?.cancel(); refreshTask?.cancel(); portfolioTask?.cancel(); flushTask?.cancel(); flushTask = nil
        pending.removeAll(); lastTrade.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        streamTask = nil; refreshTask = nil; portfolioTask = nil; socket = nil
        status = .idle
    }

    /// The API key changed in Settings: drop the old balance and fetch again.
    func credentialsChanged() {
        portfolio = nil; portfolioError = nil; portfolioUpdated = nil
        portfolioTask?.cancel(); portfolioTask = nil
        if isActive { startPortfolioTask() }
    }

    // MARK: Watchlist

    /// Adds a pair after Binance confirms it exists. Returns the normalised symbol, or nil when it does not.
    func add(_ raw: String) async -> String? {
        let symbol = BinanceClient.normalize(raw)
        guard !symbol.isEmpty else { return nil }
        if watchlist.contains(symbol) { return symbol }
        guard await BinanceClient.exists(symbol) else { return nil }
        watchlist.append(symbol)
        return symbol
    }

    func remove(_ symbol: String) {
        watchlist.removeAll { $0 == symbol }
        tickers[symbol] = nil; sparklines[symbol] = nil
    }

    /// Adds a symbol that is already known to exist (picked from the search results).
    func addKnown(_ symbol: String) {
        guard !watchlist.contains(symbol) else { return }
        watchlist.append(symbol)
    }

    func move(_ symbol: String, by offset: Int) {
        guard let index = watchlist.firstIndex(of: symbol) else { return }
        let target = index + offset
        guard watchlist.indices.contains(target) else { return }
        watchlist.swapAt(index, target)
    }

    func resetWatchlist() {
        watchlist = Self.defaultWatchlist
        tickers = tickers.filter { Self.defaultWatchlist.contains($0.key) }
    }

    // MARK: Tasks

    private func relaunchMarketTasks() {
        streamTask?.cancel(); refreshTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        let symbols = watchlist
        streamTask = Task { [weak self] in await self?.runStream(symbols) }
        refreshTask = Task { [weak self] in await self?.runRefresh(symbols) }
    }

    private func startPortfolioTask() {
        guard portfolioTask == nil, BinanceClient.hasKeys else { return }
        portfolioTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPortfolio()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func refreshPortfolio() async {
        do {
            let result = try await BinanceClient.portfolio()
            portfolio = result; portfolioError = nil; portfolioUpdated = Date()
        } catch {
            portfolioError = error.localizedDescription
        }
    }

    /// Fetches the balance once, for the Settings "Test connection" button.
    func testConnection() async -> String? {
        do {
            let result = try await BinanceClient.portfolio()
            portfolio = result; portfolioError = nil; portfolioUpdated = Date()
            // Only a tab that is showing keeps polling; testing the key from Settings must not start a clock that never stops.
            if isActive { startPortfolioTask() }
            return nil
        } catch {
            portfolioError = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func runStream(_ symbols: [String]) async {
        guard let url = BinanceClient.streamURL(for: symbols) else { return }
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            status = .connecting
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard case .string(let text) = message, let event = await BinanceClient.parseOffMain(text) else { continue }
                    switch event {
                    case .mini(var ticker):
                        // The snapshot can be up to a second behind the trades already seen.
                        if let price = lastTrade[ticker.symbol] {
                            ticker.price = price
                            ticker.high = max(ticker.high, price); ticker.low = min(ticker.low, price)
                        }
                        pending[ticker.symbol] = ticker
                    case .trade(let symbol, let price, _, _):
                        lastTrade[symbol] = price
                        guard var ticker = pending[symbol] ?? tickers[symbol] else { continue }
                        ticker.price = price
                        ticker.high = max(ticker.high, price); ticker.low = min(ticker.low, price)
                        pending[symbol] = ticker
                    case .kline, .depth:
                        continue
                    }
                    scheduleFlush()
                    backoff = 1
                }
            } catch {
                if Task.isCancelled { return }
                status = .offline
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled else { return }
            self.tickers.merge(self.pending) { _, new in new }
            self.pending.removeAll()
            self.flushTask = nil
            if self.status != .live { self.status = .live }
        }
    }

    /// REST snapshot first (so cards fill before the first stream frame), then sparklines every five minutes.
    private func runRefresh(_ symbols: [String]) async {
        while !Task.isCancelled {
            if let rows = try? await BinanceClient.tickers(symbols) {
                for row in rows where tickers[row.symbol] == nil { tickers[row.symbol] = row }
            }
            await withTaskGroup(of: (String, [Double])?.self) { group in
                for symbol in symbols {
                    group.addTask { (try? await BinanceClient.sparkline(symbol)).map { (symbol, $0) } }
                }
                for await result in group { if let (symbol, values) = result { sparklines[symbol] = values } }
            }
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
        }
    }
}
