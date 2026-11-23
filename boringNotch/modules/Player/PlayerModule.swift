//
//  PlayerModule.swift
//  boringNotch
//

import Combine
import NotchKit
import SwiftUI

@MainActor
final class PlayerModule: NotchModule {
    static let moduleID = "builtin.player"

    let id = PlayerModule.moduleID
    var title: String { String(localized: "Player") }
    let systemImage = "play.rectangle.fill"
    let tabOrder = 15

    /// A video filling the tab wants a large notch; the library and controls fit the usual size.
    var preferredContentSize: CGSize? {
        let engine = PlayerEngine.shared, ui = PlayerUI.shared
        let videoFills = ui.mode == .video && engine.current?.kind == .video && !ui.isPoppedOut && engine.state != .stopped
        return videoFills ? CGSize(width: 680, height: 400) : CGSize(width: 600, height: 262)
    }

    var changes: AnyPublisher<Void, Never> {
        let engine = PlayerEngine.shared, ui = PlayerUI.shared
        // Delivered on the next turn so the host reads the size after the values have really changed.
        return Publishers.MergeMany(
            engine.$current.map { _ in () }.eraseToAnyPublisher(),
            engine.$state.map { _ in () }.eraseToAnyPublisher(),
            ui.$mode.map { _ in () }.eraseToAnyPublisher(),
            ui.$isPoppedOut.map { _ in () }.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func makeExpandedView() -> AnyView { AnyView(PlayerView()) }
}

/// Whether the collapsed notch shows the mini player: while something plays, and for a few seconds after it is paused.
@MainActor
final class PlayerMiniState: ObservableObject {
    static let shared = PlayerMiniState()

    @Published private(set) var visible = false
    private var hideTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []

    private init() {
        let engine = PlayerEngine.shared
        // A @Published publisher fires before the value changes, so the new state is taken from the event, never re-read.
        engine.$state.removeDuplicates().sink { [weak self] state in self?.update(state) }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.update(PlayerEngine.shared.state) }
        }.store(in: &observers)
        update(engine.state)
    }

    private func update(_ state: PlayerState) {
        let enabled = UserDefaults.standard.object(forKey: PlayerSettingsKey.miniBar) as? Bool ?? true
        guard enabled else { set(false); return }
        switch state {
        case .playing, .loading:
            hideTask?.cancel(); hideTask = nil
            set(true)
        case .paused:
            guard visible, hideTask == nil else { return }
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                self?.set(false)
                self?.hideTask = nil
            }
        case .stopped, .failed:
            hideTask?.cancel(); hideTask = nil
            set(false)
        }
    }

    private func set(_ value: Bool) { if visible != value { visible = value } }
}

/// The mini player beside the closed notch: the cover on the left, the spectrum on the right, a thin progress line along
/// the bottom. A fixed width, like the music live activity it stands in for.
struct PlayerMiniBar: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    @ObservedObject private var now = PlayerUI.shared.now
    @ObservedObject private var library = PlayerLibrary.shared
    @ObservedObject private var engine = PlayerEngine.shared

    private var side: CGFloat { max(0, notchHeight - 12) }
    var body: some View {
        HStack {
            cover
                .frame(width: side, height: side)
            Rectangle().fill(.black).frame(width: notchWidth - cornerRadiusInsets.closed.top)
            Rectangle().fill(Color.gray.gradient)
                .frame(width: 50, alignment: .center)
                .mask { AudioSpectrumView(isPlaying: Binding(get: { now.isPlaying }, set: { _ in })).frame(width: 16, height: 12) }
                .frame(width: side, height: side)
        }
        .frame(height: notchHeight, alignment: .center)
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Capsule().fill(Color.effectiveAccent.opacity(0.9))
                    .frame(width: geo.size.width * (engine.duration > 0 ? min(engine.time / engine.duration, 1) : 0), height: 1.5)
                    .offset(y: geo.size.height - 1.5)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var cover: some View {
        // Music shows its cover. A video shows the video itself, shrunk to the corner and still playing (the whole frame, not a
        // cropped square: a still cut down to 30 pt reads as a random patch of colour, but moving picture is recognisable).
        if let item = engine.current, item.kind == .video {
            // A 16:9 picture in the square slot fills its width and has black bars above and below, which melt into the notch
            // and leave a small rectangle against the screen's edge. A little smaller, and pushed toward the notch, it has
            // room on its outer side. The slot itself (and so the layout of the notch) is the same as for a song.
            // The same look as a YouTube thumbnail beside the notch (SquareArtwork): the picture whole, in the middle of a square,
            // over a blurred, enlarged copy of itself, and the same inset and shift.
            ZStack {
                VideoSurface(player: engine.player, gravity: .resizeAspectFill).blur(radius: 4).opacity(0.85)
                VideoSurface(player: engine.player, gravity: .resizeAspect)
            }
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
            .frame(width: side - SquareArtwork.wideInset, height: side - SquareArtwork.wideInset)
            .frame(width: side, height: side, alignment: .trailing)
            .offset(x: SquareArtwork.wideShift)
        } else if let item = engine.current, item.kind == .audio, let image = library.artwork(for: item) {
            Image(nsImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
        } else {
            RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed).fill(Color.white.opacity(0.18))
                .overlay { Image(systemName: "waveform").font(.system(size: max(side * 0.5, 6))).foregroundStyle(.white.opacity(0.8)) }
        }
    }
}
