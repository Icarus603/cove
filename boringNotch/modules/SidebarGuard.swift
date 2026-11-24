//
//  SidebarGuard.swift
//  boringNotch
//
//  Keeps a split-view sidebar from being dragged away. The window's sidebar has a width range (190 to 300 pt), but dragging it narrower
//  than the least does not stop there: it folds the sidebar away altogether, and where there is no button to bring it back (the
//  Settings window has none) it is gone for good. This takes away the folding, so the sidebar stops at its least width.
//

import AppKit
import SwiftUI

struct SidebarGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The split view is built a moment after this view appears.
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let root = view?.window?.contentView else { return }
                Self.guardSidebars(in: root)
            }
        }
    }

    private static func guardSidebars(in view: NSView) {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
            for item in controller.splitViewItems where item.behavior == .sidebar { item.canCollapse = false }
        }
        view.subviews.forEach { guardSidebars(in: $0) }
    }
}
