//
//  ChartInput.swift
//  boringNotch
//
//  Scroll-wheel and pinch input for the chart. SwiftUI has no scroll or magnify event on macOS, so a local event
//  monitor watches for them and acts only when the pointer is over the view it is attached to; everything else is
//  passed on untouched.
//

import AppKit
import SwiftUI

struct ChartInput: NSViewRepresentable {
    /// Scroll deltas in points; `precise` is true for a trackpad.
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ precise: Bool) -> Void
    var onMagnify: (_ magnification: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        private var monitor: Any?

        /// Never takes clicks or hover: those belong to the SwiftUI chart above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let frame = self.convert(self.bounds, to: nil)
                guard frame.contains(event.locationInWindow) else { return event }
                switch event.type {
                case .scrollWheel: self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                case .magnify: self.onMagnify?(event.magnification)
                default: return event
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
