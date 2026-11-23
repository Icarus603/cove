//
//  PlayerControls.swift
//  boringNotch
//
//  The pieces the notch tab, the floating window and the video overlay share: the video surface, a thin draggable bar
//  for position and volume, the transport buttons and the small menus (speed, audio and subtitle tracks).
//

import AVFoundation
import AppKit
import SwiftUI

enum PlayerFormat {
    /// 3:07 or 1:02:09.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func rate(_ value: Float) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%g×", value)
    }
}

// MARK: Video surface

/// Draws an AVPlayer's video. Several can exist for one player (the notch and the floating window); each shows the same
/// picture, and a surface that goes away lets go of the player so a hidden one never keeps drawing.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }

    static func dismantleNSView(_ view: LayerView, coordinator: ()) { view.playerLayer.player = nil }

    final class LayerView: NSView {
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError() }
        override func makeBackingLayer() -> CALayer {
            let layer = AVPlayerLayer()
            layer.backgroundColor = NSColor.black.cgColor
            return layer
        }
        override var acceptsFirstResponder: Bool { false }
    }
}

// MARK: Thin slider

/// A slim bar that is clicked or dragged, for position and volume. It thickens under the pointer so it is easy to grab.
struct ThinSlider: View {
    /// 0...1
    let value: Double
    var tint: Color = .white
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void = { _ in }
    /// Time (or other text) shown over the pointer while hovering: receives the fraction under it.
    var hoverLabel: ((Double) -> String)?

    @State private var hovering = false
    @State private var dragging = false
    @State private var hoverFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: hovering || dragging ? 5 : 3)
                Capsule().fill(tint).frame(width: width * fraction, height: hovering || dragging ? 5 : 3)
                Circle().fill(Color.white).frame(width: 10, height: 10)
                    .offset(x: width * fraction - 5)
                    .opacity(hovering || dragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let hoverLabel, let hoverFraction, hovering || dragging {
                    Text(hoverLabel(hoverFraction))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.85)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                        .fixedSize()
                        .position(x: min(max(width * hoverFraction, 22), width - 22), y: -8)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovering = true; hoverFraction = min(max(point.x / width, 0), 1)
                case .ended: hovering = false; hoverFraction = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    let f = min(max(drag.location.x / width, 0), 1)
                    hoverFraction = f
                    onChange(f)
                }
                .onEnded { drag in
                    dragging = false
                    onCommit(min(max(drag.location.x / width, 0), 1))
                })
        }
        .frame(height: 14)
    }
}

/// Playback position with the times at either end.
struct ScrubBar: View {
    @ObservedObject var engine: PlayerEngine
    var showsTimes = true

    var body: some View {
        VStack(spacing: 1) {
            ThinSlider(
                value: engine.duration > 0 ? engine.time / engine.duration : 0,
                onChange: { f in engine.isScrubbing = true; engine.seek(to: f * engine.duration, precise: false) },
                onCommit: { f in engine.seek(to: f * engine.duration, precise: true); engine.isScrubbing = false },
                hoverLabel: { PlayerFormat.clock($0 * engine.duration) })
            if showsTimes {
                HStack {
                    Text(PlayerFormat.clock(engine.time))
                    Spacer()
                    Text("-" + PlayerFormat.clock(max(engine.duration - engine.time, 0)))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Buttons

struct PlayerIconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var active = false
    var help: LocalizedStringKey? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Color.effectiveAccent : Color.white.opacity(0.85))
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help.map { Text($0) } ?? Text(""))
    }
}

/// Shuffle, previous, play / pause, next, repeat.
struct TransportRow: View {
    @ObservedObject var engine: PlayerEngine
    var large = false

    var body: some View {
        HStack(spacing: large ? 14 : 8) {
            PlayerIconButton(symbol: "shuffle", active: engine.isShuffled, help: "Shuffle") { engine.toggleShuffle() }
            PlayerIconButton(symbol: "backward.fill", size: large ? 16 : 13, help: "Previous") { engine.previous() }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: large ? 34 : 30))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(Text(LocalizedStringKey(engine.isPlaying ? "Pause" : "Play")))
            PlayerIconButton(symbol: "forward.fill", size: large ? 16 : 13, help: "Next") { engine.next() }
            PlayerIconButton(symbol: engine.repeatMode == .one ? "repeat.1" : "repeat", active: engine.repeatMode != .off, help: "Repeat") { engine.cycleRepeat() }
        }
    }
}

/// Speaker button and a short volume bar.
struct VolumeControl: View {
    @ObservedObject var engine: PlayerEngine
    var barWidth: CGFloat = 56

    private var symbol: String {
        if engine.isMuted || engine.volume == 0 { return "speaker.slash.fill" }
        return engine.volume < 0.34 ? "speaker.wave.1.fill" : (engine.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }

    var body: some View {
        HStack(spacing: 2) {
            PlayerIconButton(symbol: symbol, size: 11, help: "Mute") { engine.isMuted.toggle() }
            ThinSlider(value: engine.isMuted ? 0 : engine.volume,
                       onChange: { engine.isMuted = false; engine.volume = $0 },
                       hoverLabel: { "\(Int(($0 * 100).rounded()))%" })
                .frame(width: barWidth)
        }
    }
}

/// Speed, and, for files that have them, audio and subtitle tracks.
struct PlayerOptionsMenus: View {
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(PlayerEngine.rates, id: \.self) { value in
                    Button { engine.setRate(value) } label: {
                        if engine.rate == value { Label(PlayerFormat.rate(value), systemImage: "checkmark") } else { Text(PlayerFormat.rate(value)) }
                    }
                }
            } label: {
                Text(PlayerFormat.rate(engine.rate))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(engine.rate == 1 ? Color.white.opacity(0.85) : Color.effectiveAccent)
                    .frame(minWidth: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(Text("Speed"))

            if !engine.audioTracks.isEmpty || !engine.subtitleTracks.isEmpty {
                Menu {
                    if !engine.audioTracks.isEmpty {
                        Section("Audio") {
                            ForEach(engine.audioTracks) { track in
                                Button { engine.selectAudio(track.id) } label: {
                                    if track.isSelected { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                                }
                            }
                        }
                    }
                    if !engine.subtitleTracks.isEmpty {
                        Section("Subtitles") {
                            Button { engine.selectSubtitle(nil) } label: {
                                if engine.subtitleTracks.allSatisfy({ !$0.isSelected }) { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                            }
                            ForEach(engine.subtitleTracks) { track in
                                Button { engine.selectSubtitle(track.id) } label: {
                                    if track.isSelected { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(engine.subtitleTracks.contains { $0.isSelected } ? Color.effectiveAccent : Color.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text("Audio and subtitles"))
            }
        }
    }
}
