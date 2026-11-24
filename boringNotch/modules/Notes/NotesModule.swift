//
//  NotesModule.swift
//  boringNotch
//

import NotchKit
import SwiftUI

@MainActor
final class NotesModule: NotchModule {
    static let moduleID = "builtin.notes"

    let id = NotesModule.moduleID
    var title: String { String(localized: "Notes") }
    let systemImage = "note.text"
    let tabOrder = 19

    var preferredContentSize: CGSize? { CGSize(width: 600, height: 262) }

    func makeExpandedView() -> AnyView { AnyView(NotesView()) }

    /// Leaving the tab (or closing the notch) puts the pen down: what is typed is kept, and the panel goes.
    func deactivate() {
        NoteTextInputController.shared.end()
        NotesStore.shared.flush()
    }
}
