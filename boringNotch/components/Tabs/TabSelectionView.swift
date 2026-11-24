//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import NotchKit
import SwiftUI

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var registry = AppModules.registry
    @Namespace var animation
    /// Room kept free beside the notch, so the last icon never touches it.
    static let clearanceFromNotch: CGFloat = 8
    var body: some View {
        // The room beside the notch is fixed, so the icons share it: the more tabs, the closer they sit (down to a floor), and
        // never a tab behind the notch.
        GeometryReader { geo in
            let count = max(registry.visibleModules.count, 1)
            let padding = min(TabButton.roomiestPadding,
                              max(TabButton.tightestPadding, ((geo.size.width - TabSelectionView.clearanceFromNotch) / CGFloat(count) - TabButton.iconWidth) / 2))
            HStack(spacing: 0) {
                ForEach(registry.visibleModules, id: \.id) { module in
                    let tab = NotchViews(id: module.id)
                    TabButton(label: module.title, icon: module.systemImage, selected: coordinator.currentView == tab, horizontalPadding: padding) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
                }
            }
            .clipShape(Capsule())
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 26)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
