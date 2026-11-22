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
    var body: some View {
        HStack(spacing: 0) {
            ForEach(registry.visibleModules, id: \.id) { module in
                    let tab = NotchViews(id: module.id)
                    TabButton(label: module.title, icon: module.systemImage, selected: coordinator.currentView == tab) {
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
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
