//
//  PhotoEditorView.swift
//  boringNotch
//
//  The photo editor, over the whole window like the viewer it grows out of. The picture is on the left; a fixed panel on the
//  right has two pages, Crop and Adjust; Cancel is always top left and Save as copy always at the bottom of the panel. The
//  original is never changed: a copy is saved next to it and opened.
//

import AppKit
import SwiftUI

struct PhotoEditorView: View {
    @StateObject private var session: PhotoEditSession
    /// Back to the viewer, nothing saved.
    let onClose: () -> Void
    /// A copy was saved: its id and file name.
    let onSaved: (Int64, String) -> Void

    @State private var confirmDiscard = false
    @State private var failure: EditFailure?

    private struct EditFailure: Identifiable {
        let id = UUID()
        let message: String
        let canChoosePlace: Bool
    }

    init(photo: Photo, onClose: @escaping () -> Void, onSaved: @escaping (Int64, String) -> Void) {
        _session = StateObject(wrappedValue: PhotoEditSession(photo: photo))
        self.onClose = onClose; self.onSaved = onSaved
    }

    /// For tests and snapshots, which bring their own session.
    init(session: PhotoEditSession, onClose: @escaping () -> Void = {}, onSaved: @escaping (Int64, String) -> Void = { _, _ in }) {
        _session = StateObject(wrappedValue: session)
        self.onClose = onClose; self.onSaved = onSaved
    }

    var body: some View {
        HStack(spacing: 0) {
            canvasArea
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            EditorPanel(session: session, save: { Task { await save() } })
                .frame(width: 304)
        }
        .background(Color(white: 0.04))
        .environment(\.colorScheme, .dark)
        .tint(Color.white)   // the editor is a dark surface: neutral controls, never a (possibly dark) accent colour
        .task { await session.load() }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("The photo has not been changed. Nothing has been saved.") }
        .alert(item: $failure) { failure in
            if failure.canChoosePlace {
                return Alert(title: Text("Could not save"), message: Text(failure.message),
                             primaryButton: .default(Text("Choose Another Place…")) { Task { await saveElsewhere() } },
                             secondaryButton: .cancel(Text("OK")))
            }
            return Alert(title: Text("Could not save"), message: Text(failure.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Picture

    private var canvasArea: some View {
        ZStack {
            GeometryReader { geo in canvas(geo.size) }
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    cancelButton
                    Spacer()
                    if session.loadState == .ready { sizeLabel }
                }
                .padding(.leading, 86).padding(.trailing, 16).padding(.top, 9)   // clear of the window buttons, on their line
                Spacer()
                if session.loadState == .ready && session.params.hasAdjustmentChange { compareButton.padding(.bottom, 16) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func canvas(_ size: CGSize) -> some View {
        switch session.loadState {
        case .loading:
            ProgressView().controlSize(.regular).frame(width: size.width, height: size.height)
        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(Color.coveWarning)
                Text("This photo could not be opened for editing.").foregroundStyle(.secondary)
            }
            .frame(width: size.width, height: size.height)
        case .ready:
            if let image = session.image {
                let fitted = Self.fit(image.size, in: CGSize(width: max(size.width - 72, 10), height: max(size.height - 104, 10)))
                let frame = CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
                ZStack {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: fitted.width, height: fitted.height)
                        .position(x: frame.midX, y: frame.midY)
                    if session.tab == .crop, abs(image.size.width - session.turnedSize.width) < 1.5 {
                        CropOverlay(session: session, display: frame)
                    }
                }
                .frame(width: size.width, height: size.height)
            } else {
                ProgressView().controlSize(.regular).frame(width: size.width, height: size.height)
            }
        }
    }

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var cancelButton: some View {
        Button {
            if session.hasChanges { confirmDiscard = true } else { onClose() }
        } label: {
            Label("Cancel", systemImage: "xmark").labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .foregroundStyle(Color.white.opacity(0.9))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(Text("Back to the photo"))
    }

    /// "3024 × 2016": how big the saved picture will be.
    private var sizeLabel: some View {
        let size = session.outputSize
        return Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.7))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    /// Press and hold to see the picture without its colour changes.
    private var compareButton: some View {
        Label("Hold to compare", systemImage: "eye")
            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).frame(height: 30)
            .background(Capsule().fill(session.comparing ? Color.white.opacity(0.92) : Color.white.opacity(0.12)))
            .foregroundStyle(session.comparing ? Color.black : Color.white.opacity(0.9))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in session.comparing = true }.onEnded { _ in session.comparing = false })
            .help(Text("Hold to see the original colours"))
    }

