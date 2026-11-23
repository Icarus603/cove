//
//  PhotosModule.swift
//  boringNotch
//

import NotchKit
import SwiftUI

@MainActor
final class PhotosModule: NotchModule {
    static let moduleID = "builtin.photos"

    let id = PhotosModule.moduleID
    var title: String { String(localized: "Photos") }
    let systemImage = "photo.on.rectangle"
    let tabOrder = 18

    var preferredContentSize: CGSize? { CGSize(width: 600, height: 262) }

    func makeExpandedView() -> AnyView { AnyView(PhotoNotchView()) }
}
