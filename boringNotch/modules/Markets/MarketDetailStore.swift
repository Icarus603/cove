//
//  MarketDetailStore.swift
//  boringNotch
//
//  State behind the detail view of one pair: candles (REST history plus a live kline stream), the order book and
//  the futures statistics. Everything stops when the Markets tab is left or the notch closes.
//

import Combine
import Foundation

@MainActor
final class MarketDetailStore: ObservableObject {
    static let shared = MarketDetailStore()
    static let intervalKey = "markets.interval"
    private static let maxCandles = 4000
    private static let pageSize = 500

    @Published private(set) var symbol: String?
    @Published private(set) var interval: CandleInterval
    @Published private(set) var candles: [Candle] = []
    @Published private(set) var book: OrderBook?
    @Published private(set) var derivatives: DerivativesStats?
    /// True once the futures request has answered, so "not available" is not shown while it is still loading.
    @Published private(set) var derivativesChecked = false
    @Published private(set) var isLoadingOlder = false
    /// No earlier candles exist (or the memory cap is reached), so panning left stops asking for more.
    private var reachedStart = false

    private var isRunning = false
    private var candleTask: Task<Void, Never>?
    private var bookTask: Task<Void, Never>?
    private var derivativesTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    private init() {
        interval = CandleInterval(rawValue: UserDefaults.standard.string(forKey: Self.intervalKey) ?? "") ?? .h1
    }

    // MARK: Lifecycle

    func open(_ symbol: String) {
        self.symbol = symbol
        reset()
        if isRunning { launch() }
    }

    func close() {
        symbol = nil
        cancelTasks()
        reset()
    }

    /// The Markets tab is on screen: fetch if a pair is open.
    func resume() {
        guard !isRunning else { return }
        isRunning = true
        if symbol != nil { launch() }
    }

    func pause() {
        isRunning = false
        close()
    }

    func setInterval(_ value: CandleInterval) {
        guard value != interval else { return }
        interval = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.intervalKey)
        candles = []; reachedStart = false; isLoadingOlder = false
        candleTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        if isRunning, symbol != nil { startCandles() }
    }

    private func reset() {
        candles = []; book = nil; derivatives = nil; derivativesChecked = false
        reachedStart = false; isLoadingOlder = false
    }

    private func cancelTasks() {
        candleTask?.cancel(); bookTask?.cancel(); derivativesTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        candleTask = nil; bookTask = nil; derivativesTask = nil; socket = nil
    }

    // MARK: Tasks

    private func launch() {
        cancelTasks()
        startCandles()
        guard let symbol else { return }
        bookTask = Task { [weak self] in
            while !Task.isCancelled {
                if let book = try? await BinanceClient.orderBook(symbol) { self?.book = book }
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
        derivativesTask = Task { [weak self] in
            while !Task.isCancelled {
                let stats = await BinanceClient.derivatives(symbol)
                self?.derivatives = stats
                self?.derivativesChecked = true
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func startCandles() {
        guard let symbol else { return }
        let interval = self.interval
        candleTask = Task { [weak self] in
            if let history = try? await BinanceClient.candles(symbol, interval: interval) {
                guard !Task.isCancelled else { return }
                self?.candles = history
            }
            await self?.streamCandles(symbol: symbol, interval: interval)
        }
    }

    private func streamCandles(symbol: String, interval: CandleInterval) async {
        guard let url = BinanceClient.klineStreamURL(symbol: symbol, interval: interval) else { return }
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            do {
                while !Task.isCancelled {
                    if case .string(let text) = try await task.receive(), let candle = BinanceClient.parseKlineMessage(text) {
                        apply(candle)
                        backoff = 1
                    }
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Fetches the page of candles before the oldest one held, when the view has been panned near the left edge.
    func loadOlder() {
        guard !isLoadingOlder, !reachedStart, let symbol, let first = candles.first, candles.count < Self.maxCandles else { return }
        isLoadingOlder = true
        let interval = self.interval
        Task { [weak self] in
            let page = try? await BinanceClient.candles(symbol, interval: interval, limit: Self.pageSize,
                                                        endTime: first.openTime.addingTimeInterval(-0.001))
            guard let self, self.symbol == symbol, self.interval == interval else { return }
            let older = (page ?? []).filter { $0.openTime < first.openTime }
            if older.isEmpty { if page != nil { self.reachedStart = true } } else { self.candles.insert(contentsOf: older, at: 0) }
            self.isLoadingOlder = false
        }
    }

    private func apply(_ candle: Candle) {
        guard let last = candles.last else { return }
        if candle.openTime == last.openTime {
            candles[candles.count - 1] = candle
        } else if candle.openTime > last.openTime {
            candles.append(candle)
        }
    }
}
