//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    /// Space on each side of the icon. The tab bar narrows it as tabs are added, so all of them stay clear of the notch.
    var horizontalPadding: CGFloat = TabButton.roomiestPadding
    let onClick: () -> Void

    /// Every icon is given the same width, so a row of tabs is as wide as its count says, whatever the symbols are.
    static let iconWidth: CGFloat = 18
    static let roomiestPadding: CGFloat = 9
    static let tightestPadding: CGFloat = 3

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .frame(width: TabButton.iconWidth)
                .padding(.horizontal, horizontalPadding)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
