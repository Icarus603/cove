//
//  PlayerVideoView.swift
//  boringNotch
//
//  A video with its controls laid over it. The same view fills the notch when a video plays there and the floating window
//  when it is popped out. The controls fade away while a video plays and the pointer rests.
//

import AppKit
import SwiftUI

struct PlayerVideoView: View {
    @ObservedObject var engine: PlayerEngine
    /// In the notch: a button leads back to the library. In the floating window there is nowhere to go back to.
    var showsBack: Bool
    var isFloating: Bool

    @ObservedObject private var ui = PlayerUI.shared
    @State private var lastPoint: CGPoint?

    /// Always shown unless a video is playing and nothing has happened for a moment.
    private var shouldShowControls: Bool {
        if case .playing = engine.state { return ui.controlsVisible }
        return true
    }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: engine.player)
            // A tap plays or pauses; a double tap goes full screen (and back), as in any video player.
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { ui.toggleFullScreen() }
                .onTapGesture { engine.togglePlayPause() }

            statusOverlay

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(shouldShowControls ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: shouldShowControls)
        }
        .onContinuousHover { phase in
            // Only a pointer that really moved counts: a view that is laid out again under a resting pointer also reports
            // "hovering", and must not keep calling the controls back.
            guard case .active(let point) = phase else { return }
            defer { lastPoint = point }
            if let last = lastPoint, hypot(point.x - last.x, point.y - last.y) < 2 { return }
            ui.pokeControls()
        }
        .onChange(of: engine.state) { _, state in if state == .playing { ui.pokeControls() } }
        .clipShape(RoundedRectangle(cornerRadius: isFloating ? 0 : 12, style: .continuous))
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 8) {
            if showsBack {
                PlayerIconButton(symbol: "chevron.left", help: "Library") { ui.mode = .library }
            }
            Text(engine.current?.title ?? "")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .shadow(radius: 3)
            Spacer()
            PlayerOptionsMenus(engine: engine)
            if !ui.isFullScreen {
                PlayerIconButton(symbol: isFloating ? "rectangle.badge.arrow.down" : "arrow.up.forward.app", help: isFloating ? LocalizedStringKey("Back to the notch") : LocalizedStringKey("Pop out")) {
                    if isFloating { ui.popIn() } else { ui.popOut() }
                }
            }
            PlayerIconButton(symbol: ui.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             help: ui.isFullScreen ? LocalizedStringKey("Exit full screen") : LocalizedStringKey("Full screen")) { ui.toggleFullScreen() }
        }
        // In the popped-out window the row is a toolbar row: the standard height, level with the window buttons, and starting clear of
        // them (full screen has none).
        .frame(height: isFloating && !ui.isFullScreen ? ToolbarMetrics.height : nil)
        .padding(.leading, isFloating && !ui.isFullScreen ? ImmersiveChrome.leadingInsetForButtons : 10)
        .padding(.trailing, 10)
        .padding(.top, isFloating && !ui.isFullScreen ? ImmersiveChrome.controlsTopInset : 8)
        .padding(.bottom, 18)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            ScrubBar(engine: engine)
            ZStack {
                HStack(spacing: 14) {
                    PlayerIconButton(symbol: "gobackward.10", size: 14, help: "Back 10 seconds") { engine.skip(by: -10) }
                    TransportRow(engine: engine, large: true)
                    PlayerIconButton(symbol: "goforward.10", size: 14, help: "Forward 10 seconds") { engine.skip(by: 10) }
                }
                HStack {
                    VolumeControl(engine: engine, barWidth: 60)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 20)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch engine.state {
        case .loading:
            ProgressView().controlSize(.regular).tint(.white)
        case .failed(let reason):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(Color.coveWarning)
                Text(reason).font(.callout).multilineTextAlignment(.center)
                if let item = engine.current, PlayerLibrary.shared.missing.contains(item.id) {
                    Button("Locate…") { ui.locate(item) }.controlSize(.small)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.8)))
        default:
            EmptyView()
        }
    }
}
