//
//  PlayerEngine.swift
//  boringNotch
//
//  Plays the library with AVPlayer: the queue (shuffle, repeat, play next), seeking, volume, speed, audio and subtitle
//  tracks, and remembering where each file was left. One engine serves the notch tab, the floating window and the
//  collapsed mini player, so they always agree.
//

import AVFoundation
import Combine
import Foundation

enum PlayerState: Equatable {
    /// Nothing loaded (or stopped).
    case stopped
    case loading
    case playing
    case paused
    case failed(String)
}

struct TrackOption: Identifiable, Equatable {
    let id: String
    let name: String
    var isSelected: Bool
}

@MainActor
final class PlayerEngine: ObservableObject {
    #if DEBUG
    static let shared = PlayerEngine(library: .shared, defaults: ProcessInfo.processInfo.environment["COVE_PLAYER_SANDBOX"] != nil
        ? UserDefaults(suiteName: "app.cove.player-sandbox")! : .standard)
    #else
    static let shared = PlayerEngine(library: .shared)
    #endif

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    let player = AVPlayer()
    let library: PlayerLibrary

    @Published private(set) var current: MediaItem?
    @Published private(set) var state: PlayerState = .stopped
    /// The last few state changes with the reason for each, newest last. Only for diagnosing odd behaviour.
    private(set) var stateLog: [String] = []
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var queueOrder: [UUID] = []
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode: PlayQueue<UUID>.RepeatMode = .off
    @Published private(set) var rate: Float = 1
    @Published private(set) var audioTracks: [TrackOption] = []
    @Published private(set) var subtitleTracks: [TrackOption] = []
    /// The user is dragging the scrubber: the clock must not move it back.
    @Published var isScrubbing = false

    @Published var volume: Double {
        didSet { player.volume = Float(volume); defaults.set(volume, forKey: Keys.volume) }
    }
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    private enum Keys {
        static let volume = "player.volume"
        static let shuffle = "player.shuffle"
        static let repeatMode = "player.repeat"
        static let queue = "player.lastQueue"
        static let item = "player.lastItem"
    }

    private let defaults: UserDefaults
    private var queue = PlayQueue<UUID>()
    private var itemObservers: [AnyCancellable] = []
    private var timeObserver: Any?
    private var lastSavedAt: TimeInterval = 0
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioOptions: [String: AVMediaSelectionOption] = [:]
    private var subtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var consecutiveFailures = 0
    private var libraryObserver: AnyCancellable?
    private var startWhenReady = false
    private var resumeAt: TimeInterval = 0

    /// True once something has been played this session: the mini player and the controls are shown from then on.
    var hasSession: Bool { current != nil && state != .stopped }
    var isPlaying: Bool { state == .playing }

    /// `defaults` is for tests, which keep their volume, queue and modes apart from the user's.
    init(library: PlayerLibrary, defaults: UserDefaults = .standard) {
        self.library = library
        self.defaults = defaults
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        player.volume = Float(volume)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        isShuffled = defaults.bool(forKey: Keys.shuffle)
        repeatMode = PlayQueue<UUID>.RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        queue.repeatMode = repeatMode
        queue.setShuffle(isShuffled)
        installTimeObserver()
        // Items taken out of the library must also leave the queue.
        libraryObserver = library.$items.dropFirst().sink { [weak self] items in
            guard let self else { return }
            let alive = Set(items.map(\.id))
            for id in self.queue.list where !alive.contains(id) { self.removeFromQueue(id) }
        }
        restoreLastSession()
    }

