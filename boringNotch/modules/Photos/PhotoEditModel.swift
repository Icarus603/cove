//
//  PhotoEditModel.swift
//  boringNotch
//
//  The maths and the state behind the photo editor: what an edit is (EditParams), how it is applied to a picture
//  (EditPipeline, used for the live preview and, unchanged, for the saved file, so what you see is what you get), how the crop
//  box moves (CropGeometry) and the session that ties them to a photo. Nothing here touches the original file.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// MARK: - What an edit is

struct EditParams: Equatable {
    /// Clockwise quarter turns, 0...3.
    var quarterTurns = 0
    /// Mirrored left to right (after turning).
    var flipped = false
    /// All of these run from -1 to 1 and 0 means "as it is"; sharpness runs 0...1.
    var brightness = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var sharpness = 0.0
    var autoEnhance = false
    /// The crop, as fractions of the turned and flipped picture (origin top left). nil is the whole picture.
    var crop: CGRect?

    var hasGeometryChange: Bool { quarterTurns % 4 != 0 || flipped || crop != nil }
    var hasAdjustmentChange: Bool { brightness != 0 || contrast != 0 || saturation != 0 || warmth != 0 || sharpness != 0 || autoEnhance }
    var isUnchanged: Bool { !hasGeometryChange && !hasAdjustmentChange }

    /// The same edit without any colour adjustment (what "hold to compare" shows).
    var withoutAdjustments: EditParams {
        var copy = self
        copy.brightness = 0; copy.contrast = 0; copy.saturation = 0; copy.warmth = 0; copy.sharpness = 0; copy.autoEnhance = false
        return copy
    }
}

// MARK: - Applying it

enum EditPipeline {
    /// Moves the picture so its lower left corner is at the origin (Core Image keeps track of where things moved).
    static func origin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Turns clockwise by `turns` quarters, then mirrors left to right if asked.
    static func oriented(_ image: CIImage, turns: Int, flipped: Bool) -> CIImage {
        var out = origin(image)
        let steps = ((turns % 4) + 4) % 4
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][steps]
        if orientation != .up { out = origin(out.oriented(orientation)) }
        if flipped { out = origin(out.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        return out
    }

    /// Crops to a rectangle given as fractions of the picture, origin top left.
    static func cropped(_ image: CIImage, unit: CGRect) -> CIImage {
        let width = image.extent.width, height = image.extent.height
        let rect = CGRect(x: unit.minX * width, y: (1 - unit.maxY) * height, width: unit.width * width, height: unit.height * height)
            .integral.intersection(image.extent)
        guard rect.width >= 1, rect.height >= 1 else { return image }
        return origin(image.cropped(to: rect))
    }

    /// Colour adjustments, in a fixed order: auto enhance, warmth, brightness / contrast / saturation, sharpness.
    static func adjusted(_ image: CIImage, _ p: EditParams) -> CIImage {
        guard p.hasAdjustmentChange else { return image }
        var out = image
        if p.autoEnhance {
            for filter in out.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(out, forKey: kCIInputImageKey)
                out = filter.outputImage ?? out
            }
        }
        if p.warmth != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = out
            // The filter maps the "neutral" colour temperature onto the target. A neutral above the target turns the picture warmer
            // (checked on pixels in PhotoChecks.editing: warmth up adds red and removes blue).
            filter.neutral = CIVector(x: 6500 + 1800 * p.warmth, y: 0)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            out = filter.outputImage ?? out
        }
        if p.brightness != 0 || p.contrast != 0 || p.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = out
            filter.brightness = Float(p.brightness * 0.3)
            filter.contrast = Float(1 + p.contrast * 0.5)
            filter.saturation = Float(1 + p.saturation)
            out = filter.outputImage ?? out
        }
        if p.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = out
            filter.sharpness = Float(p.sharpness * 1.5)
            filter.radius = 1.6
            out = filter.outputImage ?? out
        }
        return out
    }

    /// Everything, in order: turn and flip, crop (when asked), colour.
    static func render(_ source: CIImage, _ p: EditParams, applyCrop: Bool) -> CIImage {
        var out = oriented(source, turns: p.quarterTurns, flipped: p.flipped)
        if applyCrop, let crop = p.crop { out = cropped(out, unit: crop) }
        return adjusted(out, p)
    }

    static let context = CIContext(options: [.cacheIntermediates: true])
}

// MARK: - The crop box

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
}

/// Where the crop box can go and how it changes when a handle is dragged. Rectangles are in the pixels of the turned picture,
/// origin top left; `aspect` is width over height when the shape is locked.
enum CropGeometry {
    static let minSide: CGFloat = 24

