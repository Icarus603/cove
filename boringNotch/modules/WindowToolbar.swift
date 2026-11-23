//
//  WindowToolbar.swift
//  boringNotch
//
//  The few controls the library windows' toolbars are built from, all on one grid: every control is 28 pt high and centred
//  on the same line, icon buttons are 28 pt squares, text buttons are pills of the same height. Menus use the same labels so
//  a menu and a button next to each other line up.
//

import SwiftUI

enum ToolbarMetrics {
    static let height: CGFloat = 28
}

/// A square icon button, with a soft highlight under the pointer.
struct ToolbarIconButton: View {
    let symbol: String
    var help: LocalizedStringKey
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: ToolbarMetrics.height, height: ToolbarMetrics.height)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering && isEnabled ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(isEnabled ? 0.8 : 0.3))
        .onHover { hovering = $0 }
        .help(Text(help))
    }
}

/// The look of a text control: an icon and a title in a pill. `prominent` is the one main action of the bar (the neutral
/// dark pill, not an accent colour); the rest are quiet.
struct ToolbarPillLabel: View {
    let title: LocalizedStringKey
    var symbol: String? = nil
    var prominent = false
    var showsChevron = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if showsChevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7) }
        }
        .padding(.horizontal, 11)
        .frame(height: ToolbarMetrics.height)
        .background(Capsule().fill(prominent ? (scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88)) : Color.primary.opacity(0.08)))
        .foregroundStyle(prominent ? (scheme == .dark ? Color.black : Color.white) : Color.primary.opacity(isEnabled ? 0.85 : 0.3))
        .contentShape(Capsule())
    }
}

struct ToolbarPillButton: View {
    let title: LocalizedStringKey
    var symbol: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { ToolbarPillLabel(title: title, symbol: symbol, prominent: prominent) }
            .buttonStyle(.plain)
    }
}

/// A search field on the same grid.
struct ToolbarSearchField: View {
    @Binding var text: String
    var width: CGFloat = 170

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: ToolbarMetrics.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}
