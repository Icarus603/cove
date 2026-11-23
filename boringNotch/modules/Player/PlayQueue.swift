//
//  PlayQueue.swift
//  boringNotch
//
//  The order tracks are played in: shuffle, repeat, "play next" and "add to queue". Pure value logic with no AVFoundation
//  or UI in it, so it can be tested on its own (scripts/test-player.sh).
//

import Foundation

struct PlayQueue<ID: Hashable> {
    enum RepeatMode: String, Codable, CaseIterable {
        case off, all, one
    }

    /// Tracks in the order the user sees them.
    private(set) var list: [ID] = []
    /// The order they are actually played in: `list`, or a shuffle of it with the current track first.
    private(set) var order: [ID] = []
    private(set) var current: ID?
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off

    /// How a shuffle is made. Tests replace it with something predictable.
    var shuffler: ([ID]) -> [ID] = { $0.shuffled() }

    var isEmpty: Bool { list.isEmpty }

    // MARK: Loading

    /// Replaces the queue. `start` is the track that plays first (the first one when nil or not in `ids`).
    mutating func load(_ ids: [ID], start: ID? = nil) {
        var seen = Set<ID>()
        list = ids.filter { seen.insert($0).inserted }
        current = start.flatMap { list.contains($0) ? $0 : nil } ?? list.first
        rebuildOrder()
    }

    mutating func setShuffle(_ on: Bool) {
        guard on != isShuffled else { return }
        isShuffled = on
        rebuildOrder()
    }

    /// Makes `id` the current track without disturbing the order (a click in the list). Unknown ids are added to the end.
    mutating func select(_ id: ID) {
        if !list.contains(id) { list.append(id); order.append(id) }
        current = id
    }

    // MARK: Moving

    /// The track after the current one. `natural` is a track ending by itself, where repeat-one stays on the same track;
    /// a press of Next skips to the next track even then. Nil at the end of the queue with repeat off.
    func next(natural: Bool) -> ID? {
        guard let current, !order.isEmpty else { return nil }
        if natural, repeatMode == .one { return current }
        guard let index = order.firstIndex(of: current) else { return order.first }
        if index + 1 < order.count { return order[index + 1] }
        return repeatMode == .all ? firstOfNextRound() : nil
    }

    /// The track before the current one; with repeat-all the last track when at the start. Nil at the very start otherwise.
    func previous() -> ID? {
        guard let current, !order.isEmpty else { return nil }
        guard let index = order.firstIndex(of: current) else { return order.first }
        if index > 0 { return order[index - 1] }
        return repeatMode == .all ? order.last : nil
    }

    /// Moves to the next track (see `next`) and returns it.
    @discardableResult
    mutating func advance(natural: Bool) -> ID? {
        guard let target = next(natural: natural) else { return nil }
        if target == order.first, current == order.last, repeatMode == .all, isShuffled, order.count > 1 {
            reshuffleKeepingFirst(target)   // a new round of a shuffled queue gets a new order
        }
        current = target
        return target
    }

    @discardableResult
    mutating func goBack() -> ID? {
        guard let target = previous() else { return nil }
        current = target
        return target
    }

    // MARK: Editing

    /// Plays `id` right after the current track.
    mutating func playNext(_ id: ID) {
        guard id != current else { return }
        remove(id, keepingCurrent: true)
        guard let current, let at = order.firstIndex(of: current) else {
            list.append(id); order.append(id)
            if self.current == nil { self.current = id }
            return
        }
        order.insert(id, at: at + 1)
        if let listAt = list.firstIndex(of: current) { list.insert(id, at: listAt + 1) } else { list.append(id) }
    }

    /// Adds `id` at the end of the queue.
    mutating func enqueue(_ id: ID) {
        guard !list.contains(id) else { return }
        list.append(id); order.append(id)
        if current == nil { current = id }
    }

    /// Takes `id` out. When it was the current track the current track moves to the one after it (or before, at the end).
    mutating func remove(_ id: ID) { remove(id, keepingCurrent: false) }

    private mutating func remove(_ id: ID, keepingCurrent: Bool) {
        let successor = (id == current && !keepingCurrent) ? (next(natural: false) ?? previous()) : nil
        list.removeAll { $0 == id }
        order.removeAll { $0 == id }
        if id == current && !keepingCurrent { current = successor == id ? nil : successor }
        if list.isEmpty { current = nil }
    }

    // MARK: Order

    private mutating func rebuildOrder() {
        guard isShuffled else { order = list; return }
        reshuffleKeepingFirst(current)
    }

    private mutating func reshuffleKeepingFirst(_ first: ID?) {
        var rest = list
        if let first, let at = rest.firstIndex(of: first) { rest.remove(at: at) }
        order = (first.map { [$0] } ?? []) + shuffler(rest)
    }

    private func firstOfNextRound() -> ID? { order.first }
}