    private func setState(_ new: PlayerState, _ reason: String) {
        stateLog.append(String(format: "%.2f %@ -> %@ (%@) item=%@", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000), "\(state)", "\(new)", reason, current?.title ?? "-"))
        if stateLog.count > 14 { stateLog.removeFirst(stateLog.count - 14) }
        state = new
    }

    // MARK: Starting playback

    /// Plays `start` and queues `ids` after it, in the order given (the list the user clicked in).
    func play(ids: [UUID], start: UUID, resume: Bool = true) {
        queue.load(ids, start: start)
        publishQueue()
        consecutiveFailures = 0
        load(start, autoplay: true, resume: resume)
    }

    /// Plays an item from the queue (a click in the queue list).
    func playFromQueue(_ id: UUID) {
        guard queue.list.contains(id) else { return }
        queue.select(id)
        publishQueue()
        consecutiveFailures = 0
        load(id, autoplay: true, resume: false)
    }

    /// Play, or pause when playing; with nothing loaded, picks up the last session.
    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resumePlayback()
        case .loading:
            startWhenReady.toggle()
            stateLog.append("togglePlayPause while loading -> startWhenReady=\(startWhenReady)")
        case .stopped, .failed:
            if let id = queue.current ?? current?.id { consecutiveFailures = 0; load(id, autoplay: true, resume: true) }
        }
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        setState(.paused, "pause()")
        persistProgress()
    }

    func resumePlayback() {
        guard state == .paused else { return }
        player.play()
        player.rate = rate
        setState(.playing, "resumePlayback()")
    }

    func stop() {
        persistProgress()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
        setState(.stopped, "stop()")
        time = 0
        audioTracks = []; subtitleTracks = []
    }

    // MARK: Moving

    func next() {
        guard let target = queue.advance(natural: false) else { stopAtEnd(); return }
        publishQueue()
        load(target, autoplay: true, resume: false)
    }

    /// Back to the start of the track if it has played for a while, otherwise to the track before it.
    func previous() {
        if time > 3 { seek(to: 0); return }
        guard let target = queue.goBack() else { seek(to: 0); return }
        publishQueue()
        load(target, autoplay: true, resume: false)
    }

    func seek(to seconds: TimeInterval, precise: Bool = true) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        time = target
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func skip(by seconds: TimeInterval) { seek(to: time + seconds) }

    // MARK: Modes

    func toggleShuffle() {
        isShuffled.toggle()
        queue.setShuffle(isShuffled)
        defaults.set(isShuffled, forKey: Keys.shuffle)
        publishQueue()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        queue.repeatMode = repeatMode
        defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode)
    }

    func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if state == .playing { player.rate = value }
    }

    // MARK: Queue

    func playNext(_ id: UUID) {
        guard library.item(id) != nil else { return }
        queue.playNext(id)
        publishQueue()
    }

    func enqueue(_ id: UUID) {
        guard library.item(id) != nil else { return }
        queue.enqueue(id)
        publishQueue()
    }

    func removeFromQueue(_ id: UUID) {
        let wasCurrent = id == queue.current
        queue.remove(id)
        publishQueue()
        guard wasCurrent else { return }
        if let successor = queue.current, state == .playing || state == .loading {
            load(successor, autoplay: true, resume: false)
        } else {
            stop()
            current = queue.current.flatMap { library.item($0) }
        }
    }

    private func publishQueue() {
        queueOrder = queue.order
        defaults.set(queue.list.map(\.uuidString), forKey: Keys.queue)
        defaults.set(queue.current?.uuidString, forKey: Keys.item)
    }

    // MARK: Tracks

    func selectAudio(_ id: String) {
        guard let option = audioOptions[id], let group = audioGroup else { return }
        player.currentItem?.select(option, in: group)
        audioTracks = audioTracks.map { TrackOption(id: $0.id, name: $0.name, isSelected: $0.id == id) }
    }

    /// nil turns subtitles off.
    func selectSubtitle(_ id: String?) {
        guard let group = subtitleGroup else { return }
        player.currentItem?.select(id.flatMap { subtitleOptions[$0] }, in: group)
        subtitleTracks = subtitleTracks.map { TrackOption(id: $0.id, name: $0.name, isSelected: $0.id == id) }
    }

    // MARK: Loading

    private func load(_ id: UUID, autoplay: Bool, resume: Bool) {
        guard let item = library.item(id) else { fail(id: id, String(localized: "This file is no longer in the library."), skip: autoplay); return }
        guard let url = library.resolveURL(for: id) else { fail(id: id, String(localized: "The file could not be found."), skip: autoplay); return }

        persistProgress()   // for the track being left
        current = item
        time = 0; duration = item.duration
        audioTracks = []; subtitleTracks = []; audioGroup = nil; subtitleGroup = nil
        itemObservers.removeAll()
        setState(.loading, "load(autoplay: \(autoplay))")
        startWhenReady = autoplay
        resumeAt = resume ? item.resumePosition : 0
        lastSavedAt = 0

        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        playerItem.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self else { return }
            switch status {
            case .readyToPlay: MainActor.assumeIsolated { self.itemReady(playerItem, id: id) }
            case .failed:
                let reason = playerItem.error?.localizedDescription ?? String(localized: "This file cannot be played.")
                MainActor.assumeIsolated { self.fail(id: id, reason, skip: self.startWhenReady) }
            default: break
            }
        }.store(in: &itemObservers)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.itemEnded(id) }
            }.store(in: &itemObservers)
        publishQueue()
    }

    private func itemReady(_ playerItem: AVPlayerItem, id: UUID) {
        guard current?.id == id, state == .loading else { return }
        consecutiveFailures = 0
        let seconds = playerItem.duration.seconds
        if seconds.isFinite, seconds > 0 { duration = seconds; library.updateDuration(id, seconds) }
        Task { await loadTracks(for: playerItem) }
        let begin = resumeAt
        let go = startWhenReady
        let finish = { [weak self] in
            guard let self, self.current?.id == id else { return }
            if go {
                self.player.defaultRate = self.rate
                self.player.play()
                self.player.rate = self.rate
                self.setState(.playing, "itemReady autoplay")
                self.library.recordPlay(id)
            } else {
                self.setState(.paused, "itemReady without autoplay (startWhenReady=false)")
            }
        }
        if begin > 0 {
            time = begin
            player.seek(to: CMTime(seconds: begin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async { finish() }
            }
        } else {
            finish()
        }
    }

    private func loadTracks(for playerItem: AVPlayerItem) async {
        let asset = playerItem.asset
        func options(_ characteristic: AVMediaCharacteristic) async -> (AVMediaSelectionGroup?, [String: AVMediaSelectionOption], [TrackOption]) {
            guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic) else { return (nil, [:], []) }
            var map: [String: AVMediaSelectionOption] = [:]
            var list: [TrackOption] = []
            let selected = playerItem.currentMediaSelection.selectedMediaOption(in: group)
            for (index, option) in group.options.enumerated() {
                let id = "\(index)"
                map[id] = option
                list.append(TrackOption(id: id, name: option.displayName, isSelected: option == selected))
            }
            return (group, map, list)
        }
        let (audio, audioMap, audioList) = await options(.audible)
        let (legible, legibleMap, legibleList) = await options(.legible)
        guard player.currentItem === playerItem else { return }
        audioGroup = audio; audioOptions = audioMap; audioTracks = audioList.count > 1 ? audioList : []
        subtitleGroup = legible; subtitleOptions = legibleMap; subtitleTracks = legibleList
    }

    private func itemEnded(_ id: UUID) {
        guard current?.id == id else { return }
        library.recordPosition(id, 0)   // finished: next time starts from the beginning
        guard let target = queue.advance(natural: true) else { stopAtEnd(); return }
        publishQueue()
        if target == id {
            seek(to: 0)
            player.play(); player.rate = rate
            setState(.playing, "repeat one")
            library.recordPlay(id)
        } else {
            load(target, autoplay: true, resume: false)
        }
    }

    /// The queue ran out: stay on the last track, paused at the start.
    private func stopAtEnd() {
        player.pause()
        setState(.paused, "stopAtEnd")
        seek(to: 0)
    }

    /// A file that cannot be played. When playback was running the next one is tried (at most once around the queue), so
    /// one bad file does not end an album; otherwise the error is shown on the track.
    private func fail(id: UUID, _ reason: String, skip: Bool) {
        current = library.item(id) ?? current
        consecutiveFailures += 1
        if skip, consecutiveFailures < max(queue.list.count, 1), let target = queue.advance(natural: false), target != id {
            publishQueue()
            load(target, autoplay: true, resume: false)
            return
        }
        player.pause()
        setState(.failed(reason), "fail")
    }

    // MARK: Clock and progress

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] cmTime in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.state == .playing, !self.isScrubbing else { return }
                let seconds = cmTime.seconds
                guard seconds.isFinite else { return }
                self.time = seconds
                if seconds - self.lastSavedAt >= 5 || seconds < self.lastSavedAt {
                    self.lastSavedAt = seconds
                    if let id = self.current?.id { self.library.recordPosition(id, seconds) }
                }
            }
        }
    }

    /// Writes where the current track is. Called when pausing, switching, stopping and quitting.
    func persistProgress() {
        guard let id = current?.id, time > 0 else { return }
        library.recordPosition(id, time)
        library.saveNow()
    }

    // MARK: Last session

    /// Shows the track that was last played, paused where it stopped, without loading it or starting any sound.
    private func restoreLastSession() {
        let ids = (defaults.stringArray(forKey: Keys.queue) ?? []).compactMap(UUID.init).filter { library.item($0) != nil }
        guard !ids.isEmpty else { return }
        let last = defaults.string(forKey: Keys.item).flatMap(UUID.init)
        queue.load(ids, start: last)
        queue.repeatMode = repeatMode
        publishQueue()
        current = queue.current.flatMap { library.item($0) }
        time = current?.resumePosition ?? 0
        duration = current?.duration ?? 0
    }
}
