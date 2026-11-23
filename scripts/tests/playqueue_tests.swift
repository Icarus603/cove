import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") { if !ok { failures += 1 }; print(ok ? "ok  " : "FAIL", name, detail) }

typealias Q = PlayQueue<Int>
func walk(_ q: Q, natural: Bool = true, limit: Int = 50) -> [Int] {
    var q = q; var seen = [q.current].compactMap { $0 }
    while seen.count < limit, let n = q.advance(natural: natural) { seen.append(n) }
    return seen
}

// sequential
var q = Q(); q.load([1, 2, 3, 4])
check("starts at first", q.current == 1)
check("sequential order", walk(q) == [1, 2, 3, 4])
check("repeat off ends", { var c = q; c.load([1, 2], start: 2); return c.next(natural: true) == nil }())
check("start at given track", { var c = Q(); c.load([1, 2, 3], start: 3); return c.current == 3 && c.previous() == 2 }())
check("unknown start falls back to first", { var c = Q(); c.load([5, 6], start: 99); return c.current == 5 }())
check("duplicates dropped", { var c = Q(); c.load([1, 1, 2, 2, 3]); return c.list == [1, 2, 3] }())
check("empty queue", { var c = Q(); c.load([]); return c.current == nil && c.next(natural: true) == nil && c.previous() == nil && c.isEmpty }())

// repeat
var r = Q(); r.load([1, 2, 3]); r.repeatMode = .all
check("repeat all wraps forward", { var c = r; c.select(3); return c.next(natural: true) == 1 }())
check("repeat all wraps back", { var c = r; return c.previous() == 3 }())
var one = Q(); one.load([1, 2, 3]); one.repeatMode = .one
check("repeat one: natural end stays", one.next(natural: true) == 1)
check("repeat one: manual next moves on", one.next(natural: false) == 2)
check("repeat off: previous at start is nil", { var c = Q(); c.load([1, 2]); return c.previous() == nil }())

// shuffle
var s = Q(); s.shuffler = { $0.reversed() }; s.load([1, 2, 3, 4, 5], start: 3); s.setShuffle(true)
check("shuffle keeps current first", s.order.first == 3 && s.current == 3)
check("shuffle visits every track exactly once", Set(walk(s)) == [1, 2, 3, 4, 5] && walk(s).count == 5)
check("list order untouched by shuffle", s.list == [1, 2, 3, 4, 5])
check("shuffle off restores order", { var c = s; c.setShuffle(false); return c.order == [1, 2, 3, 4, 5] && c.current == 3 }())
var sa = Q(); sa.shuffler = { $0.reversed() }; sa.load([1, 2, 3], start: 1); sa.setShuffle(true); sa.repeatMode = .all
var rounds: [Int] = []; for _ in 0..<9 { rounds.append(sa.current!); sa.advance(natural: true) }
check("shuffle + repeat all keeps visiting all", Set(rounds[0..<3]) == [1, 2, 3] && Set(rounds[3..<6]) == [1, 2, 3] && Set(rounds[6..<9]) == [1, 2, 3], "\(rounds)")

// editing
var e = Q(); e.load([1, 2, 3])
e.playNext(9); check("play next goes after current", e.order == [1, 9, 2, 3] && e.list == [1, 9, 2, 3])
e.playNext(3); check("play next moves an existing track", e.order == [1, 3, 9, 2], "\(e.order)")
e.playNext(1); check("play next of the current track is a no-op", e.order == [1, 3, 9, 2])
e.enqueue(7); check("enqueue appends", e.order.last == 7)
e.enqueue(7); check("enqueue is idempotent", e.order.filter { $0 == 7 }.count == 1)
var rm = Q(); rm.load([1, 2, 3]); rm.select(2); rm.remove(2)
check("remove current moves to the next", rm.current == 3 && rm.list == [1, 3])
rm.remove(3); check("remove last current falls back to previous", rm.current == 1)
rm.remove(1); check("remove everything empties", rm.current == nil && rm.isEmpty)
var rmo = Q(); rmo.load([1, 2, 3]); rmo.remove(3)
check("remove another track keeps current", rmo.current == 1 && rmo.list == [1, 2])
var sel = Q(); sel.load([1, 2]); sel.select(8)
check("select adds an unknown track", sel.current == 8 && sel.list == [1, 2, 8])

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
