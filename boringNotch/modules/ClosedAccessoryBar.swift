//
//  ClosedAccessoryBar.swift
//  boringNotch
//
//  Draws module accessories (agent mascot, plugin badges) on either side of the closed notch.
//  Each wing is placed from the notch's own edge outwards, so none of it hides behind the notch.
//

import NotchKit
import SwiftUI

struct ClosedAccessoryBar: View {
    @ObservedObject private var registry = AppModules.registry
    let notchWidth: CGFloat
    let height: CGFloat

    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 6
    /// How far a wing tucks under the notch so no hairline shows between them.
    private static let tuck: CGFloat = 3

    private var accessories: [ClosedAccessory] {
        registry.visibleModules.compactMap(\.closedAccessory)
    }

    private func width(of items: [ClosedAccessory]) -> CGFloat {
        items.map(\.width).reduce(0, +) + Self.spacing * CGFloat(max(items.count - 1, 0)) + Self.inset * 2
    }

    var body: some View {
        let leading = accessories.filter { $0.side == .leading }
        let trailing = accessories.filter { $0.side == .trailing }
        ZStack(alignment: .top) {
            if !leading.isEmpty {
                wing(leading, edge: .leading)
                    .offset(x: -(notchWidth / 2) - width(of: leading) / 2 + Self.tuck)
            }
            if !trailing.isEmpty {
                wing(trailing, edge: .trailing)
                    .offset(x: notchWidth / 2 + width(of: trailing) / 2 - Self.tuck)
            }
        }
        .frame(width: notchWidth, height: height, alignment: .top)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func wing(_ items: [ClosedAccessory], edge: HorizontalEdge) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                item.view.frame(width: item.width, height: height)
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(height: height)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: edge == .leading ? 12 : 0,
                bottomTrailingRadius: edge == .trailing ? 12 : 0
            ).fill(.black)
        )
    }
}
