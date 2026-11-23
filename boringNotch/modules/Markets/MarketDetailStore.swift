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
    /// The first load of candles failed (offline, or Binance not reachable from here).
    @Published private(set) var loadFailed = false
    /// No earlier candles exist (or the memory cap is reached), so panning left stops asking for more.
    private var reachedStart = false

    private var isRunning = false
    private var candleTask: Task<Void, Never>?
    private var derivativesTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// The last trade seen, so a one-second-old kline snapshot never pulls the price back.
    private var lastTrade: (price: Double, time: Date)?
    private var publishTask: Task<Void, Never>?
    private var latestLast: Candle?
    private var localBook: LocalOrderBook?
    private var bookBuffer: [DepthDiff] = []
    private var isSyncingBook = false
    private var bookPublishTask: Task<Void, Never>?

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

    /// Try the first load again after it failed.
    func retry() {
        guard let symbol else { return }
        open(symbol)
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
        reachedStart = false; isLoadingOlder = false; loadFailed = false; lastTrade = nil; latestLast = nil
        localBook = nil; bookBuffer = []; isSyncingBook = false
    }

    private func cancelTasks() {
        candleTask?.cancel(); derivativesTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        candleTask = nil; derivativesTask = nil; socket = nil
        publishTask?.cancel(); publishTask = nil; bookPublishTask?.cancel(); bookPublishTask = nil
        localBook = nil; bookBuffer = []; isSyncingBook = false
    }

    // MARK: Tasks

    private func launch() {
        cancelTasks()
        startCandles()
        guard let symbol else { return }
        derivativesTask = Task { [weak self] in
            while !Task.isCancelled {
                let stats = await BinanceClient.derivatives(symbol)
                self?.derivatives = stats
                self?.derivativesChecked = true
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
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
                self?.loadFailed = false
            } else if !Task.isCancelled {
                self?.loadFailed = true
            }
            await self?.streamCandles(symbol: symbol, interval: interval)
        }
    }

    private func streamCandles(symbol: String, interval: CandleInterval) async {
        guard let url = BinanceClient.detailStreamURL(symbol: symbol, interval: interval) else { return }
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            do {
                while !Task.isCancelled {
                    guard case .string(let text) = try await task.receive(), let event = await BinanceClient.parseOffMain(text) else { continue }
                    switch event {
                    case .kline(let candle, let eventTime): apply(candle, eventTime: eventTime, interval: interval)
                    case .trade(_, let price, let quantity, let time): applyTrade(price: price, quantity: quantity, time: time, interval: interval)
                    case .depth(let diff): handleDepth(diff, symbol: symbol)
                    case .mini: break
                    }
                    backoff = 1
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    // MARK: Order book

    private func handleDepth(_ diff: DepthDiff, symbol: String) {
        guard let lastUpdateId = localBook?.lastUpdateId else {
            bookBuffer.append(diff)
            if bookBuffer.count > 500 { bookBuffer.removeFirst(bookBuffer.count - 500) }
            if !isSyncingBook { syncBook(symbol) }
            return
        }
        if diff.last <= lastUpdateId { return }
        if diff.first > lastUpdateId + 1 {
            // A diff was missed: the local book is stale. Start again from a fresh snapshot.
            localBook = nil; bookBuffer = [diff]
            syncBook(symbol)
            return
        }
        localBook?.apply(diff)   // in place: copying the two dictionaries for every diff made a megabyte of garbage a time
        schedulePublishBook()
    }

    /// Fetches a snapshot and replays the diffs buffered while it was in flight (Binance's documented procedure).
    private func syncBook(_ symbol: String) {
        isSyncingBook = true
        Task { [weak self] in
            let snapshot = try? await BinanceClient.orderBookSnapshot(symbol)
            guard let self, self.symbol == symbol else { return }
            self.isSyncingBook = false
            guard var book = snapshot else { return }   // the next diff tries again
            for diff in self.bookBuffer where diff.last > book.lastUpdateId {
                if diff.first > book.lastUpdateId + 1 { self.bookBuffer = [diff]; return }   // snapshot too old: retry on the next diff
                book.apply(diff)
            }
            self.bookBuffer = []
            self.localBook = book
            self.schedulePublishBook()
        }
    }

    private func schedulePublishBook() {
        guard bookPublishTask == nil else { return }
        bookPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled else { return }
            self.book = self.localBook?.snapshot()
            self.bookPublishTask = nil
        }
    }

    /// A trade moves the open candle straight away (about every 100 ms) instead of waiting for the next kline snapshot.
    /// Published at most every 100 ms.
    private func applyTrade(price: Double, quantity: Double, time: Date, interval: CandleInterval) {
        guard var last = latestLast ?? candles.last, time >= last.openTime, time < last.openTime.addingTimeInterval(interval.seconds) else { return }
        last.close = price
        last.high = max(last.high, price); last.low = min(last.low, price)
        last.volume += quantity
        lastTrade = (price, time)
        latestLast = last
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled else { return }
            if let latest = self.latestLast, !self.candles.isEmpty, self.candles[self.candles.count - 1].openTime == latest.openTime {
                self.candles[self.candles.count - 1] = latest
            }
            self.publishTask = nil
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

    private func apply(_ snapshot: Candle, eventTime: Date, interval: CandleInterval) {
        var candle = snapshot
        guard let last = candles.last else { return }
        if candle.openTime == last.openTime {
            // The snapshot is up to a second old: keep a newer trade price rather than stepping back to it.
            if let trade = lastTrade, trade.time > eventTime {
                candle.close = trade.price
                candle.high = max(candle.high, trade.price); candle.low = min(candle.low, trade.price)
            }
            candles[candles.count - 1] = candle
        } else if candle.openTime > last.openTime {
            candles.append(candle)
        } else {
            return
        }
        latestLast = candle
    }
}