    // MARK: Saving

    private func save() async {
        do {
            let saved = try await session.saveCopy()
            onSaved(saved.id, saved.url.lastPathComponent)
        } catch let error as PhotoExporter.ExportError {
            if case .notWritable = error { failure = EditFailure(message: error.localizedDescription, canChoosePlace: true) }
            else { failure = EditFailure(message: error.localizedDescription, canChoosePlace: false) }
        } catch {
            failure = EditFailure(message: error.localizedDescription, canChoosePlace: false)
        }
    }

    private func saveElsewhere() async {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save as copy")
        panel.nameFieldStringValue = PhotoExporter.suggestedURL(for: session.photo.url, in: FileManager.default.temporaryDirectory).lastPathComponent
        panel.allowedContentTypes = [PhotoExporter.outputType(forExtension: session.photo.url.pathExtension).type]
        panel.presentAboveNotch()
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        do {
            let saved = try await session.saveCopy(to: url)
            onSaved(saved.id, saved.url.lastPathComponent)
        } catch {
            failure = EditFailure(message: error.localizedDescription, canChoosePlace: false)
        }
    }
}

private extension NSSavePanel {
    /// `begin()` as something to await.
    @MainActor func begin() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in begin { continuation.resume(returning: $0) } }
    }
}

// MARK: - The crop box over the picture

private struct CropOverlay: View {
    @ObservedObject var session: PhotoEditSession
    /// Where the whole turned picture is drawn, in this view's coordinates.
    let display: CGRect
    @State private var drag: (rect: CGRect, handle: CropHandle)?

    private var scale: CGFloat { display.width / max(session.turnedSize.width, 1) }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: display.minX + r.minX * scale, y: display.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    var body: some View {
        let box = viewRect(session.cropRect)
        ZStack {
            Canvas { context, _ in
                var dim = Path(display)
                dim.addRect(box)
                context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                // thirds
                var grid = Path()
                for i in 1...2 {
                    let f = CGFloat(i) / 3
                    grid.move(to: CGPoint(x: box.minX + box.width * f, y: box.minY)); grid.addLine(to: CGPoint(x: box.minX + box.width * f, y: box.maxY))
                    grid.move(to: CGPoint(x: box.minX, y: box.minY + box.height * f)); grid.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * f))
                }
                context.stroke(grid, with: .color(.white.opacity(0.28)), lineWidth: 0.8)
                context.stroke(Path(box), with: .color(.white.opacity(0.95)), lineWidth: 1.5)
                // corner brackets and edge ticks
                var marks = Path()
                let arm: CGFloat = min(18, box.width / 3, box.height / 3)
                for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                         (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)] {
                    marks.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y)); marks.addLine(to: corner); marks.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                }
                let tick: CGFloat = min(12, box.width / 6, box.height / 6)
                marks.move(to: CGPoint(x: box.midX - tick, y: box.minY)); marks.addLine(to: CGPoint(x: box.midX + tick, y: box.minY))
                marks.move(to: CGPoint(x: box.midX - tick, y: box.maxY)); marks.addLine(to: CGPoint(x: box.midX + tick, y: box.maxY))
                marks.move(to: CGPoint(x: box.minX, y: box.midY - tick)); marks.addLine(to: CGPoint(x: box.minX, y: box.midY + tick))
                marks.move(to: CGPoint(x: box.maxX, y: box.midY - tick)); marks.addLine(to: CGPoint(x: box.maxX, y: box.midY + tick))
                context.stroke(marks, with: .color(.white), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
            .allowsHitTesting(false)

            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            guard let handle = PhotoEditHitTest.handle(at: value.startLocation, box: box) else { return }
                            drag = (session.cropRect, handle)
                        }
                        guard let drag else { return }
                        let t = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                        session.setCropRect(CropGeometry.drag(drag.rect, handle: drag.handle, by: t, aspect: session.lockedAspect, in: session.turnedSize))
                    }
                    .onEnded { _ in drag = nil })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): Self.cursor(for: PhotoEditHitTest.handle(at: point, box: box)).set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
        }
    }

    static func cursor(for handle: CropHandle?) -> NSCursor {
        switch handle {
        case .left?, .right?: return .resizeLeftRight
        case .top?, .bottom?: return .resizeUpDown
        case .topLeft?, .topRight?, .bottomLeft?, .bottomRight?: return .crosshair
        case .move?: return .openHand
        case nil: return .arrow
        }
    }
}

