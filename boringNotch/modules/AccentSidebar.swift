//
//  AccentSidebar.swift
//  boringNotch
//
//  A sidebar row selected in the user's own accent colour. A List with a selection binding always paints the selection in
//  the asset's fixed accent and ignores .tint, so the windows' sidebars use plain buttons with this background instead
//  (as the settings window does).
//

import SwiftUI

struct AccentSidebarRow<Content: View>: View {
    let selected: Bool
    var highlighted: Bool = false
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.effectiveAccent : highlighted ? Color.effectiveAccent.opacity(0.25) : Color.clear)
                .padding(.horizontal, 8)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Icon and count colours that stay readable on a selected row.
struct SidebarRowLabel: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(selected ? Color.white : Color.effectiveAccent)
                .frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
    }
}