    /// The largest rectangle of the given shape that fits the picture, centred.
    static func fit(aspect: CGFloat?, in size: CGSize) -> CGRect {
        guard let aspect, aspect > 0 else { return CGRect(origin: .zero, size: size) }
        var width = size.width, height = width / aspect
        if height > size.height { height = size.height; width = height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func drag(_ start: CGRect, handle: CropHandle, by t: CGSize, aspect: CGFloat?, in bounds: CGSize) -> CGRect {
        if handle == .move {
            let x = min(max(start.minX + t.width, 0), bounds.width - start.width)
            let y = min(max(start.minY + t.height, 0), bounds.height - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        guard let aspect, aspect > 0 else { return freeResize(start, handle, t, bounds) }
        return lockedResize(start, handle, t, aspect, bounds)
    }

    private static func freeResize(_ s: CGRect, _ handle: CropHandle, _ t: CGSize, _ bounds: CGSize) -> CGRect {
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle), movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle), movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        if movesLeft { minX = min(max(s.minX + t.width, 0), s.maxX - minSide) }
        if movesRight { maxX = max(min(s.maxX + t.width, bounds.width), s.minX + minSide) }
        if movesTop { minY = min(max(s.minY + t.height, 0), s.maxY - minSide) }
        if movesBottom { maxY = max(min(s.maxY + t.height, bounds.height), s.minY + minSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func lockedResize(_ s: CGRect, _ handle: CropHandle, _ t: CGSize, _ aspect: CGFloat, _ bounds: CGSize) -> CGRect {
        let minWidth = max(minSide, minSide * aspect)
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let right = handle == .topRight || handle == .bottomRight, down = handle == .bottomLeft || handle == .bottomRight
            let anchor = CGPoint(x: right ? s.minX : s.maxX, y: down ? s.minY : s.maxY)
            let corner = CGPoint(x: (right ? s.maxX : s.minX) + t.width, y: (down ? s.maxY : s.minY) + t.height)
            var width = max(abs(corner.x - anchor.x), abs(corner.y - anchor.y) * aspect)
            width = max(width, minWidth)
            let availableWidth = right ? bounds.width - anchor.x : anchor.x
            let availableHeight = down ? bounds.height - anchor.y : anchor.y
            width = min(width, availableWidth, availableHeight * aspect)
            let height = width / aspect
            return CGRect(x: right ? anchor.x : anchor.x - width, y: down ? anchor.y : anchor.y - height, width: width, height: height)
        case .left, .right:
            let centreY = s.midY
            let growsRight = handle == .right
            var width = max(s.width + (growsRight ? t.width : -t.width), minWidth)
            let room = growsRight ? bounds.width - s.minX : s.maxX
            let tall = 2 * min(centreY, bounds.height - centreY) * aspect
            width = min(width, room, tall)
            let height = width / aspect
            return CGRect(x: growsRight ? s.minX : s.maxX - width, y: centreY - height / 2, width: width, height: height)
        case .top, .bottom:
            let centreX = s.midX
            let growsDown = handle == .bottom
            var height = max(s.height + (growsDown ? t.height : -t.height), minWidth / aspect)
            let room = growsDown ? bounds.height - s.minY : s.maxY
            let wide = 2 * min(centreX, bounds.width - centreX) / aspect
            height = min(height, room, wide)
            let width = height * aspect
            return CGRect(x: centreX - width / 2, y: growsDown ? s.minY : s.maxY - height, width: width, height: height)
        case .move:
            return s
        }
    }
}

// MARK: - The session

/// A shape the crop box can be locked to.
enum CropShape: Equatable, Hashable {
    case free, original
    case ratio(Int, Int)

    var title: String {
        switch self {
        case .free: return String(localized: "Free")
        case .original: return String(localized: "Original")
        case .ratio(let w, let h): return "\(w):\(h)"
        }
    }
    /// The shapes offered as buttons. Ratios are stored wide side first; Landscape / Portrait decides which way they lie.
    static let presets: [CropShape] = [.free, .original, .ratio(1, 1), .ratio(5, 4), .ratio(4, 3), .ratio(7, 5),
                                       .ratio(3, 2), .ratio(16, 10), .ratio(16, 9), .ratio(21, 9), .ratio(2, 1), .ratio(3, 1)]

    /// The label for a button: "4:3" lying down, "3:4" standing up.
    func label(landscape: Bool) -> String {
        if case .ratio(let w, let h) = self, !landscape { return "\(h):\(w)" }
        return title
    }
}

@MainActor
final class PhotoEditSession: ObservableObject {
    enum Tab { case crop, adjust }
    enum LoadState { case loading, ready, failed }

    let photo: Photo
    @Published var params = EditParams() { didSet { if params != oldValue { scheduleRender() } } }
    @Published var tab: Tab = .crop { didSet { if tab != oldValue { scheduleRender() } } }
    @Published var comparing = false { didSet { if comparing != oldValue { scheduleRender() } } }
    @Published private(set) var shape: CropShape = .free
    /// Landscape or portrait, if the user chose one. Until then a ratio lies the same way as the picture does.
    @Published private(set) var chosenLandscape: Bool?
    var landscape: Bool { chosenLandscape ?? (turnedSize.width >= turnedSize.height) }
    /// What the canvas draws: the whole picture while cropping, the cropped result while adjusting.
    @Published private(set) var image: NSImage?
    /// The preview picture as it was loaded, before any turning.
    @Published private(set) var sourceSize: CGSize = .zero
    /// The size of the turned and flipped picture (not cropped), in preview pixels. Worked out at once from the turns, never
    /// waiting for a render, so a shape chosen right after a turn already sees the new proportions.
    var turnedSize: CGSize {
        params.quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
    }
    @Published private(set) var loadState: LoadState = .loading
    @Published var isSaving = false

    private var source: CIImage?
    private var renderTask: Task<Void, Never>?
    private var generation = 0

    init(photo: Photo) {
        self.photo = photo
    }

    var hasChanges: Bool { !params.isUnchanged }

    // MARK: Loading

    func load() async {
        guard source == nil else { return }   // already has its picture (a second call, or one handed in by a test)
        let url = photo.url
        let ci: CIImage? = await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 2400]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return CIImage(cgImage: cg)
        }.value
        guard let ci else { loadState = .failed; return }
        source = ci
        sourceSize = ci.extent.size
        loadState = .ready
        scheduleRender()
    }

    /// For tests: gives the session a picture without going through a file.
    func use(_ picture: CIImage) {
        source = picture
        sourceSize = picture.extent.size
        loadState = .ready
        scheduleRender()
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard let source else { return }
        renderTask?.cancel()
        generation += 1
        let token = generation
        let snapshot = (params: comparing ? params.withoutAdjustments : params, crop: tab == .adjust)
        renderTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let out = EditPipeline.render(source, snapshot.params, applyCrop: snapshot.crop)
                return EditPipeline.context.createCGImage(out, from: out.extent)
            }.value
            guard let self, !Task.isCancelled, token == self.generation, let cg = result else { return }
            self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    /// Waits for the render in flight (tests and snapshots).
    func settle() async { await renderTask?.value }

    // MARK: Crop

    /// The locked width over height, or nil for a free box.
    var lockedAspect: CGFloat? {
        switch shape {
        case .free: return nil
        case .original: return turnedSize.height > 0 ? turnedSize.width / turnedSize.height : nil
        case .ratio(let w, let h):
            let value = CGFloat(w) / CGFloat(h)
            return landscape ? value : 1 / value
        }
    }

    /// The crop box in preview pixels (the whole picture when there is no crop).
    var cropRect: CGRect {
        guard turnedSize.width > 0 else { return .zero }
        let unit = params.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGRect(x: unit.minX * turnedSize.width, y: unit.minY * turnedSize.height, width: unit.width * turnedSize.width, height: unit.height * turnedSize.height)
    }

    func setCropRect(_ rect: CGRect) {
        guard turnedSize.width > 0, turnedSize.height > 0 else { return }
        let unit = CGRect(x: rect.minX / turnedSize.width, y: rect.minY / turnedSize.height, width: rect.width / turnedSize.width, height: rect.height / turnedSize.height)
        let whole = unit.width > 0.999 && unit.height > 0.999
        params.crop = whole ? nil : unit
    }

    /// Picks a shape for the box and fits it to the picture.
    func choose(_ new: CropShape) {
        shape = new
        guard let aspect = lockedAspect else { return }
        setCropRect(CropGeometry.fit(aspect: aspect, in: turnedSize))
    }

    /// Lays the chosen ratio down or stands it up (4:3 becomes 3:4) and refits the box.
    func setLandscape(_ value: Bool) {
        chosenLandscape = value
        guard let aspect = lockedAspect else { return }
        setCropRect(CropGeometry.fit(aspect: aspect, in: turnedSize))
    }

    /// Any width:height the user types. 4:5 stands up, 5:4 lies down.
    func chooseCustom(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        chosenLandscape = width >= height
        choose(.ratio(max(width, height), min(width, height)))
    }

    /// Whether Landscape / Portrait means anything for the shape now chosen.
    var canTurnShape: Bool { if case .ratio(let w, let h) = shape { return w != h } else { return false } }

    // MARK: Turning

    func rotate(clockwise: Bool) {
        params.quarterTurns = ((params.quarterTurns + (clockwise ? 1 : 3)) % 4 + 4) % 4
        params.crop = nil
        // The turned picture has new proportions; the locked shape starts again from the whole picture.
        if case .original = shape { shape = .free }
        chosenLandscape = nil
    }

    func flip() {
        params.flipped.toggle()
        params.crop = nil
    }

    func resetAll() {
        params = EditParams()
        shape = .free
        chosenLandscape = nil
    }

    func resetAdjustments() {
        var p = params
        p.brightness = 0; p.contrast = 0; p.saturation = 0; p.warmth = 0; p.sharpness = 0; p.autoEnhance = false
        params = p
    }

    func resetCropAndTurn() {
        var p = params
        p.quarterTurns = 0; p.flipped = false; p.crop = nil
        params = p
        shape = .free
        chosenLandscape = nil
    }

    /// The size the saved picture will have, in pixels.
    var outputSize: CGSize {
        let turnedWidth = params.quarterTurns % 2 == 0 ? CGFloat(photo.width) : CGFloat(photo.height)
        let turnedHeight = params.quarterTurns % 2 == 0 ? CGFloat(photo.height) : CGFloat(photo.width)
        let unit = params.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGSize(width: (turnedWidth * unit.width).rounded(), height: (turnedHeight * unit.height).rounded())
    }
}
