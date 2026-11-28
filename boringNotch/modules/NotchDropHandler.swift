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
    struct PasteboardSnapshot {
        let fileURLs: [URL]
        let promiseReceivers: [NSFilePromiseReceiver]
        let webURL: URL?
        let imageData: (data: Data, identifier: String)?
        let text: String?
    }

    /// Reads the drag pasteboard synchronously (must be called before `performDragOperation` returns).
    static func snapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let promiseReceivers = fileURLs.isEmpty
            ? ((pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? [])
            : []
        let webURL = (fileURLs.isEmpty && promiseReceivers.isEmpty)
            ? (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first(where: { !$0.isFileURL })
            : nil

        var imageData: (Data, String)?
        if fileURLs.isEmpty && promiseReceivers.isEmpty && webURL == nil {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = pasteboard.data(forType: type) {
                    let identifier = type == .png ? UTType.png.identifier : UTType.tiff.identifier
                    imageData = (data, identifier)
                    break
                }
            }
        }

        let text: String? = (fileURLs.isEmpty && promiseReceivers.isEmpty && webURL == nil && imageData == nil)
            ? pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
            : nil

        return PasteboardSnapshot(
            fileURLs: fileURLs,
            promiseReceivers: promiseReceivers,
            webURL: webURL,
            imageData: imageData,
            text: text
        )
    }

    static func providers(from snapshot: PasteboardSnapshot) async -> [NSItemProvider] {
        if !snapshot.fileURLs.isEmpty {
            return snapshot.fileURLs.compactMap { NSItemProvider(contentsOf: $0) }
        }

        if !snapshot.promiseReceivers.isEmpty {
            var result: [NSItemProvider] = []
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoveDrops-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for receiver in snapshot.promiseReceivers {
                let url: URL? = await withCheckedContinuation { continuation in
                    receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                        continuation.resume(returning: error == nil ? url : nil)
                    }
                }
                if let url, let provider = NSItemProvider(contentsOf: url) { result.append(provider) }
            }
            if !result.isEmpty { return result }
        }

        if let url = snapshot.webURL {
            return [NSItemProvider(object: url as NSURL)]
        }

        if let (data, identifier) = snapshot.imageData {
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: identifier)
            provider.suggestedName = "Image"
            return [provider]
        }

        if let text = snapshot.text {
            return [NSItemProvider(object: text as NSString)]
        }
        return []
    }

    static func providers(from pasteboard: NSPasteboard) async -> [NSItemProvider] {
        await providers(from: snapshot(from: pasteboard))
    }
}

