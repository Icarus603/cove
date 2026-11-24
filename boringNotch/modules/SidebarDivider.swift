//
//  SidebarDivider.swift
//  boringNotch
//
//  The sidebar of a window laid out by hand has a width of its own, within a range it cannot leave: it cannot be folded away
//  (there is no button to bring it back), and it cannot be squeezed until its words are gone.
//

import AppKit
import SwiftUI

/// The line between the sidebar and the page, which can be dragged to change the sidebar's width (190 to 300 pt, as in the Player
/// library window). The pointer shows it can be moved while it is over the line.
struct SidebarDivider: View {
    @Binding var width: Double
    @State private var startWidth: Double?
    @State private var hovering = false
    static let range: ClosedRange<Double> = 190...300

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = startWidth ?? width
                            startWidth = start
                            width = min(max(start + drag.translation.width, Self.range.lowerBound), Self.range.upperBound)
                        }
                        .onEnded { _ in startWidth = nil })
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }
}
