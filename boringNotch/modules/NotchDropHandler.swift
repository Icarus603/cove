//
//  NotchDropHandler.swift
//  boringNotch
//
//  Takes a drop onto the open shelf at the AppKit level. SwiftUI's own drop targets inside the notch were not
//  being entered during a drag, so anything dragged onto the shelf slid off to whatever was underneath.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag carries, turned into the item providers the shelf already knows how to store.
enum NotchDropHandler {
    static func providers(from pasteboard: NSPasteboard) async -> [NSItemProvider] {
        var result: [NSItemProvider] = []

        // Files: from Finder, or a screenshot thumbnail that carries a file URL.
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for url in fileURLs { if let provider = NSItemProvider(contentsOf: url) { result.append(provider) } }
        if !result.isEmpty { return result }

        // File promises: apps that write the file only when it is dropped (screenshot thumbnails, browsers, Photos).
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoveDrops-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for receiver in receivers {
                let url: URL? = await withCheckedContinuation { continuation in
                    receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                        continuation.resume(returning: error == nil ? url : nil)
                    }
                }
                if let url, let provider = NSItemProvider(contentsOf: url) { result.append(provider) }
            }
            if !result.isEmpty { return result }
        }

        // A web address.
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first(where: { !$0.isFileURL }) {
            return [NSItemProvider(object: url as NSURL)]
        }

        // Image data with no file behind it.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                let identifier = type == .png ? UTType.png.identifier : UTType.tiff.identifier
                let provider = NSItemProvider(item: data as NSData, typeIdentifier: identifier)
                provider.suggestedName = "Image"
                return [provider]
            }
        }

        // Plain text.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [NSItemProvider(object: text as NSString)]
        }
        return []
    }
}

/// The notch window's content view. SwiftUI registers a private drop-destination view inside it that never hands a drag to
/// the shelf's own targets here, so this view takes that registration over and accepts drops onto the open notch itself.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    private let viewModel: BoringViewModel
    private var reclaimTimer: Timer?

    init(rootView: Content, viewModel: BoringViewModel) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @MainActor required init(rootView: Content) { fatalError("use init(rootView:viewModel:)") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { reclaimTimer?.invalidate() }

    private static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Switches off SwiftUI's own destination view so this one is the deepest registered view under a drag.
    private func claimRegistration() {
        func visit(_ view: NSView) {
            if String(describing: type(of: view)).contains("DraggingDestination"), !view.registeredDraggedTypes.isEmpty {
                view.unregisterDraggedTypes()
            }
            view.subviews.forEach(visit)
        }
        visit(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reclaimTimer?.invalidate()
        guard window != nil else { return }
        claimRegistration()
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.claimRegistration() }
    }

    override func layout() {
        super.layout()
        claimRegistration()
    }

    private func takes(_ sender: NSDraggingInfo) -> Bool {
        guard viewModel.notchState == .open else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let width = viewModel.notchSize.width, height = viewModel.notchSize.height
        let left = (bounds.width - width) / 2
        return point.x >= left && point.x <= left + width && fromTop >= 0 && fromTop <= height + 16
    }

    /// Whether the drag is over the AirDrop zone beside the shelf.
    private func overAirDrop(_ sender: NSDraggingInfo) -> Bool {
        guard viewModel.airDropHandler != nil, let zone = viewModel.airDropZoneView, zone.window === window else { return false }
        return zone.convert(zone.bounds, to: nil).contains(sender.draggingLocation)
    }

    private func setTargets(shelf: Bool, airDrop: Bool) {
        if viewModel.dragDetectorTargeting != shelf { viewModel.dragDetectorTargeting = shelf }
        if viewModel.dropZoneTargeting != airDrop { viewModel.dropZoneTargeting = airDrop }
    }

    private func follow(_ sender: NSDraggingInfo) -> NSDragOperation {
        claimRegistration()
        guard takes(sender) else {
            setTargets(shelf: false, airDrop: false)
            return []
        }
        if BoringViewCoordinator.shared.currentView.id != "builtin.shelf" { BoringViewCoordinator.shared.currentView = .shelf }
        let airDrop = overAirDrop(sender)
        setTargets(shelf: !airDrop, airDrop: airDrop)
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = follow(sender)
        return result
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargets(shelf: false, airDrop: false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { takes(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard takes(sender) else { return false }
        let toAirDrop = overAirDrop(sender)
        viewModel.dropEvent = true
        setTargets(shelf: false, airDrop: false)
        Task { @MainActor in
            let providers = await NotchDropHandler.providers(from: pasteboard)
            guard !providers.isEmpty else { return }
            if toAirDrop { viewModel.airDropHandler?(providers) } else { ShelfStateViewModel.shared.load(providers) }
        }
        return true
    }
}