/// The notch window's content view. SwiftUI registers a private drop-destination view inside it that never hands a drag to
/// the shelf's own targets here, so this view takes that registration over and accepts drops onto the open notch itself.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    private let viewModel: BoringViewModel
    /// Re-takes the registration while a mouse button is down (a drag may be starting) and never otherwise: a timer that ran
    /// all day walked the whole view tree twice a second for nothing.
    private var claimTimer: Timer?
    private var mouseMonitor: Any?
    private var lastClaim = Date.distantPast

    init(rootView: Content, viewModel: BoringViewModel) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @MainActor required init(rootView: Content) { fatalError("use init(rootView:viewModel:)") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        claimTimer?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    private static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Switches off SwiftUI's own destination view so this one is the deepest registered view under a drag.
    private func claimRegistration(throttled: Bool = false) {
        let now = Date()
        if throttled, now.timeIntervalSince(lastClaim) < 0.25 { return }
        lastClaim = now
        func visit(_ view: NSView) {
            if NSStringFromClass(type(of: view)).contains("DraggingDestination"), !view.registeredDraggedTypes.isEmpty {
                view.unregisterDraggedTypes()
            }
            view.subviews.forEach(visit)
        }
        visit(self)
    }

    private func buttonChanged(down: Bool) {
        claimTimer?.invalidate()
        claimTimer = nil
        guard down else { return }
        claimRegistration()
        claimTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.claimRegistration() }
        claimTimer?.tolerance = 0.1
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { viewModel.notchState == .open }

    override func mouseDown(with event: NSEvent) {
        if viewModel.notchState == .open, let skyWindow = window as? BoringNotchSkyLightWindow {
            skyWindow.beginKeyInput()
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppDelegate.current?.handleNotchKeyDown(event) == nil {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if AppDelegate.current?.handleNotchKeyDown(event) == nil {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let delegate = AppDelegate.current,
           delegate.isAnyNotchOpen,
           !NoteTextInputController.shared.isEditing,
           !NotchTextInputController.shared.isEditing {
            delegate.closeNotchEverywhere()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimTimer?.invalidate(); claimTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        guard window != nil else { return }
        claimRegistration()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in self?.buttonChanged(down: event.type == .leftMouseDown) }
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        claimRegistration()
    }

    override func layout() {
        super.layout()
        claimRegistration(throttled: true)   // layout runs for every animation frame; once a quarter second is enough
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

    private func setTargets(shelf: Bool, airDrop: Bool, player: Bool = false, photos: Bool = false) {
        if viewModel.dragDetectorTargeting != shelf { viewModel.dragDetectorTargeting = shelf }
        if viewModel.dropZoneTargeting != airDrop { viewModel.dropZoneTargeting = airDrop }
        if PlayerUI.shared.isDropTargeted != player { PlayerUI.shared.isDropTargeted = player }
        if PhotoNotchModel.shared.isDropTargeted != photos { PhotoNotchModel.shared.isDropTargeted = photos }
    }

    private func libraryFileDropRoute(for sender: NSDraggingInfo) -> String? {
        let currentID = BoringViewCoordinator.shared.currentView.id
        guard currentID == PlayerModule.moduleID || currentID == "builtin.photos" else { return nil }
        let hasFiles = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return hasFiles ? currentID : nil
    }

    private func follow(_ sender: NSDraggingInfo) -> NSDragOperation {
        claimRegistration(throttled: true)
        guard takes(sender) else {
            setTargets(shelf: false, airDrop: false)
            return []
        }
        if let route = libraryFileDropRoute(for: sender) {
            setTargets(
                shelf: false,
                airDrop: false,
                player: route == PlayerModule.moduleID,
                photos: route == "builtin.photos"
            )
            return .copy
        }
        guard !AppModules.registry.disabledIDs.contains(NotchViews.shelf.id) else {
            setTargets(shelf: false, airDrop: false)
            return []
        }
        if BoringViewCoordinator.shared.currentView.id != "builtin.shelf" { BoringViewCoordinator.shared.currentView = .shelf }
        let airDrop = overAirDrop(sender)
        setTargets(shelf: !airDrop, airDrop: airDrop)
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        follow(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargets(shelf: false, airDrop: false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { takes(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard takes(sender) else { return false }
        let snapshot = NotchDropHandler.snapshot(from: sender.draggingPasteboard)
        let libraryRoute = libraryFileDropRoute(for: sender)
        let toAirDrop = libraryRoute == nil && overAirDrop(sender)
        if libraryRoute == nil && AppModules.registry.disabledIDs.contains(NotchViews.shelf.id) {
            setTargets(shelf: false, airDrop: false)
            return false
        }
        viewModel.dropEvent = true
        setTargets(shelf: false, airDrop: false)
        Task { @MainActor in
            if libraryRoute == PlayerModule.moduleID {
                guard !snapshot.fileURLs.isEmpty else { return }
                await PlayerLibrary.shared.importURLs(snapshot.fileURLs)
                return
            }
            if libraryRoute == "builtin.photos" {
                guard !snapshot.fileURLs.isEmpty else { return }
                await PhotoLibrary.shared.importURLs(snapshot.fileURLs)
                return
            }
            let providers = await NotchDropHandler.providers(from: snapshot)
            guard !providers.isEmpty else { return }
            if toAirDrop { viewModel.airDropHandler?(providers) } else { ShelfStateViewModel.shared.load(providers) }
        }
        return true
    }
}