// MARK: - The panel

private struct EditorPanel: View {
    @ObservedObject var session: PhotoEditSession
    let save: () -> Void
    @State private var customWidth = ""
    @State private var customHeight = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if session.tab == .crop { cropPage } else { adjustPage }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background(Color(white: 0.105))
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edit").font(.system(size: 15, weight: .semibold))
            Text(session.photo.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            tab("Crop", symbol: "crop", .crop)
            tab("Adjust", symbol: "slider.horizontal.3", .adjust)
        }
        .padding(.horizontal, 18).padding(.bottom, 4)
    }

    private func tab(_ title: LocalizedStringKey, symbol: String, _ value: PhotoEditSession.Tab) -> some View {
        let selected = session.tab == value
        return Button { session.tab = value } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Crop

    private var cropPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Shape")
                orientationSwitch
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(CropShape.presets, id: \.self) { shape in
                        shapeChip(shape)
                    }
                }
                customRatio
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Rotate and flip")
                HStack(spacing: 6) {
                    transformButton("Rotate left", symbol: "rotate.left") { session.rotate(clockwise: false) }
                    transformButton("Rotate right", symbol: "rotate.right") { session.rotate(clockwise: true) }
                    transformButton("Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.flip() }
                }
            }
            hint("Drag the corners or edges of the picture to crop. Drag inside the box to move it.")
        }
    }

    /// Landscape or Portrait: every ratio below lies down or stands up with it.
    private var orientationSwitch: some View {
        HStack(spacing: 6) {
            orientationButton("Landscape", symbol: "rectangle", landscape: true)
            orientationButton("Portrait", symbol: "rectangle.portrait", landscape: false)
        }
        .opacity(session.canTurnShape ? 1 : 0.4)
        .disabled(!session.canTurnShape)
        .help(Text(session.canTurnShape ? "Lay the shape down or stand it up" : "Choose a ratio first"))
    }

    private func orientationButton(_ title: LocalizedStringKey, symbol: String, landscape: Bool) -> some View {
        let selected = session.canTurnShape && session.landscape == landscape
        return Button { session.setLandscape(landscape) } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shapeChip(_ shape: CropShape) -> some View {
        let selected = session.shape == shape
        return Button { session.choose(shape) } label: {
            Text(shape.label(landscape: session.landscape)).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// "Custom  [ 5 ] : [ 4 ]  Apply": any ratio. A taller number second (4:5) stands up by itself.
    private var customRatio: some View {
        let width = Int(customWidth), height = Int(customHeight)
        let valid = (width ?? 0) > 0 && (height ?? 0) > 0
        return HStack(spacing: 6) {
            Text("Custom").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.75))
            Spacer(minLength: 4)
            ratioField($customWidth, example: "4")
            Text(verbatim: ":").foregroundStyle(Color.white.opacity(0.6))
            ratioField($customHeight, example: "3")
            Button("Apply") { if let width, let height, valid { session.chooseCustom(width: width, height: height) } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(valid ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
                .foregroundStyle(valid ? Color.black : Color.white.opacity(0.35))
                .disabled(!valid)
        }
        .padding(.top, 4)
    }

    private func ratioField(_ text: Binding<String>, example: String) -> some View {
        TextField("", text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.filter(\.isNumber).prefix(3)) }))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, design: .monospaced))
            .overlay { if text.wrappedValue.isEmpty { Text(verbatim: example).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.white.opacity(0.28)).allowsHitTesting(false) } }
            .frame(width: 40, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .onSubmit { if let w = Int(customWidth), let h = Int(customHeight), w > 0, h > 0 { session.chooseCustom(width: w, height: h) } }
    }

    private func transformButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                Text(title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
            .foregroundStyle(Color.white.opacity(0.9))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Adjust

    private var adjustPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { session.params.autoEnhance.toggle() } label: {
                Label("Auto enhance", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(Capsule().fill(session.params.autoEnhance ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
                    .foregroundStyle(session.params.autoEnhance ? Color.black : Color.white.opacity(0.85))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Light")
                EditSlider(title: "Brightness", value: binding(\.brightness))
                EditSlider(title: "Contrast", value: binding(\.contrast))
            }
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Color")
                EditSlider(title: "Saturation", value: binding(\.saturation))
                EditSlider(title: "Warmth", value: binding(\.warmth))
            }
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Detail")
                EditSlider(title: "Sharpness", value: binding(\.sharpness), range: 0...1)
            }
            hint("Click a value to put it back to zero.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<EditParams, Double>) -> Binding<Double> {
        Binding(get: { session.params[keyPath: keyPath] }, set: { session.params[keyPath: keyPath] = $0 })
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Button("Reset all") { session.resetAll() }
                .buttonStyle(.plain).font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(session.hasChanges ? 0.75 : 0.3))
                .disabled(!session.hasChanges)
            Button(action: save) {
                HStack(spacing: 6) {
                    if session.isSaving { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.down") }
                    Text("Save as copy")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(Capsule().fill(session.hasChanges ? Color.white.opacity(0.94) : Color.white.opacity(0.12)))
                .foregroundStyle(session.hasChanges ? Color.black : Color.white.opacity(0.35))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!session.hasChanges || session.isSaving)
            .help(Text(session.hasChanges ? "Save an edited copy next to the original" : "Make a change first"))
            Text("A copy is saved next to the original. The original is never changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

// MARK: - A slider with its name and value

private struct EditSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.9))
                Spacer()
                Button { value = 0 } label: {
                    Text(valueText).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(value == 0 ? Color.white.opacity(0.4) : Color.white)
                        .fontWeight(value == 0 ? .regular : .semibold)
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .disabled(value == 0)
                .help(Text("Put it back to zero"))
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }

    private var valueText: String { String(Int((value * 100).rounded())) }
}

/// Which part of the crop box a point is on, shared by the overlay and the checks.
enum PhotoEditHitTest {
    /// Which part of the box a point is on: a corner or an edge within reach, else inside to move it, else nothing.
    static func handle(at p: CGPoint, box: CGRect) -> CropHandle? {
        let reach: CGFloat = 18
        let nearLeft = abs(p.x - box.minX) < reach, nearRight = abs(p.x - box.maxX) < reach
        let nearTop = abs(p.y - box.minY) < reach, nearBottom = abs(p.y - box.maxY) < reach
        let withinX = p.x > box.minX - reach && p.x < box.maxX + reach, withinY = p.y > box.minY - reach && p.y < box.maxY + reach
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        if box.contains(p) { return .move }
        return nil
    }
}
