import AppKit

final class CanvasView: NSView, NSTextViewDelegate {
    enum Tool: Hashable {
        case brush, eraser, paintBucket, gradient, rectangleSelect, ellipseSelect, lassoSelect, magicWand, moveSelectedPixels, moveSelection
        case pencil, colorPicker, cloneStamp, recolor, text, lineCurve, shapes, zoom, pan

        var selectionName: String? {
            switch self {
            case .rectangleSelect: return "Rectangle Select"
            case .ellipseSelect: return "Ellipse Select"
            case .lassoSelect: return "Lasso Select"
            case .magicWand: return "Magic Wand"
            default: return nil
            }
        }
        var drawsSelection: Bool { selectionName != nil }
        var usesFlood: Bool { self == .magicWand || self == .paintBucket }
        var transformsSelection: Bool { self == .moveSelectedPixels || self == .moveSelection }
        var usesBrushTip: Bool { self == .brush || self == .eraser || self == .cloneStamp || self == .recolor }
        var usesRasterDrawing: Bool { self == .pencil || usesBrushTip }
        var usesVectorDrawing: Bool { self == .lineCurve || self == .shapes || self == .text }
        var usesBrushSize: Bool { usesBrushTip || self == .lineCurve || self == .shapes }
    }

    private struct SelectionDrag {
        let anchor: CGPoint
        var end: CGPoint
        let before: SelectionOutline?
        let mode: SelectionOutline.Mode
        let lassoPath: CGMutablePath?
        let rightButton: Bool
    }

    private struct FloodEdit {
        enum Operation {
            case select(mode: SelectionOutline.Mode, before: SelectionOutline?)
            case fill(layer: PaintLayer, mask: Data?)
        }

        let source: PaintLayer
        var x: Int
        var y: Int
        let flood: FloodSettings.Flood
        var secondary = false
        let operation: Operation
    }

    private struct GradientEdit {
        let layer: PaintLayer
        let selection: SelectionOutline?
        var line: LinearGradient
        var reversed: Bool
        var preview: PaintLayer?
        var needsRender = false
    }

    private struct GradientDrag {
        let startsLine: Bool
        let movesStart: Bool
        let rightButton: Bool
        let offset: CGPoint
    }

    struct MoveSession {
        let layerIndex: Int
        let pixels: SelectedPixelsTransform?
        let outline: SelectionOutline
        let initialGeometry: MoveGeometry
        var geometry: MoveGeometry
        var sampling: MoveResampler.Mode = .bicubic
        var copy = false
        var actionName = "Move Selected Pixels"
        var recorded = false

        var isPaste: Bool { pixels?.isPaste == true }
        var changed: Bool {
            isPaste || geometry.rect != initialGeometry.rect || geometry.angle != initialGeometry.angle ||
                geometry.flipX || geometry.flipY
        }

        var transform: CGAffineTransform {
            let source = initialGeometry.rect
            if geometry.angle == initialGeometry.angle && geometry.rect.size == source.size &&
                !geometry.flipX && !geometry.flipY {
                return CGAffineTransform(translationX: geometry.rect.minX - source.minX,
                                         y: geometry.rect.minY - source.minY)
            }
            return CGAffineTransform(translationX: geometry.rect.midX, y: geometry.rect.midY)
                .rotated(by: geometry.angle)
                .scaledBy(x: (geometry.flipX ? -1 : 1) * geometry.rect.width / source.width,
                          y: (geometry.flipY ? -1 : 1) * geometry.rect.height / source.height)
                .rotated(by: -initialGeometry.angle)
                .translatedBy(x: -source.midX, y: -source.midY)
        }

        var hasPixelPreview: Bool { pixels != nil && changed }

        func renderedLayer() -> PaintLayer? {
            guard hasPixelPreview else { return nil }
            return pixels?.transformed(by: transform, copy: copy, sampling: sampling)
        }

        var transformedOutline: SelectionOutline? { outline.transformed(by: transform) }
    }

    private struct MoveDrag {
        let before: MoveSession?
        let geometry: MoveGeometry
        let anchor: CGPoint
        let handle: TransformHandle
        let rightButton: Bool
        var lastPoint: CGPoint
        var resizeGeometry: MoveGeometry
        var resizeAnchor: CGPoint
        var proportional: Bool
    }

    private enum TransformHandle {
        case move
        case resize(ResizeHandle)
        case rotate
        case pivot
    }

    private enum HandleEdge: CGFloat, CaseIterable {
        case minimum = 0, middle = 0.5, maximum = 1

        var direction: CGFloat { rawValue * 2 - 1 }
    }

    private struct ResizeHandle {
        let horizontal: HandleEdge
        let vertical: HandleEdge

        static let all: [ResizeHandle] = HandleEdge.allCases.flatMap { vertical in
            HandleEdge.allCases.compactMap { horizontal in
                horizontal == .middle && vertical == .middle ? nil : ResizeHandle(horizontal: horizontal, vertical: vertical)
            }
        }

        func resized(_ geometry: MoveGeometry, delta: CGPoint, proportional: Bool, centered: Bool) -> MoveGeometry {
            let rect = geometry.rect
            let local = delta.rotated(by: -geometry.angle)
            let x = horizontal.direction, y = vertical.direction
            let multiplier: CGFloat = centered ? 2 : 1
            var width = rect.width + (x * local.x * multiplier).rounded()
            var height = rect.height + (y * local.y * multiplier).rounded()
            guard width != rect.width || height != rect.height else { return geometry }
            if proportional {
                let sx = width / rect.width, sy = height / rect.height
                let dominant = abs(sx - 1) >= abs(sy - 1) ? sx : sy
                let scale = max(abs(dominant), 1 / min(rect.width, rect.height))
                width = rect.width * scale * (width < 0 ? -1 : 1)
                height = rect.height * scale * (height < 0 ? -1 : 1)
            }
            if abs(width) < 1 { width = 1 }
            if abs(height) < 1 { height = 1 }

            let shift = CGPoint(x: x * (width - rect.width) / 2, y: y * (height - rect.height) / 2)
            let center = centered ? rect.center : rect.center + shift.rotated(by: geometry.angle)
            let pivot = (geometry.pivot - rect.center).rotated(by: -geometry.angle)
            let scaledPivot = CGPoint(x: pivot.x * width / rect.width, y: pivot.y * height / rect.height)
            return MoveGeometry(rect: CGRect(x: center.x - abs(width) / 2, y: center.y - abs(height) / 2,
                                             width: abs(width), height: abs(height)),
                                pivot: center + scaledPivot.rotated(by: geometry.angle), angle: geometry.angle,
                                flipX: geometry.flipX != (width < 0), flipY: geometry.flipY != (height < 0))
        }

        func frame(in marquee: CGRect) -> CGRect {
            // Spread handles out on small selections so the center remains draggable.
            let width = max(marquee.width, 28), height = max(marquee.height, 28)
            let x = marquee.midX + (horizontal.rawValue - 0.5) * width
            let y = marquee.midY + (vertical.rawValue - 0.5) * height
            return CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
        }
    }

    static let zoomSteps: [CGFloat] = [
        1, 2, 3, 5, 6, 8, 12.5, 16, 25, 33, 50, 66, 75, 100, 150, 200, 300, 400, 500,
        600, 800, 1000, 1200, 1400, 1600, 2000, 2400, 2800, 3200, 4000, 4800, 5600, 6400,
        8000, 10000
    ]
    private static let rotationCursor: NSCursor = {
        let size = NSSize(width: 20, height: 20)
        let center = CGPoint(x: 10, y: 10)
        let image = NSImage(size: size, flipped: false) { _ in
            let arrow = NSBezierPath()
            arrow.appendArc(withCenter: center, radius: 6, startAngle: -50, endAngle: 0, clockwise: true)
            arrow.move(to: CGPoint(x: 12.5, y: 13.5))
            arrow.line(to: CGPoint(x: 16, y: 10))
            arrow.line(to: CGPoint(x: 17.5, y: 14.5))
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round

            // The white outline stays visible over dark pixels and the black stroke over light ones.
            NSColor.white.setStroke()
            arrow.lineWidth = 4
            arrow.stroke()
            NSColor.black.setStroke()
            arrow.lineWidth = 2
            arrow.stroke()
            return true
        }
        image.accessibilityDescription = "Rotate Selection"
        return NSCursor(image: image, hotSpot: center)
    }()
    private static let floodHandleIcon = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                                 accessibilityDescription: "Move flood tool click point")

    private weak var document: PaintDocument?
    var tool = Tool.brush {
        willSet {
            if newValue != tool {
                cancelSelectionDrag()
                rasterDrawing = nil
                cloneCursor = nil
                composite = nil
                finishSelection()
                if newValue == .colorPicker { previousTool = tool }
            }
        }
        didSet {
            if tool == .moveSelectedPixels && usesMetalMovePreview { MetalMovePreview.prepare() }
            updateBrushCursor()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            selectionDidChange?()
        }
    }
    private(set) var zoomPercent: CGFloat?
    private(set) var displayedZoomPercent: CGFloat = 0
    var zoomDidChange: (() -> Void)?
    var brushColor = NSColor.black {
        didSet {
            if tool == .paintBucket { updateFloodEdit() }
            else if tool == .gradient { invalidateGradientPreview() }
            updateDrawingPreview()
        }
    }
    var secondaryColor = NSColor.white {
        didSet {
            if tool == .gradient { invalidateGradientPreview() }
            if tool == .paintBucket { updateFloodEdit() }
            updateDrawingPreview()
        }
    }
    static let brushSizeRange: ClosedRange<CGFloat> = 0.1...4096
    var brushSize: CGFloat = 12 {
        didSet {
            updateBrushCursor()
            updateDrawingPreview()
            brushSizeDidChange?()
        }
    }
    var brushSizeDidChange: (() -> Void)?
    private var perToolBrushOptions: [Tool: BrushOptions] = [:]
    var brushOptions: BrushOptions {
        get { perToolBrushOptions[tool] ?? BrushOptions() }
        set { perToolBrushOptions[tool] = newValue }
    }
    var brushAntialiased: Bool {
        get { brushOptions.antialiased }
        set { brushOptions.antialiased = newValue }
    }
    private(set) var hasSeenTablet = false
    var drawingStyle = DrawingStyle() { didSet { updateDrawingPreview() } }
    var gradientOptions = GradientOptions() { didSet { invalidateGradientPreview() } }
    var pickerSampling: FloodSettings.Sampling = .layer
    var pickerSampleSize = 1
    enum PickerAfter: String, CaseIterable {
        case stay = "Keep Color Picker", previous = "Previous Tool", pencil = "Pencil"
    }
    var pickerAfter = PickerAfter.stay
    var recolorTolerance = 50
    var colorDidPick: ((NSColor, Bool) -> Void)?
    var handleColorShortcut: ((String) -> Bool)?
    var showsPixelGrid = false { didSet { needsDisplay = true } }
    var canvasImageRect: CGRect { imageRect }
    var pointerDidMove: ((CGPoint?) -> Void)?
    var selectionDidChange: (() -> Void)?
    var selectTool: ((Tool) -> Void)?
    var layerPreview: LayerStack? {
        didSet {
            composite = nil
            moveTilePreview = nil
            metalSheetPreview = nil
            needsDisplay = true
        }
    }
    private var composite: CanvasComposite?
    var cachedCommittedComposite: CGImage? {
        guard layerPreview == nil, rasterDrawing == nil, gradientEdit == nil,
              fillPreview == nil, drawingDraft == nil else { return nil }
        return composite?.renderedImage
    }

    private(set) var selectionOutline: SelectionOutline?
    var selectionMode: SelectionOutline.Mode = .replace
    var rectangleSelection = RectangleSelection()
    var imageResolution: ImageResolution { document?.stack?.resolution ?? .standard }
    var floodSettings = FloodSettings()
    private var floodEdit: FloodEdit?
    private var fillPreview: PaintLayer?
    private var floodDrag: (anchor: CGPoint, x: Int, y: Int)?
    private var gradientEdit: GradientEdit?
    private var gradientDrag: GradientDrag?
    private var previousTool = Tool.brush
    private var textEditor: CanvasTextInput?
    private var textLayout: TextLayout?
    private var textBlinkTimer: Timer?
    private var textCaretVisible = true

    var focusedTextInput: CanvasTextInput? {
        guard let textEditor, let responder = window?.firstResponder,
              responder === textEditor || responder === self else { return nil }
        return textEditor
    }

    var hasPendingText: Bool { textEditor != nil }

    func focusTextInput() {
        if let textEditor { window?.makeFirstResponder(textEditor) }
    }

    private var drawingDraft: (geometry: VectorDrawing, secondary: Bool, preview: PaintLayer?)?
    private enum DrawingDragMode { case create, handle(Int), move, rotate }
    private var drawingDrag: (anchor: CGPoint, mode: DrawingDragMode, initial: VectorDrawing)?
    private var rasterDrawing: RasterDrawing? {
        didSet {
            if oldValue !== rasterDrawing {
                metalStroke = nil
                metalStrokeDirty = .null
                metalStrokeRevision &+= 1
            }
        }
    }
    private var drawingWithSecondaryButton = false
    private var lastTabletPressure: CGFloat?
    private var cloneSource: (point: CGPoint, layer: Int)?
    private var cloneOffset: CGPoint?
    private var cloneCursor: CGPoint?
    var selection: CGRect { selectionOutline?.bounds.integral ?? .zero }
    private var selectionDrag: SelectionDrag?

    private(set) var move: MoveSession?
    private var moveDrag: MoveDrag?
    private var moveTilePreview: MoveTilePreview?
    var usesMetalMovePreview = true
    var usesMetalViewportPreview = true
    var metalMovePreviewDraws: Int { moveTilePreview?.metalDraws ?? 0 }
    private var metalCanvas: MetalCanvasSurface?
    private var metalOverlay: MetalCanvasOverlay?
    private var metalStack: (revision: Int, renderer: MetalMovePreview?)?
    private var metalSheetPreview: MetalMovePreview?
    private var metalActivePreview: (image: CGImage, pixels: MetalMovePreview.ActivePixels)?
    private var metalStroke: (renderer: MetalMovePreview, pixels: MetalMovePreview.ActivePixels)?
    private var metalStrokeDirty = CGRect.null
    private var metalStrokeRevision = 0
    private var metalPresentationFailed = false
    private var fallbackRepaintScheduled = false
    var cachedMetalComposite: MetalMovePreview? {
        guard layerPreview == nil, metalStack?.revision == document?.stackRevision else { return nil }
        return metalStack?.renderer
    }
    private var cursorTracking: NSTrackingArea?
    private var brushCursor: CGRect? {
        didSet {
            guard brushCursor != oldValue else { return }
            for ring in [oldValue, brushCursor].compactMap({ $0 }) {
                // Include the outline and antialiasing in the dirty region.
                let dirtyRect = ring.insetBy(dx: -2, dy: -2).intersection(visibleRect)
                if !dirtyRect.isEmpty { setNeedsDisplay(dirtyRect) }
            }
        }
    }
    private var panDrag: (location: CGPoint, button: Int)?
    private var holdingSpace = false
    private var zoomScrollDistance: CGFloat = 0
    private var zoomingScrollGesture = false

    init(document: PaintDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityLabel("Canvas")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    private let margin: CGFloat = 24
    private var backingScale: CGFloat { window?.backingScaleFactor ?? 1 }
    private var imageRect = CGRect.zero
    private var viewportSize = CGSize.zero

    func setZoom(_ percent: CGFloat?) {
        zoomPercent = percent
        updateViewport(recenter: true)
    }

    func updateViewport(anchor: CGPoint? = nil, recenter: Bool = false) {
        guard let scrollView = enclosingScrollView, let image = document?.image else { return }
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let clip = scrollView.contentView
        let scale = zoomPercent.map { $0 / (100 * backingScale) }
            ?? min(max(1, viewport.width - 2 * margin) / CGFloat(image.width),
                   max(1, viewport.height - 2 * margin) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        // A large image can bring either edge to center. A small image can go halfway offscreen.
        let paddingX = max(viewport.width / 2, viewport.width - width / 2)
        let paddingY = max(viewport.height / 2, viewport.height - height / 2)
        let size = CGSize(width: width + 2 * paddingX, height: height + 2 * paddingY)
        let rect = CGRect(x: (paddingX * backingScale).rounded() / backingScale,
                          y: (paddingY * backingScale).rounded() / backingScale,
                          width: width, height: height)

        if rect != imageRect || size != frame.size || recenter || viewport != viewportSize {
            let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            let offset = anchor ?? center
            let oldOffset = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let oldOrigin = clip.bounds.origin
            var fraction = CGPoint(x: 0.5, y: 0.5)
            let refitting = zoomPercent == nil && viewport != viewportSize
            if !recenter && !refitting && !imageRect.isEmpty {
                fraction = CGPoint(x: (oldOrigin.x + oldOffset.x - imageRect.minX) / imageRect.width,
                                   y: (oldOrigin.y + oldOffset.y - imageRect.minY) / imageRect.height)
            }

            viewportSize = viewport
            imageRect = rect
            if frame.size != size { setFrameSize(size) }
            scroll(to: CGPoint(x: rect.minX + fraction.x * rect.width - offset.x,
                               y: rect.minY + fraction.y * rect.height - offset.y), in: scrollView)
            window?.invalidateCursorRects(for: self)
        }
        displayedZoomPercent = zoomPercent ?? scale * backingScale * 100
        updateBrushCursor()
        zoomDidChange?()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateViewport()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            if newWindow == nil {
                // A tab can leave the workspace window without losing its editable preview.
                resetWindowInteraction()
                metalCanvas?.clearFrame()
                metalOverlay?.isHidden = true
                metalStack = nil
                metalSheetPreview = nil
                metalActivePreview = nil
                moveTilePreview = nil
            } else if newWindow !== window {
                cancelEditingGesture()
            }
        }
        if let clip = enclosingScrollView?.contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(refreshBrushCursor(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let clip = enclosingScrollView?.contentView {
            MetalMovePreview.prepare()
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(refreshBrushCursor(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
        updateBrushCursor()
    }

    @objc private func refreshBrushCursor(_ notification: Notification) {
        updateBrushCursor()
        if metalCanvas?.isHidden == false { needsDisplay = true }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        resetWindowInteraction()
    }

    private func resetWindowInteraction() {
        completeMoveDrag()
        cancelSelectionDrag()
        floodDrag = nil
        gradientDrag = nil
        drawingDrag = nil
        rasterDrawing = nil
        cloneCursor = nil
        brushCursor = nil
        composite = nil
        needsDisplay = true
        panDrag = nil
        holdingSpace = false
        window?.invalidateCursorRects(for: self)
    }

    private func scroll(to origin: CGPoint, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let proposedBounds = CGRect(origin: origin, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposedBounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func resetCursorRects() {
        if panDrag != nil {
            addCursorRect(visibleRect, cursor: .closedHand)
        } else if tool == .pan || holdingSpace {
            addCursorRect(visibleRect, cursor: .openHand)
        } else if !tool.transformsSelection && !imageRect.isEmpty {
            addCursorRect(imageRect, cursor: tool == .text ? .iBeam : .crosshair)
            if tool == .text, let width = document?.image?.width, let handle = textHandleFrame(imageWidth: width) {
                addCursorRect(handle, cursor: .openHand)
            }
        }
    }

    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        cursorTracking = tracking
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        if updatePanCursor() { return }
        if tool.transformsSelection { updateMoveCursor(at: convert(event.locationInWindow, from: nil)) }
        else if tool.usesFlood { updateFloodCursor(at: convert(event.locationInWindow, from: nil)) }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        updateBrushCursor(at: event.locationInWindow)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateBrushCursor(at: event.locationInWindow)
        let location = convert(event.locationInWindow, from: nil)
        if imageRect.contains(location), let height = document?.image?.height {
            let point = imagePoint(location)
            pointerDidMove?(CGPoint(x: Int(floor(point.x)), y: height - 1 - Int(floor(point.y))))
        } else {
            pointerDidMove?(nil)
        }
        if updatePanCursor() { return }
        if tool.transformsSelection { updateMoveCursor(at: location) }
        else if tool.usesFlood { updateFloodCursor(at: location) }
        else { super.mouseMoved(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        brushCursor = nil
        pointerDidMove?(nil)
        super.mouseExited(with: event)
    }

    private func updateBrushCursor(at locationInWindow: CGPoint? = nil) {
        guard tool.usesBrushTip, !holdingSpace, panDrag == nil,
              let window, window.isKeyWindow, let image = document?.image else {
            brushCursor = nil
            return
        }
        let center = convert(locationInWindow ?? window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(center), imageRect.contains(center) else {
            brushCursor = nil
            return
        }
        let diameter = brushSize * imageRect.width / CGFloat(image.width)
        brushCursor = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                             width: diameter, height: diameter)
    }

    private func updateFloodCursor(at location: CGPoint) {
        if floodDrag != nil || panDrag != nil { NSCursor.closedHand.set() }
        else if floodHandle?.frame.contains(location) == true { NSCursor.openHand.set() }
        else { (imageRect.contains(location) ? NSCursor.crosshair : .arrow).set() }
    }

    private func updateMoveCursor(at location: CGPoint) {
        guard let layer = document?.stack?.activeLayer, !imageRect.isEmpty,
              tool == .moveSelection ? selectionOutline != nil : layer.isVisible else {
            NSCursor.arrow.set()
            return
        }
        if panDrag != nil {
            NSCursor.closedHand.set()
            return
        }
        switch moveDrag?.handle ?? transformHandle(at: location, layer: layer) {
        case .rotate: Self.rotationCursor.set()
        case .move, .resize, .pivot: (moveDrag == nil ? NSCursor.openHand : .closedHand).set()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let zooming = event.modifierFlags.contains(.command)
        if !event.momentumPhase.isEmpty {
            if !zooming && !zoomingScrollGesture { super.scrollWheel(with: event) }
            return
        }
        if event.phase == .began || event.phase == .mayBegin || !event.hasPreciseScrollingDeltas {
            zoomingScrollGesture = false
            zoomScrollDistance = 0
        }
        guard zooming else {
            zoomScrollDistance = 0
            super.scrollWheel(with: event)
            return
        }
        zoomingScrollGesture = true
        guard !imageRect.isEmpty, selectionDrag == nil, moveDrag == nil, floodDrag == nil,
              gradientDrag == nil, drawingDrag == nil, rasterDrawing == nil, panDrag == nil else { return }

        let steps: Int
        if event.hasPreciseScrollingDeltas {
            let pointsPerStep: CGFloat = 24
            zoomScrollDistance += event.scrollingDeltaY
            steps = Int(zoomScrollDistance / pointsPerStep)
            zoomScrollDistance -= CGFloat(steps) * pointsPerStep
        } else {
            steps = Int(event.scrollingDeltaY.rounded(.awayFromZero))
        }
        stepZoom(steps, at: event.locationInWindow)
    }

    private func stepZoom(_ steps: Int, at locationInWindow: CGPoint) {
        guard steps != 0, let scrollView = enclosingScrollView else { return }
        let levels = Self.zoomSteps
        let index: Int
        if steps > 0 {
            guard let next = levels.firstIndex(where: { $0 > displayedZoomPercent + 0.0001 }) else { return }
            index = min(next + steps - 1, levels.count - 1)
        } else {
            guard let next = levels.lastIndex(where: { $0 < displayedZoomPercent - 0.0001 }) else { return }
            index = max(next + steps + 1, 0)
        }
        let percent = levels[index]

        let pointer = convert(locationInWindow, from: nil)
        let origin = scrollView.contentView.bounds.origin
        let anchor = imageRect.contains(pointer) ? CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y) : nil
        zoomPercent = percent
        updateViewport(anchor: anchor)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        beginPan(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        dragPan(with: event)
    }

    private func beginPan(with event: NSEvent) {
        guard !imageRect.isEmpty, panDrag == nil, selectionDrag == nil, moveDrag == nil,
              floodDrag == nil, gradientDrag == nil, drawingDrag == nil, rasterDrawing == nil else { return }
        if event.buttonNumber != 2 { window?.makeFirstResponder(self) }
        panDrag = (event.locationInWindow, event.buttonNumber)
        brushCursor = nil
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
    }

    private func dragPan(with event: NSEvent) {
        guard let drag = panDrag, drag.button == event.buttonNumber, let scrollView = enclosingScrollView else { return }
        let lastLocation = drag.location
        let last = convert(lastLocation, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        let origin = scrollView.contentView.bounds.origin
        panDrag?.location = event.locationInWindow
        scroll(to: CGPoint(x: origin.x + last.x - current.x, y: origin.y + last.y - current.y), in: scrollView)
        NSCursor.closedHand.set()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        finishPan(with: event)
    }

    private func finishPan(with event: NSEvent) {
        guard panDrag?.button == event.buttonNumber else { return }
        dragPan(with: event)
        panDrag = nil
        updateBrushCursor(at: event.locationInWindow)
        defer { window?.invalidateCursorRects(for: self) }
        if updatePanCursor() { return }
        let location = convert(event.locationInWindow, from: nil)
        if tool.transformsSelection && visibleRect.contains(location) {
            updateMoveCursor(at: location)
        } else if tool.usesFlood && visibleRect.contains(location) {
            updateFloodCursor(at: location)
        } else if visibleRect.contains(location) && imageRect.contains(location) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func updatePanCursor() -> Bool {
        if panDrag != nil { NSCursor.closedHand.set() }
        else if tool == .pan || holdingSpace { NSCursor.openHand.set() }
        else { return false }
        return true
    }

    private func imagePoint(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        let scale = CGFloat(document?.image?.width ?? 0) / rect.width
        return CGPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale)
    }

    private func pixelEdge(at location: CGPoint, in image: CGImage) -> CGPoint {
        let point = imagePoint(location)
        return CGPoint(x: min(max(point.x.rounded(), 0), CGFloat(image.width)),
                       y: min(max(point.y.rounded(), 0), CGFloat(image.height)))
    }

    private func cancelSelectionDrag() {
        guard let drag = selectionDrag else { return }
        selectionDrag = nil
        setSelection(drag.before)
    }

    private func selectionMode(at modifiers: NSEvent.ModifierFlags, rightButton: Bool) -> SelectionOutline.Mode {
        if modifiers.contains(.control) { return rightButton ? .xor : .add }
        if modifiers.contains(.option) { return rightButton ? .intersect : .subtract }
        return selectionMode
    }

    private func beginSelectionDrag(at location: CGPoint, in image: CGImage,
                                    modifiers: NSEvent.ModifierFlags, rightButton: Bool) {
        guard selectionDrag == nil else { return }
        let anchor = pixelEdge(at: location, in: image)
        let path = tool == .lassoSelect ? CGMutablePath() : nil
        path?.move(to: anchor)
        selectionDrag = SelectionDrag(anchor: anchor, end: anchor, before: selectionOutline,
                                      mode: selectionMode(at: modifiers, rightButton: rightButton),
                                      lassoPath: path, rightButton: rightButton)
        updateSelectionDrag(in: image, modifiers: modifiers)
    }

    private func dragSelection(with event: NSEvent, rightButton: Bool) -> Bool {
        guard var drag = selectionDrag, let image = document?.image else { return false }
        guard drag.rightButton == rightButton else { return true }
        let location = convert(event.locationInWindow, from: nil)
        let point = imagePoint(location)
        let end = drag.lassoPath == nil ? pixelEdge(at: location, in: image)
            : CGPoint(x: point.x.rounded(), y: point.y.rounded())
        if end != drag.end {
            drag.lassoPath?.addLine(to: end)
            drag.end = end
            selectionDrag = drag
        }
        updateSelectionDrag(in: image, modifiers: event.modifierFlags)
        return true
    }

    private func finishSelectionDrag(with event: NSEvent, rightButton: Bool) -> Bool {
        guard let drag = selectionDrag, let name = tool.selectionName else { return false }
        guard drag.rightButton == rightButton else { return true }
        _ = dragSelection(with: event, rightButton: rightButton)
        let outline = selectionOutline
        cancelSelectionDrag()
        let actionName = drag.mode == .replace ? (outline == nil ? "Deselect" : name) : "\(name) (\(drag.mode.rawValue))"
        document?.commitSelection(outline, actionName: actionName)
        return true
    }

    private func updateSelectionDrag(in image: CGImage, modifiers: NSEvent.ModifierFlags) {
        guard let drag = selectionDrag else { return }
        let outline: SelectionOutline?
        if let path = drag.lassoPath?.mutableCopy() {
            path.closeSubpath()
            outline = SelectionOutline(path: path.normalized(using: .evenOdd))
        } else {
            outline = shapeSelection(from: drag.anchor, to: drag.end, in: image, modifiers: modifiers)
        }
        let clipped = outline?.clipped(to: canvasBounds(for: image))
        setSelection(drag.mode.applying(clipped, to: drag.before))
    }

    private func shapeSelection(from anchor: CGPoint, to end: CGPoint, in image: CGImage,
                                modifiers: NSEvent.ModifierFlags) -> SelectionOutline? {
        if tool == .rectangleSelect {
            return SelectionOutline(rect: rectangleSelection.bounds(from: anchor, to: end, canvas: canvasBounds(for: image),
                                                                     resolution: imageResolution, square: modifiers.contains(.shift)))
        }
        let rect = CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                          width: abs(anchor.x - end.x), height: abs(anchor.y - end.y))
        var bounds = rect
        if modifiers.contains(.shift) {
            // The drag endpoints define the diameter, in any direction.
            let diameter = hypot(rect.width, rect.height)
            bounds = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                            width: diameter, height: diameter)
        }
        return SelectionOutline(path: CGPath(ellipseIn: bounds, transform: nil))
    }

    func setSelection(_ outline: SelectionOutline?) {
        guard selectionOutline != outline else { return }
        selectionOutline = outline
        if textEditor != nil { updateDrawingPreview() }
        needsDisplay = true
        selectionDidChange?()
    }

    private func canvasBounds(for image: CGImage) -> CGRect {
        CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    var copyableOutline: SelectionOutline? {
        guard let image = document?.image else { return nil }
        if let move, move.changed { return move.transformedOutline?.clipped(to: canvasBounds(for: image)) }
        return selectionOutline
    }

    private var pixelPreview: PaintLayer? {
        nonRasterPixelPreview ?? rasterDrawing?.preview
    }

    private var nonRasterPixelPreview: PaintLayer? {
        renderGradientPreviewIfNeeded()
        return fillPreview ?? gradientEdit?.preview ?? drawingDraft?.preview
    }
    var copyableLayer: PaintLayer? {
        if let move, move.hasPixelPreview { return move.renderedLayer() }
        return pixelPreview ?? document?.stack?.activeLayer
    }
    var canCopyPixels: Bool {
        document?.stack != nil && (copyableOutline != nil || (selectionOutline == nil && move?.isPaste != true))
    }

    func pastePixels(_ pastedImage: CGImage, sourceOrigin: CGPoint? = nil, replacingStack replacement: LayerStack? = nil,
                     fromTopLeft: Bool = false, actionName: String = "Paste") {
        guard let document, let stack = replacement ?? document.stack,
              let layer = replacement?.activeLayer ?? copyableLayer,
              layer.isVisible, layerPreview == nil else { return }
        let size = CGSize(width: pastedImage.width, height: pastedImage.height)
        let origin = fromTopLeft ? .zero : pasteOrigin(sourceOrigin, size: size, in: layer.image)
        let destination = CGRect(origin: origin, size: size)
        let rect = CGRect(x: origin.x, y: CGFloat(layer.image.height) - destination.maxY,
                          width: size.width, height: size.height)
        guard let outline = SelectionOutline(rect: rect),
              let pixels = SelectedPixelsTransform(layer: layer, pastedImage: pastedImage, at: destination) else { return }

        finishSelection()
        let geometry = MoveGeometry(rect: rect, pivot: rect.center)
        let session = MoveSession(layerIndex: stack.active, pixels: pixels, outline: outline,
                                  initialGeometry: geometry, geometry: geometry, sampling: moveSampling,
                                  recorded: true)
        if let replacement {
            document.applyEdit(replacingStack: replacement, actionName: actionName,
                               selectionChange: (selectionOutline, nil), moveChange: (nil, session))
        } else {
            document.recordMove(from: nil, to: session, actionName: actionName)
        }
        window?.makeFirstResponder(self)
    }

    private func pasteOrigin(_ source: CGPoint?, size: CGSize, in image: CGImage) -> CGPoint {
        let visible = imageRect.intersection(visibleRect)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat
        if visible.isEmpty {
            minX = 0
            minY = 0
            maxX = width
            maxY = height
        } else {
            // Use whole pixel edges in top-left image coordinates. A subpixel
            // sliver at the edge still has one pixel available for placement.
            minX = min(width - 1, ceil((visible.minX - imageRect.minX) / imageRect.width * width))
            minY = min(height - 1, ceil((imageRect.maxY - visible.maxY) / imageRect.height * height))
            maxX = floor((visible.maxX - imageRect.minX) / imageRect.width * width)
            maxY = floor((imageRect.maxY - visible.minY) / imageRect.height * height)
        }
        func fit(_ coordinate: CGFloat, lower: CGFloat, upper: CGFloat, length: CGFloat) -> CGFloat {
            max(lower, min(coordinate, upper - length))
        }
        return CGPoint(x: fit(source?.x ?? minX, lower: minX, upper: maxX, length: size.width),
                       y: fit(source?.y ?? minY, lower: minY, upper: maxY, length: size.height))
    }

    func cancelEditingGesture() {
        rasterDrawing = nil
        cloneCursor = nil
        drawingDraft = nil
        drawingDrag = nil
        endTextInput()
        cancelSelectionDrag()
        floodDrag = nil
        if let floodEdit {
            self.floodEdit = nil
            if case .select(_, let before) = floodEdit.operation { setSelection(before) }
        }
        fillPreview = nil
        gradientEdit = nil
        gradientDrag = nil
        if let drag = moveDrag {
            moveDrag = nil
            move = drag.before
        }
        composite = nil
        moveTilePreview = nil
        needsDisplay = true
        selectionDidChange?()
    }

    var hasPendingMove: Bool { move?.recorded == true || move?.changed == true }
    private(set) var moveSampling: MoveResampler.Mode = .bicubic

    func setMoveSampling(_ sampling: MoveResampler.Mode) {
        guard moveSampling != sampling else { return }
        guard let before = move, before.pixels != nil else {
            moveSampling = sampling
            return
        }
        var after = before
        after.sampling = sampling
        moveSampling = sampling
        if before.recorded {
            document?.recordMove(from: before, to: after, actionName: "Change Move Resampling")
        } else {
            restoreMove(after)
        }
    }
    var hasPendingFloodEdit: Bool { floodEdit != nil }
    var hasPendingGradient: Bool { gradientEdit != nil }
    var hasPendingDrawing: Bool { drawingDraft != nil }
    var hasLiveEditChange: Bool {
        renderGradientPreviewIfNeeded()
        return hasFloodChange || gradientEdit?.preview != nil || drawingDraft?.preview != nil
    }
    var hasFloodChange: Bool {
        guard let floodEdit else { return false }
        switch floodEdit.operation {
        case .select(_, let before): return before != selectionOutline
        case .fill: return fillPreview != nil
        }
    }
    var hasPendingPixelEdit: Bool {
        move?.hasPixelPreview == true || rasterDrawing?.changed == true || nonRasterPixelPreview != nil
    }
    var rotationDegrees: CGFloat? { move.map { $0.geometry.angle * 180 / .pi } }

    func restoreMove(_ session: MoveSession?) {
        let previous = move
        if previous?.pixels !== session?.pixels { moveTilePreview = nil }
        move = nil
        if let session {
            let transformTool: Tool = session.pixels == nil ? .moveSelection : .moveSelectedPixels
            if tool != transformTool {
                if let selectTool { selectTool(transformTool) }
                else { tool = transformTool }
            }
            if session.pixels != nil { moveSampling = session.sampling }
        }
        move = session
        if previous?.pixels == nil || previous?.pixels !== session?.pixels || previous?.geometry != session?.geometry ||
            previous?.sampling != session?.sampling || previous?.copy != session?.copy {
            needsDisplay = true
        }
        window?.invalidateCursorRects(for: self)
        selectionDidChange?()
    }

    func finishSelection() {
        finishLiveEdit()
        completeMoveDrag()
        guard let session = move, let image = document?.image else { return }
        guard session.recorded else {
            restoreMove(nil)
            return
        }
        let keepsOutline = session.isPaste || selectionOutline != nil
        let clipped = keepsOutline ? session.transformedOutline?.clipped(to: canvasBounds(for: image)) : nil
        var handles = session.geometry
        // The committed outline and pixels already include any reflection.
        handles.flipX = false
        handles.flipY = false
        let destination = clipped.flatMap { SelectionOutline(path: $0.path, handleGeometry: handles) }
        let layer = session.renderedLayer()
        guard !session.hasPixelPreview || layer != nil else { return }
        document?.commitSelectedPixelsTransform(layer, to: destination, actionName: "Finish Selection")
    }

    func finishLiveEdit() {
        finishFloodEdit()
        finishGradient()
        finishDrawing()
    }

    var imageSelection: CGRect? {
        guard let image = document?.image, !selection.isEmpty else { return nil }
        return topLeftRect(selection, imageHeight: image.height)
    }

    private func topLeftRect(_ rect: CGRect, imageHeight: Int) -> CGRect {
        // The canvas and bitmap context use a bottom-left origin. CGImage rows start at the top.
        return CGRect(x: rect.minX, y: CGFloat(imageHeight) - rect.maxY, width: rect.width, height: rect.height)
    }

    private func marquee(for selection: CGRect, imageWidth: Int) -> CGRect {
        let scale = imageRect.width / CGFloat(imageWidth)
        return CGRect(x: imageRect.minX + selection.minX * scale, y: imageRect.minY + selection.minY * scale,
                      width: selection.width * scale, height: selection.height * scale)
    }

    private func moveGeometry(for image: CGImage) -> MoveGeometry {
        if let move { return move.geometry }
        if let handles = selectionOutline?.handleGeometry { return handles }
        let rect = tool == .moveSelection ? selectionOutline?.bounds ?? .zero
            : (selectionOutline == nil ? canvasBounds(for: image) : selection)
        return MoveGeometry(rect: rect, pivot: rect.center)
    }

    private func showsTransformHandles(on layer: PaintLayer) -> Bool {
        if tool == .moveSelection { return selectionOutline != nil }
        return tool == .moveSelectedPixels && layer.isVisible && (selectionOutline != nil || move != nil)
    }

    private func transformHandle(at location: CGPoint, layer: PaintLayer) -> TransformHandle {
        guard showsTransformHandles(on: layer) else { return .move }
        let image = layer.image
        let geometry = moveGeometry(for: image)
        let frame = marquee(for: geometry.rect, imageWidth: image.width)
        let pivot = marquee(for: CGRect(origin: geometry.pivot, size: .zero), imageWidth: image.width).origin
        let radius = min(6, max(1, min(frame.width, frame.height) / 5))
        let pivotTarget = CGRect(x: pivot.x - radius, y: pivot.y - radius, width: 2 * radius, height: 2 * radius)
        if pivotTarget.contains(location) { return .pivot }
        let local = frame.center + (location - frame.center).rotated(by: -geometry.angle)
        if let handle = ResizeHandle.all.first(where: { $0.frame(in: frame).insetBy(dx: -2, dy: -2).contains(local) }) {
            return .resize(handle)
        }
        let rotationMargin: CGFloat = 48
        if !frame.contains(local) && frame.insetBy(dx: -rotationMargin, dy: -rotationMargin).contains(local) {
            return .rotate
        }
        return .move
    }

    var cropRect: CGRect? {
        guard !hasPendingMove, let image = document?.image, let imageSelection,
              selectionOutline?.pixelRectangle == false ||
                imageSelection.size != CGSize(width: image.width, height: image.height) else { return nil }
        return imageSelection
    }

    override func keyDown(with event: NSEvent) {
        if let textEditor {
            if window?.firstResponder === self {
                focusTextInput()
                if window?.firstResponder === textEditor { textEditor.keyDown(with: event) }
            } else {
                super.keyDown(with: event)
            }
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(), key == "c" || key == "x" {
            if event.isARepeat || handleColorShortcut?(key) == true { return }
        }
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection([.command, .option]).isEmpty {
            if !holdingSpace {
                holdingSpace = true
                brushCursor = nil
                window?.invalidateCursorRects(for: self)
                _ = updatePanCursor()
            }
            return
        }
        if (holdingSpace || tool == .pan), let delta = nudge(for: event), let scrollView = enclosingScrollView {
            scroll(to: scrollView.contentView.bounds.origin + delta, in: scrollView)
            return
        }
        if tool.usesBrushSize, let key = event.charactersIgnoringModifiers, key == "[" || key == "]",
           event.modifierFlags.intersection([.command, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.control) ? 5 : 1
            let newSize = brushSize + (key == "]" ? step : -step)
            brushSize = min(max(newSize, Self.brushSizeRange.lowerBound), Self.brushSizeRange.upperBound)
            return
        }
        let isEscape = event.keyCode == 53
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let deselects = (isEscape || isReturn) &&
            (move != nil || !selection.isEmpty || selectionDrag != nil || hasPendingFloodEdit || hasPendingGradient || hasPendingDrawing)
        if event.isARepeat && (isEscape || deselects) { return }
        if tool == .shapes, event.charactersIgnoringModifiers?.lowercased() == "a",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let shapes = DrawingShape.allCases
            let index = shapes.firstIndex(of: drawingStyle.shape) ?? 0
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            drawingStyle.shape = shapes[(index + delta + shapes.count) % shapes.count]
            selectionDidChange?()
        } else if !event.isARepeat, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let selectTool, let shortcut = event.charactersIgnoringModifiers?.lowercased(),
           let requested = toolForKey(shortcut, reverse: event.modifierFlags.contains(.shift)) {
            selectTool(requested)
        } else if (isEscape || isReturn) && hasPendingDrawing {
            finishDrawing()
        } else if let delta = nudge(for: event), let draft = drawingDraft, drawingDrag == nil {
            drawingDraft?.geometry = draft.geometry.translated(by: delta)
            updateDrawingPreview()
        } else if (isEscape || isReturn) && hasPendingGradient {
            finishGradient()
        } else if (isEscape || isReturn) && tool == .paintBucket && hasPendingFloodEdit {
            finishFloodEdit()
        } else if deselects {
            document?.deselect(nil)
        } else if tool.transformsSelection, let delta = nudge(for: event), moveDrag == nil,
                  let stack = document?.stack {
            let before = move
            if beginMove(on: stack) {
                let image = stack.activeLayer.image
                let geometry = moveGeometry(for: image)
                updateMove(with: translated(geometry, by: delta), actionName: "Move Selected Pixels", copy: false)
                recordMove(from: before, geometry: geometry)
            } else {
                super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", holdingSpace {
            holdingSpace = false
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else {
            super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        holdingSpace = false
        updateBrushCursor()
        window?.invalidateCursorRects(for: self)
        return super.resignFirstResponder()
    }

    private func nudge(for event: NSEvent) -> CGPoint? {
        let step: CGFloat = event.modifierFlags.contains(.control) ? 10 : 1
        switch event.keyCode {
        case 123: return CGPoint(x: -step, y: 0)
        case 124: return CGPoint(x: step, y: 0)
        case 125: return CGPoint(x: 0, y: -step)
        case 126: return CGPoint(x: 0, y: step)
        default: return nil
        }
    }

    private func beginMove(on stack: LayerStack) -> Bool {
        let layer = stack.activeLayer
        guard !imageRect.isEmpty, layerPreview == nil,
              tool == .moveSelection ? selectionOutline != nil : layer.isVisible else { return false }
        if move != nil { return true }
        let geometry = moveGeometry(for: layer.image)
        guard let outline = selectionOutline ?? SelectionOutline(rect: geometry.rect) else { return false }
        var pixels: SelectedPixelsTransform?
        if tool == .moveSelectedPixels {
            let height = layer.image.height
            let region = topLeftRect(outline.bounds.integral, imageHeight: height)
            let mask = outline.pixelRectangle ? nil : outline.mask(in: region, imageHeight: height)
            guard outline.pixelRectangle || mask != nil,
                  let transform = SelectedPixelsTransform(layer: layer, selection: region, mask: mask) else { return false }
            pixels = transform
        }
        move = MoveSession(layerIndex: stack.active, pixels: pixels, outline: outline,
                           initialGeometry: geometry, geometry: geometry, sampling: moveSampling)
        return true
    }

    private func beginMoveDrag(with event: NSEvent, rightButton: Bool) {
        let before = move
        guard panDrag == nil, moveDrag == nil, let stack = document?.stack else { return }
        let location = convert(event.locationInWindow, from: nil)
        let handle = rightButton ? .rotate : transformHandle(at: location, layer: stack.activeLayer)
        guard beginMove(on: stack) else { return }
        window?.makeFirstResponder(self)
        let point = imagePoint(location)
        let geometry = moveGeometry(for: stack.activeLayer.image)
        moveDrag = MoveDrag(before: before, geometry: geometry, anchor: point, handle: handle,
                            rightButton: rightButton, lastPoint: point, resizeGeometry: geometry,
                            resizeAnchor: point, proportional: event.modifierFlags.contains(.shift))
        updateMoveCursor(at: location)
    }

    private func translated(_ geometry: MoveGeometry, by delta: CGPoint) -> MoveGeometry {
        var next = geometry
        next.rect = next.rect.offsetBy(dx: delta.x, dy: delta.y)
        next.pivot = next.pivot + delta
        return next
    }

    private func updateMoveDrag(with event: NSEvent, rightButton: Bool) {
        guard let drag = moveDrag, drag.rightButton == rightButton else { return }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        updateMoveDrag(at: point, modifiers: event.modifierFlags)
    }

    private func updateMoveDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var drag = moveDrag else { return }
        let previousPoint = drag.lastPoint
        drag.lastPoint = point
        let delta = point - drag.anchor
        var geometry = drag.geometry
        let actionName: String
        switch drag.handle {
        case .pivot:
            moveDrag = drag
            move?.geometry.pivot = geometry.pivot + delta
            needsDisplay = true
            return
        case .move:
            let rounding: FloatingPointRoundingRule = tool == .moveSelectedPixels ? .towardZero : .toNearestOrAwayFromZero
            let offset = CGPoint(x: delta.x.rounded(rounding), y: delta.y.rounded(rounding))
            geometry = translated(geometry, by: offset)
            actionName = "Move Selected Pixels"
        case .resize(let handle):
            let proportional = modifiers.contains(.shift)
            if proportional != drag.proportional {
                // Pick up the live size when shifting between free and constrained resizing.
                drag.resizeGeometry = move?.geometry ?? drag.resizeGeometry
                drag.resizeAnchor = previousPoint
                drag.proportional = proportional
            }
            geometry = handle.resized(drag.resizeGeometry, delta: point - drag.resizeAnchor, proportional: proportional,
                                      centered: modifiers.contains(.option))
            actionName = "Resize Selected Pixels"
        case .rotate:
            let from = drag.anchor - geometry.pivot, to = point - geometry.pivot
            guard from != .zero, to != .zero else {
                moveDrag = drag
                return
            }
            let change = atan2(from.x * to.y - from.y * to.x, from.x * to.x + from.y * to.y)
            let step = CGFloat.pi / 12
            let angle = geometry.angle + change
            let snapped = modifiers.contains(.shift) ? (angle / step).rounded() * step : angle
            let rotation = snapped - geometry.angle
            let center = geometry.pivot + (geometry.rect.center - geometry.pivot).rotated(by: rotation)
            geometry.rect.origin = CGPoint(x: center.x - geometry.rect.width / 2, y: center.y - geometry.rect.height / 2)
            geometry.angle = snapped.remainder(dividingBy: 2 * .pi)
            actionName = "Rotate Pixels"
        }
        moveDrag = drag
        let copy = !modifiers.intersection([.control, .command]).isEmpty
        updateMove(with: geometry, actionName: actionName, copy: copy)
    }

    private func updateMove(with geometry: MoveGeometry, actionName: String, copy: Bool) {
        guard let previous = move else { return }
        let keepSource = previous.copy || copy
        guard previous.geometry != geometry || previous.copy != keepSource else { return }
        var session = previous
        session.geometry = geometry
        session.copy = keepSource
        session.actionName = tool == .moveSelection ? "Transform Selection" : actionName
        move = session
        if let pixels = session.pixels, let image = document?.image {
            invalidateMovePreview(from: previous, to: session, pixels: pixels, image: image)
        } else {
            needsDisplay = true
        }
        selectionDidChange?()
    }

    private func invalidateMovePreview(from before: MoveSession, to after: MoveSession,
                                       pixels: SelectedPixelsTransform, image: CGImage) {
        let width = image.width
        func invalidatePixels(_ region: CGRect) {
            guard !region.isEmpty else { return }
            setNeedsDisplay(marquee(for: topLeftRect(region, imageHeight: image.height), imageWidth: width)
                .insetBy(dx: -2, dy: -2))
        }
        let oldTransform = before.transform
        let newTransform = after.transform
        invalidatePixels(pixels.destinationRegion(by: oldTransform))
        invalidatePixels(pixels.destinationRegion(by: newTransform))
        let oldHole = pixels.clearedRegion(by: oldTransform, copy: before.copy)
        let newHole = pixels.clearedRegion(by: newTransform, copy: after.copy)
        if oldHole != newHole {
            invalidatePixels(oldHole)
            invalidatePixels(newHole)
        }
        for state in [before, after] {
            let frame = marquee(for: state.geometry.rect, imageWidth: width)
            let handleFrame = frame.insetBy(dx: -max(0, (28 - frame.width) / 2),
                                            dy: -max(0, (28 - frame.height) / 2))
            let rotation = CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: state.geometry.angle).translatedBy(x: -frame.midX, y: -frame.midY)
            let outline = marquee(for: state.outline.bounds.applying(state.transform), imageWidth: width)
            setNeedsDisplay(outline.union(handleFrame.applying(rotation)).insetBy(dx: -8, dy: -8))
            let pivot = marquee(for: CGRect(origin: state.geometry.pivot, size: .zero), imageWidth: width).origin
            setNeedsDisplay(CGRect(x: pivot.x - 7, y: pivot.y - 7, width: 14, height: 14))
        }
    }

    private func endMoveDrag(with event: NSEvent, rightButton: Bool) {
        guard moveDrag?.rightButton == rightButton else { return }
        updateMoveDrag(with: event, rightButton: rightButton)
        completeMoveDrag()
        updateMoveCursor(at: convert(event.locationInWindow, from: nil))
    }

    func completeMoveDrag() {
        guard let drag = moveDrag else { return }
        moveDrag = nil
        if case .pivot = drag.handle {
            if let session = move, !session.recorded, session.geometry.pivot == session.initialGeometry.pivot {
                restoreMove(nil)
            }
        } else {
            recordMove(from: drag.before, geometry: drag.geometry)
        }
    }

    private func recordMove(from before: MoveSession?, geometry: MoveGeometry) {
        guard var session = move else { return }
        guard session.geometry != geometry || (session.changed && session.copy != (before?.copy ?? false)) else {
            restoreMove(before)
            return
        }
        session.recorded = true
        document?.recordMove(from: before, to: session, actionName: session.actionName)
    }

    override func rightMouseDown(with event: NSEvent) {
        if holdingSpace || tool == .pan { beginPan(with: event); return }
        guard panDrag == nil else { return }
        if tool.transformsSelection { beginMoveDrag(with: event, rightButton: true) }
        else if tool == .gradient { beginGradient(with: event, rightButton: true) }
        else if tool.usesFlood || tool.drawsSelection {
            let location = convert(event.locationInWindow, from: nil)
            guard imageRect.contains(location), let image = document?.image else {
                if tool.drawsSelection { document?.deselect(nil) }
                return
            }
            window?.makeFirstResponder(self)
            if tool.usesFlood {
                beginFloodEdit(at: imagePoint(location), modifiers: event.modifierFlags, secondary: true)
            } else {
                beginSelectionDrag(at: location, in: image, modifiers: event.modifierFlags, rightButton: true)
            }
        }
        else if tool.usesRasterDrawing || tool.usesVectorDrawing || tool == .colorPicker || tool == .zoom {
            beginToolGesture(with: event, secondary: true)
        }
        else { super.rightMouseDown(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if panDrag != nil { dragPan(with: event); return }
        if tool.transformsSelection { updateMoveDrag(with: event, rightButton: true) }
        else if tool == .gradient { dragGradient(with: event, rightButton: true) }
        else if dragSelection(with: event, rightButton: true) { return }
        else if updateToolGesture(with: event) { return }
        else { super.rightMouseDragged(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if panDrag != nil { finishPan(with: event); return }
        if tool.transformsSelection { endMoveDrag(with: event, rightButton: true) }
        else if tool == .gradient { endGradientDrag(with: event, rightButton: true) }
        else if finishSelectionDrag(with: event, rightButton: true) { return }
        else if endToolGesture(with: event) { return }
        else { super.rightMouseUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if let point = moveDrag?.lastPoint { updateMoveDrag(at: point, modifiers: event.modifierFlags) }
        if (tool == .rectangleSelect || tool == .ellipseSelect), selectionDrag != nil, let image = document?.image {
            updateSelectionDrag(in: image, modifiers: event.modifierFlags)
        }
        super.flagsChanged(with: event)
    }

    override func tabletProximity(with event: NSEvent) {
        if event.isEnteringProximity { noticeTablet() }
        super.tabletProximity(with: event)
    }

    private func noticeTablet() {
        guard !hasSeenTablet else { return }
        hasSeenTablet = true
        selectionDidChange?()
    }

    private func beginGradient(with event: NSEvent, rightButton: Bool) {
        guard panDrag == nil, gradientDrag == nil, let layer = document?.stack?.activeLayer else { return }
        let location = convert(event.locationInWindow, from: nil)
        if var edit = gradientEdit {
            let handles = gradientHandleCenters(edit.line, imageWidth: layer.image.width)
            let startDelta = location - handles.start, endDelta = location - handles.end
            let startDistance = hypot(startDelta.x, startDelta.y)
            let endDistance = hypot(endDelta.x, endDelta.y)
            if min(startDistance, endDistance) <= 9 {
                window?.makeFirstResponder(self)
                if rightButton {
                    edit.reversed.toggle()
                    gradientEdit = edit
                    invalidateGradientPreview()
                } else {
                    let movesStart = startDistance < endDistance
                    let endpoint = movesStart ? edit.line.start : edit.line.end
                    gradientDrag = GradientDrag(startsLine: false, movesStart: movesStart, rightButton: false,
                                                offset: endpoint - imagePoint(location))
                }
                return
            }
        }
        guard imageRect.contains(location) else { return }
        finishGradient()
        guard var layer = document?.stack?.activeLayer, layer.isVisible, let pixels = layer.straightPixels else {
            NSSound.beep()
            return
        }
        layer.pdnPixels = pixels
        window?.makeFirstResponder(self)
        let point = imagePoint(location)
        gradientEdit = GradientEdit(layer: layer, selection: selectionOutline,
                                    line: LinearGradient(start: point, end: point), reversed: rightButton)
        gradientDrag = GradientDrag(startsLine: true, movesStart: false, rightButton: rightButton, offset: .zero)
        needsDisplay = true
        selectionDidChange?()
    }

    private func dragGradient(with event: NSEvent, rightButton: Bool) {
        guard let drag = gradientDrag, drag.rightButton == rightButton, var edit = gradientEdit else { return }
        var point = imagePoint(convert(event.locationInWindow, from: nil)) + drag.offset
        if event.modifierFlags.contains(.shift) {
            let anchor = drag.movesStart ? edit.line.end : edit.line.start
            let delta = point - anchor
            let step = CGFloat.pi / 12
            let angle = (atan2(delta.y, delta.x) / step).rounded() * step
            point = anchor + CGPoint(x: hypot(delta.x, delta.y), y: 0).rotated(by: angle)
        }
        let current = drag.movesStart ? edit.line.start : edit.line.end
        guard current != point else { return }
        if drag.movesStart { edit.line.start = point }
        else { edit.line.end = point }
        gradientEdit = edit
        invalidateGradientPreview()
    }

    private func endGradientDrag(with event: NSEvent, rightButton: Bool) {
        guard let drag = gradientDrag, drag.rightButton == rightButton else { return }
        dragGradient(with: event, rightButton: rightButton)
        gradientDrag = nil
        renderGradientPreviewIfNeeded()
        if drag.startsLine, let edit = gradientEdit, edit.line.start == edit.line.end { finishGradient() }
    }

    private func invalidateGradientPreview() {
        guard gradientEdit != nil else { return }
        // AppKit coalesces redraws, so only rasterize the latest endpoint for each draw.
        gradientEdit?.needsRender = true
        needsDisplay = true
    }

    private func renderGradientPreviewIfNeeded() {
        guard let edit = gradientEdit, edit.needsRender else { return }
        let primary = (brushColor.usingColorSpace(.sRGB) ?? .black).cgColor
        let secondary = (secondaryColor.usingColorSpace(.sRGB) ?? .white).cgColor
        gradientEdit?.preview = edit.line.applying(to: edit.layer, primary: primary, secondary: secondary,
                                                   selection: edit.selection, options: gradientOptions,
                                                   reversed: edit.reversed)
        gradientEdit?.needsRender = false
        composite = nil
        selectionDidChange?()
    }

    private func finishGradient() {
        renderGradientPreviewIfNeeded()
        guard let edit = gradientEdit else { return }
        gradientEdit = nil
        gradientDrag = nil
        composite = nil
        needsDisplay = true
        if let preview = edit.preview { document?.commitPaintLayer(preview, actionName: "Gradient") }
        selectionDidChange?()
    }

    override func mouseDown(with event: NSEvent) {
        if holdingSpace || tool == .pan { beginPan(with: event); return }
        guard panDrag == nil else { return }
        if tool.usesRasterDrawing || tool.usesVectorDrawing || tool == .colorPicker || tool == .zoom {
            beginToolGesture(with: event, secondary: false)
            return
        }
        if tool == .gradient {
            beginGradient(with: event, rightButton: false)
            return
        }
        if tool.transformsSelection {
            beginMoveDrag(with: event, rightButton: false)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        if let edit = floodEdit, floodHandle?.frame.contains(location) == true {
            window?.makeFirstResponder(self)
            floodDrag = (imagePoint(location), edit.x, edit.y)
            updateFloodCursor(at: location)
            return
        }
        guard imageRect.contains(location), let image = document?.image else {
            if tool.drawsSelection { document?.deselect(nil) }
            return
        }

        window?.makeFirstResponder(self)
        if tool.usesFlood {
            beginFloodEdit(at: imagePoint(location), modifiers: event.modifierFlags)
            return
        }
        if tool.drawsSelection {
            beginSelectionDrag(at: location, in: image, modifiers: event.modifierFlags, rightButton: false)
            return
        }
    }

    private func beginFloodEdit(at point: CGPoint, modifiers: NSEvent.ModifierFlags, secondary: Bool = false) {
        finishFloodEdit()
        guard let stack = document?.stack else { return }
        let fillsPixels = tool == .paintBucket
        if fillsPixels && !stack.activeLayer.isVisible {
            NSSound.beep()
            return
        }
        let sampleImage = floodSettings.sampling == .image || (fillsPixels && modifiers.contains(.control))
        guard var source = sampleImage ? stack.flattenedLayer() : stack.activeLayer,
              let pixels = source.straightPixels else { return }
        source.pdnPixels = pixels
        let x = min(max(0, Int(point.x)), source.image.width - 1)
        let y = min(max(0, source.image.height - 1 - Int(point.y)), source.image.height - 1)
        let operation: FloodEdit.Operation
        if fillsPixels {
            var layer = stack.activeLayer
            guard let original = sampleImage ? layer.straightPixels : pixels else { return }
            layer.pdnPixels = original
            var mask: Data?
            if let outline = selectionOutline {
                guard let selectionMask = outline.mask(in: canvasBounds(for: layer.image), imageHeight: layer.image.height),
                      selectionMask[y * layer.image.width + x] != 0 else { return }
                mask = selectionMask
            }
            operation = .fill(layer: layer, mask: mask)
        } else {
            operation = .select(mode: selectionMode(at: modifiers, rightButton: secondary), before: selectionOutline)
        }
        let flood = modifiers.contains(.shift) ? (floodSettings.flood == .global ? FloodSettings.Flood.contiguous : .global) : floodSettings.flood
        floodEdit = FloodEdit(source: source, x: x, y: y, flood: flood, secondary: secondary, operation: operation)
        updateFloodEdit()
        needsDisplay = true
        selectionDidChange?()
    }

    func setFloodTolerance(_ tolerance: Int) {
        guard floodSettings.tolerance != tolerance else { return }
        floodSettings.tolerance = tolerance
        updateFloodEdit()
    }

    private func updateFloodEdit() {
        guard let edit = floodEdit else { return }
        var settings = floodSettings
        settings.flood = edit.flood
        switch edit.operation {
        case .select(let mode, let before):
            guard let outline = settings.select(in: edit.source, x: edit.x, y: edit.y) else { return }
            setSelection(mode.applying(outline, to: before))
        case .fill(let layer, let mask):
            let outline = settings.select(in: edit.source, x: edit.x, y: edit.y, within: mask)
            let color = DrawingColor(edit.secondary ? secondaryColor : brushColor, in: layer.workingColorSpace)
            fillPreview = outline.flatMap {
                layer.filling($0, blue: color.blue, green: color.green, red: color.red, alpha: color.alpha)
            }
            composite = nil
            needsDisplay = true
            selectionDidChange?()
        }
    }

    func finishFloodEdit() {
        guard let edit = floodEdit else { return }
        floodDrag = nil
        floodEdit = nil
        needsDisplay = true
        switch edit.operation {
        case .select(let mode, let before):
            let result = selectionOutline
            setSelection(before)
            let name = mode == .replace ? "Magic Wand" : "Magic Wand (\(mode.rawValue))"
            document?.commitSelection(result, actionName: name)
        case .fill:
            let result = fillPreview
            fillPreview = nil
            composite = nil
            if let result { document?.commitPaintLayer(result, actionName: "Paint Bucket") }
        }
        selectionDidChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        if panDrag != nil { dragPan(with: event); return }
        if updateToolGesture(with: event) { return }
        if tool == .gradient {
            dragGradient(with: event, rightButton: false)
            return
        }
        guard !imageRect.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        if let drag = floodDrag, var edit = floodEdit {
            let delta = imagePoint(location) - drag.anchor
            let x = min(max(0, drag.x + Int(delta.x.rounded())), edit.source.image.width - 1)
            let y = min(max(0, drag.y - Int(delta.y.rounded())), edit.source.image.height - 1)
            if edit.x != x || edit.y != y {
                edit.x = x
                edit.y = y
                floodEdit = edit
                updateFloodEdit()
                needsDisplay = true
            }
            return
        }
        if dragSelection(with: event, rightButton: false) { return }
        if moveDrag != nil {
            updateMoveDrag(with: event, rightButton: false)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        if panDrag != nil { finishPan(with: event); return }
        if endToolGesture(with: event) { return }
        if tool == .gradient {
            endGradientDrag(with: event, rightButton: false)
            return
        }
        if moveDrag != nil {
            endMoveDrag(with: event, rightButton: false)
            return
        }
        if finishSelectionDrag(with: event, rightButton: false) { return }
        mouseDragged(with: event)
        if floodDrag != nil {
            floodDrag = nil
            updateFloodCursor(at: convert(event.locationInWindow, from: nil))
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.gray.withAlphaComponent(0.22).setFill()
        dirtyRect.fill()
        let rect = imageRect
        let visible = rect.intersection(dirtyRect)
        guard let graphics = NSGraphicsContext.current, var stack = layerPreview ?? document?.stack else { return }
        let context = graphics.cgContext
        let floating = move.flatMap { $0.hasPixelPreview ? $0 : nil }
        let brush = floating == nil && rasterDrawing?.changed == true ? rasterDrawing : nil
        let preview = floating == nil ? nonRasterPixelPreview : nil
        if let preview { stack.layers[stack.active] = preview }
        // AppKit can call draw while rendering the window into a backing surface.
        let onScreen = window != nil && NSPrintOperation.current == nil
        let wantsMetal = onScreen && usesMetalViewportPreview
        let presents: Bool
        if wantsMetal && !metalPresentationFailed && !imageRect.intersection(visibleRect).isEmpty {
            presents = presentMetalCanvas(stack, move: floating, brush: brush, preview: preview)
            metalPresentationFailed = !presents
        } else {
            presents = false
        }
        let revealsFallback = onScreen && !presents && metalCanvas?.isHidden == false
        let viewportImage = rect.intersection(visibleRect)
        if revealsFallback && !viewportImage.isEmpty && !coversFallbackViewport(viewportImage, dirtyRect: dirtyRect) {
            // AppKit clips this draw to the dirty area. Keep the prior Metal frame until the
            // software backing has a complete viewport, including tiles untouched by the edit.
            if !fallbackRepaintScheduled {
                fallbackRepaintScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.fallbackRepaintScheduled = false
                    self.setNeedsDisplay(self.visibleRect)
                }
            }
            return
        }
        defer {
            if !presents { drawCanvasDecorations(stack.activeLayer, in: context) }
            if revealsFallback {
                metalCanvas?.clearFrame()
                metalOverlay?.isHidden = true
            }
        }
        guard !visible.isEmpty else { return }

        context.saveGState()
        context.clip(to: visible)
        if presents {
            context.restoreGState()
            return
        }
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(rect)
        context.setFillColor(gray: 0.73, alpha: 1)
        let square: CGFloat = 12
        let rows = Int((visible.minY - rect.minY) / square)..<Int(ceil((visible.maxY - rect.minY) / square))
        let columns = Int((visible.minX - rect.minX) / square)..<Int(ceil((visible.maxX - rect.minX) / square))
        for row in rows {
            for column in columns where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: rect.minX + CGFloat(column) * square,
                                    y: rect.minY + CGFloat(row) * square, width: square, height: square))
            }
        }
        if displayedZoomPercent >= 100 { context.interpolationQuality = .none }
        if let floating, stack.activeLayer.opacity > 0 {
            drawMovePreview(floating, stack: stack, visible: visible, allowsBitmapMetal: !wantsMetal, in: context)
        } else {
            drawStack(stack, visible: visible, brush: brush, in: context)
        }
        context.restoreGState()
    }

    private func coversFallbackViewport(_ viewport: CGRect, dirtyRect: CGRect) -> Bool {
        guard dirtyRect.contains(viewport) else { return false }
        // The dirty rectangle may be the bounding box of several disjoint AppKit clips.
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        guard let rects, count > 0 else { return true }
        return UnsafeBufferPointer(start: rects, count: count).contains { $0.contains(viewport) }
    }

    private func drawCanvasDecorations(_ layer: PaintLayer, in context: CGContext) {
        let rect = imageRect
        let image = layer.image
        let showsHandles = showsTransformHandles(on: layer)
        let geometry = moveGeometry(for: image)
        let marquee = marquee(for: showsHandles ? geometry.rect : selection, imageWidth: image.width)
        defer {
            drawDrawingHandles(imageWidth: image.width, in: context)
            if let edit = gradientEdit { drawGradientHandles(edit.line, imageWidth: image.width, in: context) }
            if let handle = floodHandle { drawFloodHandle(at: handle.seed, frame: handle.frame, in: context) }
            if showsHandles && !marquee.isEmpty {
                let pivot = self.marquee(for: CGRect(origin: geometry.pivot, size: .zero), imageWidth: image.width).origin
                drawTransformHandles(around: marquee, angle: geometry.angle, pivot: pivot, in: context)
            }
            if let brushCursor {
                context.saveGState()
                context.setStrokeColor(gray: 1, alpha: 1)
                context.setLineWidth(3)
                context.strokeEllipse(in: brushCursor)
                context.setStrokeColor(gray: 0, alpha: 1)
                context.setLineWidth(1)
                context.strokeEllipse(in: brushCursor)
                context.restoreGState()
            }
        }
        guard !rect.isEmpty else { return }
        if showsPixelGrid { drawWorkspaceGrid(in: context) }
        let outline = move?.transformedOutline ?? selectionOutline
        let scale = rect.width / CGFloat(image.width)
        let toView = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        if let path = outline?.transformed(by: toView)?.path {
            context.saveGState()
            if !showsHandles || tool == .moveSelection {
                context.clip(to: rect)
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                context.addPath(path)
                context.fillPath(using: .evenOdd)
            }
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.addPath(path)
            context.strokePath()
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
    }

    private func presentMetalCanvas(_ stack: LayerStack, move requestedMove: MoveSession?, brush: RasterDrawing?,
                                    preview: PaintLayer?) -> Bool {
        let rect = imageRect.intersection(visibleRect)
        let image = stack.activeLayer.image
        let region = imageRegion(for: rect, width: image.width)
        let session = stack.activeLayer.isVisible && stack.activeLayer.opacity > 0 ? requestedMove : nil
        let transform = session?.transform ?? .identity
        let documentStack = document?.stack ?? stack
        let sheetUsesActivePixels = layerPreview != nil && canSharePreviewLayers(stack, committed: documentStack)
        let usesSheetStack = layerPreview != nil && !sheetUsesActivePixels
        let candidate = sheetUsesActivePixels ? stack.activeLayer : preview
        let activePreview = stack.activeLayer.isVisible && stack.activeLayer.opacity > 0 ? candidate : nil
        let renderer: MetalMovePreview?
        if let session {
            if moveTilePreview == nil, let pixels = session.pixels {
                moveTilePreview = MoveTilePreview(stack: stack, pixels: pixels, residentStack: cachedMetalComposite)
            }
            renderer = moveTilePreview?.metalRenderer
        } else if usesSheetStack {
            if metalSheetPreview == nil { metalSheetPreview = MetalMovePreview(stack: stack) }
            renderer = metalSheetPreview
        } else if let revision = document?.stackRevision {
            if metalStack?.revision != revision {
                metalStack = (revision, MetalMovePreview(stack: documentStack))
            }
            renderer = metalStack?.renderer
        } else {
            return false
        }
        guard let renderer else {
            MetalMovePreview.log.error("Could not prepare the Metal canvas renderer")
            return false
        }
        if metalCanvas == nil {
            let surface = MetalCanvasSurface(frame: rect)
            surface.wantsLayer = true
            addSubview(surface)
            metalCanvas = surface
            let overlay = MetalCanvasOverlay(frame: visibleRect)
            overlay.wantsLayer = true
            overlay.drawDecorations = { [weak self] context in
                guard let self, let layer = (self.layerPreview ?? self.document?.stack)?.activeLayer else { return }
                self.drawCanvasDecorations(layer, in: context)
            }
            addSubview(overlay, positioned: .above, relativeTo: surface)
            metalOverlay = overlay
        }
        guard let surface = metalCanvas, let overlay = metalOverlay else { return false }
        let size = CGSize(width: max(1, (rect.width * backingScale).rounded()),
                          height: max(1, (rect.height * backingScale).rounded()))
        let checker = SIMD4(Float((rect.minX - imageRect.minX) * backingScale),
                            Float((rect.maxY - imageRect.minY) * backingScale), Float(12 * backingScale), 0)
        let frame = MetalCanvasSurface.Frame(region: region, size: size, transform: transform,
                                            copy: session?.copy ?? false, sampling: session?.sampling ?? .bicubic,
                                            checkerboard: checker, activeImage: activePreview.map { ObjectIdentifier($0.image) },
                                            strokeRevision: brush == nil ? nil : metalStrokeRevision)
        if surface.frame != rect { surface.frame = rect }
        surface.isHidden = false
        guard surface.draw(frame, with: renderer, activePixels: {
            if let brush { return prepareMetalStroke(brush, stack: documentStack, renderer: renderer) }
            guard let activePreview else {
                metalActivePreview = nil
                return nil
            }
            if metalActivePreview?.image !== activePreview.image, let bytes = activePreview.straightPixels,
               let pixels = renderer.makeActivePixels(from: bytes) {
                metalActivePreview = (activePreview.image, pixels)
            }
            return metalActivePreview?.image === activePreview.image ? metalActivePreview?.pixels : nil
        }, invalidate: { [weak self] in self?.needsDisplay = true }) else { return false }
        if overlay.frame != visibleRect { overlay.frame = visibleRect }
        overlay.isHidden = false
        overlay.needsDisplay = true
        return true
    }

    private func canSharePreviewLayers(_ preview: LayerStack, committed: LayerStack) -> Bool {
        guard preview.active == committed.active, preview.layers.count == committed.layers.count else { return false }
        return preview.layers.indices.allSatisfy { index in
            let a = preview.layers[index], b = committed.layers[index]
            return (index == preview.active || a.image === b.image) && a.isVisible == b.isVisible &&
                a.opacity == b.opacity && a.blendMode == b.blendMode
        }
    }

    private func prepareMetalStroke(_ brush: RasterDrawing, stack: LayerStack, renderer: MetalMovePreview)
        -> MetalMovePreview.ActivePixels? {
        if metalStroke?.renderer !== renderer {
            let image = stack.activeLayer.image
            let bounds = canvasBounds(for: image)
            let previous = metalStroke == nil ? nil : brush.pixels(in: bounds)
            guard let bytes = previous ?? stack.activeLayer.straightPixels,
                  let pixels = renderer.makeActivePixels(from: bytes) else { return nil }
            metalStroke = (renderer, pixels)
        }
        if !metalStrokeDirty.isEmpty, let bytes = brush.pixels(in: metalStrokeDirty) {
            metalStroke?.pixels.update(bytes, in: metalStrokeDirty)
        }
        metalStrokeDirty = .null
        return metalStroke?.pixels
    }

    private func drawStack(_ stack: LayerStack, visible: CGRect, brush: RasterDrawing? = nil, in context: CGContext) {
        guard stack.needsBlendComposite || brush != nil else {
            stack.draw(in: context, rect: imageRect)
            return
        }
        if composite == nil { composite = CanvasComposite(stack: stack) }
        // At actual pixels and higher zooms the draw uses nearest sampling. At lower zooms
        // provide the full composite so Core Graphics can sample across the entire image.
        let region = displayedZoomPercent >= 100
            ? imageRegion(for: visible, width: stack.activeLayer.image.width).insetBy(dx: -1, dy: -1)
            : nil
        if let image = composite?.render(stack: stack, region: region, activePixels: brush.map { $0.pixels(in:) }) {
            context.draw(image, in: imageRect)
        } else {
            var fallback = stack
            if let preview = brush?.preview { fallback.layers[fallback.active] = preview }
            if let image = fallback.flattenedLayer()?.image { context.draw(image, in: imageRect) }
        }
    }

    private func imageRegion(for rect: CGRect, width: Int) -> CGRect {
        let scale = imageRect.width / CGFloat(width)
        return CGRect(x: (rect.minX - imageRect.minX) / scale, y: (imageRect.maxY - rect.maxY) / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }

    private func viewRegion(for rect: CGRect, image: CGImage) -> CGRect {
        marquee(for: topLeftRect(rect, imageHeight: image.height), imageWidth: image.width)
    }

    private func tileClip(_ rect: CGRect, in context: CGContext, image: CGImage) -> CGRect {
        let device = context.convertToDeviceSpace(viewRegion(for: rect, image: image))
        let x = device.minX.rounded(), y = device.minY.rounded()
        return context.convertToUserSpace(CGRect(x: x, y: y, width: device.maxX.rounded() - x,
                                                 height: device.maxY.rounded() - y))
    }

    private func drawTile(_ tile: CGImage, padded: CGRect, clip: CGRect, in context: CGContext, image: CGImage) {
        context.saveGState()
        context.clip(to: clip)
        context.draw(tile, in: viewRegion(for: padded, image: image))
        context.restoreGState()
    }

    private func drawMovePreview(_ session: MoveSession, stack: LayerStack, visible: CGRect,
                                 allowsBitmapMetal: Bool, in context: CGContext) {
        let image = stack.activeLayer.image
        let transform = session.transform
        if !stack.needsBlendComposite,
           let offset = session.pixels?.retainedImageOffset(by: transform, copy: session.copy) {
            // The canvas clip exposes the checkerboard wherever the translated image leaves a gap.
            let scale = imageRect.width / CGFloat(image.width)
            context.draw(image, in: imageRect.offsetBy(dx: offset.x * scale, dy: offset.y * scale))
            return
        }
        if moveTilePreview == nil, let pixels = session.pixels {
            moveTilePreview = MoveTilePreview(stack: stack, pixels: pixels)
        }
        guard let moveTilePreview else {
            var rendered = stack
            if let layer = session.renderedLayer() { rendered.layers[rendered.active] = layer }
            if rendered.needsBlendComposite {
                if let image = rendered.blendComposite()?.image { context.draw(image, in: imageRect) }
            } else {
                rendered.draw(in: context, rect: imageRect)
            }
            return
        }
        let dirtyImage = imageRegion(for: visible, width: image.width)
        if allowsBitmapMetal && usesMetalMovePreview, let preview = moveTilePreview.metalFrame(in: dirtyImage, by: transform,
                                                                         copy: session.copy, sampling: session.sampling) {
            context.draw(preview.image, in: viewRegion(for: preview.region, image: image))
            return
        }
        let tiles = moveTilePreview.tiles(in: dirtyImage, by: transform, copy: session.copy,
                                         sampling: session.sampling)
        if tiles.isEmpty {
            drawStack(stack, visible: visible, in: context)
            return
        }
        let cores = tiles.map { tileClip($0.core, in: context, image: image) }
        // Replace tiles, including transparent pixels, rather than painting them over the original stack.
        context.saveGState()
        context.addRect(imageRect.insetBy(dx: -2, dy: -2))
        context.addRects(cores)
        context.clip(using: .evenOdd)
        drawStack(stack, visible: visible, in: context)
        context.restoreGState()
        for (tile, core) in zip(tiles, cores) {
            drawTile(tile.image, padded: tile.padded, clip: core, in: context, image: image)
        }
    }

    private var floodHandle: (seed: CGPoint, frame: CGRect)? {
        guard tool.usesFlood, let edit = floodEdit, !imageRect.isEmpty else { return nil }
        let pixel = CGPoint(x: CGFloat(edit.x) + 0.5, y: CGFloat(edit.source.image.height - edit.y) - 0.5)
        let seed = marquee(for: CGRect(origin: pixel, size: .zero), imageWidth: edit.source.image.width).origin
        let viewport = visibleRect
        guard viewport.contains(seed) else { return nil }
        let halfSize: CGFloat = 9
        let offset: CGFloat = 22
        let x = seed.x + (seed.x + offset + halfSize <= viewport.maxX ? offset : -offset)
        let y = seed.y + (seed.y + offset + halfSize <= viewport.maxY ? offset : -offset)
        return (seed, CGRect(x: x - halfSize, y: y - halfSize, width: 2 * halfSize, height: 2 * halfSize))
    }

    private func gradientHandleCenters(_ line: LinearGradient, imageWidth: Int) -> (start: CGPoint, end: CGPoint) {
        (marquee(for: CGRect(origin: line.start, size: .zero), imageWidth: imageWidth).origin,
         marquee(for: CGRect(origin: line.end, size: .zero), imageWidth: imageWidth).origin)
    }

    private func drawGradientHandles(_ line: LinearGradient, imageWidth: Int, in context: CGContext) {
        let centers = gradientHandleCenters(line, imageWidth: imageWidth)
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        for center in [centers.start, centers.end] {
            let handle = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.fillEllipse(in: handle)
            context.strokeEllipse(in: handle)
        }
        context.restoreGState()
    }

    private func drawFloodHandle(at seed: CGPoint, frame: CGRect, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.move(to: seed)
        context.addLine(to: frame.center)
        context.strokePath()
        let dot = CGRect(x: seed.x - 2, y: seed.y - 2, width: 4, height: 4)
        context.fill(dot)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(dot)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(frame)
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(frame)
        Self.floodHandleIcon?.draw(in: frame.insetBy(dx: 3, dy: 3))
        context.restoreGState()
    }

    private func rotateDrawing(around marquee: CGRect, by angle: CGFloat, in context: CGContext) {
        guard angle != 0 else { return }
        context.translateBy(x: marquee.midX, y: marquee.midY)
        context.rotate(by: angle)
        context.translateBy(x: -marquee.midX, y: -marquee.midY)
    }

    private func drawTransformHandles(around marquee: CGRect, angle: CGFloat, pivot: CGPoint, in context: CGContext) {
        context.saveGState()
        rotateDrawing(around: marquee, by: angle, in: context)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        for handle in ResizeHandle.all {
            let frame = handle.frame(in: marquee)
            context.fill(frame)
            context.stroke(frame)
        }
        context.restoreGState()
        context.saveGState()
        let pivotFrame = CGRect(x: pivot.x - 5, y: pivot.y - 5, width: 10, height: 10)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1)
        context.fillEllipse(in: pivotFrame)
        context.strokeEllipse(in: pivotFrame)
        context.move(to: CGPoint(x: pivot.x - 3, y: pivot.y))
        context.addLine(to: CGPoint(x: pivot.x + 3, y: pivot.y))
        context.move(to: CGPoint(x: pivot.x, y: pivot.y - 3))
        context.addLine(to: CGPoint(x: pivot.x, y: pivot.y + 3))
        context.strokePath()
        context.restoreGState()
    }
}

private extension CanvasView {
    func toolForKey(_ shortcut: String, reverse: Bool) -> Tool? {
        switch shortcut {
        case "b": return .brush
        case "e": return .eraser
        case "f": return .paintBucket
        case "g": return .gradient
        case "h": return .pan
        case "k": return .colorPicker
        case "l": return .cloneStamp
        case "m": return reverse || tool == .moveSelectedPixels ? .moveSelection : .moveSelectedPixels
        case "o": return reverse || tool == .lineCurve ? .shapes : .lineCurve
        case "p": return .pencil
        case "r": return .recolor
        case "s":
            let group: [Tool] = [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand]
            let current = group.firstIndex(of: tool) ?? (reverse ? 0 : group.count - 1)
            return group[(current + group.count + (reverse ? -1 : 1)) % group.count]
        case "t": return .text
        case "z": return .zoom
        default: return nil
        }
    }

    func beginToolGesture(with event: NSEvent, secondary: Bool) {
        guard panDrag == nil, drawingDrag == nil, rasterDrawing == nil,
              let stack = document?.stack, layerPreview == nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        if textEditor == nil { window?.makeFirstResponder(self) }
        updateBrushCursor(at: event.locationInWindow)
        if tool == .zoom {
            stepZoom(secondary ? -1 : 1, at: event.locationInWindow)
            return
        }
        guard !imageRect.isEmpty else { return }
        let point = imagePoint(location)
        if let draft = drawingDraft {
            let handles = drawingHandles(for: draft.geometry, width: stack.activeLayer.image.width)
                .filter { $0.frame.insetBy(dx: -2, dy: -2).contains(location) }
            let nearest = handles.min { first, second in
                let a = first.frame.center - location, b = second.frame.center - location
                return hypot(a.x, a.y) < hypot(b.x, b.y)
            }
            if let handle = nearest {
                if case .line = draft.geometry, handle.index == 1 || handle.index == 2 { drawingStyle.curve = true }
                drawingDrag = (point, .handle(handle.index), draft.geometry)
                focusTextInput()
                return
            }
            if secondary && tool != .text {
                drawingDrag = (point, .rotate, draft.geometry)
                return
            }
            if draft.geometry.shapeContains(point) {
                drawingDrag = (point, .move, draft.geometry)
                return
            }
        }
        if tool == .text && secondary { return }
        guard imageRect.contains(location) else {
            finishDrawing()
            return
        }
        if tool == .colorPicker {
            let composite = pickerSampling == .image || event.modifierFlags.contains(.control)
            guard let source = composite ? stack.flattenedLayer() : stack.activeLayer,
                  let color = DrawingColor.pick(from: source, at: point, sampleSize: pickerSampleSize) else { return }
            if secondary { secondaryColor = color } else { brushColor = color }
            colorDidPick?(color, secondary)
            if pickerAfter == .previous { selectTool?(previousTool) }
            if pickerAfter == .pencil { selectTool?(.pencil) }
            return
        }
        guard stack.activeLayer.isVisible else { NSSound.beep(); return }
        if tool.usesRasterDrawing {
            beginRasterDrawing(on: stack, at: point, secondary: secondary, event: event)
        } else {
            finishDrawing()
            let geometry: VectorDrawing
            switch tool {
            case .lineCurve: geometry = .line(Array(repeating: point, count: 4))
            case .shapes: geometry = .shape(CGRect(origin: point, size: .zero))
            default:
                drawingStyle.text = ""
                geometry = .text(point)
            }
            drawingDraft = (geometry, secondary, nil)
            if tool == .text { beginTextInput() }
            else { drawingDrag = (point, .create, geometry) }
            updateDrawingPreview()
        }
    }

    private func beginRasterDrawing(on stack: LayerStack, at point: CGPoint, secondary: Bool, event: NSEvent) {
        let layer = stack.activeLayer
        let primary = DrawingColor(secondary ? secondaryColor : brushColor, in: layer.workingColorSpace)
        let alternate = DrawingColor(secondary ? brushColor : secondaryColor, in: layer.workingColorSpace)
        let operation: RasterDrawing.Operation
        switch tool {
        case .brush: operation = .paint(primary: primary, secondary: alternate)
        case .eraser: operation = .erase(opacity: primary.alpha)
        case .pencil: operation = .pencil(primary)
        case .recolor: operation = .recolor(from: alternate, to: primary, tolerance: recolorTolerance)
        case .cloneStamp:
            let pixel = CGPoint(x: floor(point.x), y: floor(point.y))
            if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
                cloneSource = (pixel, stack.active)
                cloneOffset = nil
                needsDisplay = true
                return
            }
            guard let source = cloneSource, stack.layers.indices.contains(source.layer) else { NSSound.beep(); return }
            let sourceLayer = stack.layers[source.layer]
            guard let raw = sourceLayer.straightPixels,
                  let pixels = BGRA8.converted(raw, width: sourceLayer.image.width, height: sourceLayer.image.height,
                                               from: sourceLayer.workingColorSpace, to: layer.workingColorSpace)
            else { NSSound.beep(); return }
            let offset = cloneOffset ?? source.point - pixel
            cloneOffset = offset
            cloneCursor = pixel + offset
            operation = .clone(source: pixels, offset: offset, opacity: primary.alpha)
        default: return
        }
        drawingWithSecondaryButton = secondary
        lastTabletPressure = nil
        rasterDrawing = RasterDrawing(layer: layer, operation: operation, diameter: brushSize,
                                      selection: selectionOutline, options: brushOptions)
        if let rasterDrawing {
            rasterDrawing.append(point, pressure: pressure(for: event))
            invalidateRasterDrawing(rasterDrawing)
        }
        if tool == .cloneStamp { needsDisplay = true }
    }

    private func invalidateRasterDrawing(_ drawing: RasterDrawing) {
        let region = drawing.takeDirtyBounds()
        guard !region.isEmpty, let stack = document?.stack else { return }
        metalStrokeRevision &+= 1
        metalStrokeDirty = metalStrokeDirty.union(region)
        if composite == nil { composite = CanvasComposite(stack: stack) }
        composite?.invalidate(region)
        setNeedsDisplay(viewRegion(for: region, image: stack.activeLayer.image).insetBy(dx: -2, dy: -2))
    }

    private func pressure(for event: NSEvent) -> CGFloat {
        if event.subtype == .tabletPoint {
            noticeTablet()
            // On a lift event the tablet can report zero even though the last contact had pressure.
            let lifted = event.type == .leftMouseUp || event.type == .rightMouseUp
            if !lifted || event.pressure > 0 {
                lastTabletPressure = CGFloat(event.pressure)
            }
        }
        return lastTabletPressure ?? 1
    }

    private func matchesDrawingButton(_ event: NSEvent) -> Bool {
        drawingWithSecondaryButton == (event.type == .rightMouseDragged || event.type == .rightMouseUp)
    }

    func updateToolGesture(with event: NSEvent) -> Bool {
        updateBrushCursor(at: event.locationInWindow)
        guard !imageRect.isEmpty else { return false }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        if let rasterDrawing {
            guard matchesDrawingButton(event) else { return true }
            rasterDrawing.append(point, pressure: pressure(for: event))
            invalidateRasterDrawing(rasterDrawing)
            if tool == .cloneStamp, let cloneOffset {
                cloneCursor = point + cloneOffset
                needsDisplay = true
            }
            return true
        }
        guard let drag = drawingDrag else { return false }
        let anchor = drag.anchor
        let delta = point - anchor
        let shift = event.modifierFlags.contains(.shift)
        let centered = event.modifierFlags.contains(.option)
        let handle: Int?
        switch drag.mode {
        case .create: handle = nil
        case .handle(let index): handle = index
        case .move:
            drawingDraft?.geometry = drag.initial.translated(by: delta)
            updateDrawingPreview()
            return true
        case .rotate:
            let pivot = drag.initial.center
            let start = anchor - pivot, end = point - pivot
            var angle = atan2(end.y, end.x) - atan2(start.y, start.x)
            if shift { angle = (angle / (.pi / 12)).rounded() * .pi / 12 }
            drawingDraft?.geometry = drag.initial.rotated(by: angle)
            updateDrawingPreview()
            return true
        }
        var end = point
        let geometry: VectorDrawing
        switch drag.initial {
        case .line(var points):
            if let handle {
                points[handle] = points[handle] + delta
                if !drawingStyle.curve {
                    points = lineControls(from: points[0], to: points[3])
                }
            } else {
                if shift {
                    let angle = (atan2(delta.y, delta.x) / (.pi / 12)).rounded() * .pi / 12
                    let distance = hypot(delta.x, delta.y)
                    end = anchor + CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
                }
                points = lineControls(from: centered ? anchor - (end - anchor) : anchor, to: end)
            }
            geometry = .line(points)
        case .shape(let rect, let angle):
            let handles = VectorDrawing.shape(rect).handles
            let opposite = handle.map { handles[($0 + 2) % 4] } ?? anchor
            if let handle { end = handles[handle] + delta.rotated(by: -angle) }
            let base = centered && handle != nil ? rect.center : opposite
            if shift {
                let difference = end - base
                let ratio = rect.isEmpty ? 1 : rect.width / rect.height
                let height = max(abs(difference.x) / ratio, abs(difference.y))
                end = base + CGPoint(x: (difference.x < 0 ? -1 : 1) * height * ratio,
                                     y: (difference.y < 0 ? -1 : 1) * height)
            }
            let start = centered ? base - (end - base) : base
            let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                width: abs(end.x - start.x), height: abs(end.y - start.y))
            let shift = bounds.center - rect.center
            let offset = shift.rotated(by: angle) - shift
            geometry = .shape(bounds.offsetBy(dx: offset.x, dy: offset.y), angle: angle)
        case .text: geometry = drag.initial.translated(by: delta)
        }
        drawingDraft?.geometry = geometry
        updateDrawingPreview()
        return true
    }

    func lineControls(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let dx = (end.x - start.x) / 3, dy = (end.y - start.y) / 3
        return [start, CGPoint(x: start.x + dx, y: start.y + dy), CGPoint(x: end.x - dx, y: end.y - dy), end]
    }

    func endToolGesture(with event: NSEvent) -> Bool {
        if rasterDrawing != nil && !matchesDrawingButton(event) { return true }
        guard updateToolGesture(with: event) else { return false }
        if let rasterDrawing {
            rasterDrawing.finish()
            invalidateRasterDrawing(rasterDrawing)
            let preview = rasterDrawing.preview
            self.rasterDrawing = nil
            cloneCursor = nil
            if let preview {
                let updatedComposite = composite
                if let pixels = preview.pdnPixels { updatedComposite?.commitActivePixels(pixels) }
                document?.commitRasterDrawing(rasterDrawing, layer: preview)
                composite = updatedComposite
            }
        }
        drawingDrag = nil
        needsDisplay = true
        return true
    }

    func updateDrawingPreview() {
        guard let draft = drawingDraft, let layer = document?.stack?.activeLayer else { return }
        var style = drawingStyle
        style.primary = draft.secondary ? secondaryColor : brushColor
        style.secondary = draft.secondary ? brushColor : secondaryColor
        style.width = brushSize
        if case .text(let origin) = draft.geometry {
            style.textResolution = imageResolution
            let layout = TextLayout(origin: origin, style: style)
            textLayout = layout
            window?.invalidateCursorRects(for: self)
            drawingDraft?.preview = layout.applying(to: layer, selection: selectionOutline, style: style)
        } else {
            drawingDraft?.preview = draft.geometry.applying(to: layer, selection: selectionOutline, style: style)
        }
        composite = nil
        needsDisplay = true
        selectionDidChange?()
    }

    func finishDrawing() {
        guard let draft = drawingDraft else { return }
        drawingDraft = nil
        drawingDrag = nil
        endTextInput()
        composite = nil
        let action: String
        switch draft.geometry {
        case .line: action = "Line / Curve"
        case .shape: action = "Shapes"
        case .text: action = "Text"
        }
        if let preview = draft.preview { document?.commitPaintLayer(preview, actionName: action) }
        needsDisplay = true
        selectionDidChange?()
    }

    func drawingHandles(for drawing: VectorDrawing, width: Int) -> [(index: Int, frame: CGRect)] {
        if case .text = drawing, let frame = textHandleFrame(imageWidth: width) {
            return [(0, frame)]
        }
        return drawing.handles.enumerated().map { index, point in
            let center = marquee(for: CGRect(origin: point, size: .zero), imageWidth: width).origin
            return (index, CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        }
    }

    func drawDrawingHandles(imageWidth: Int, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        if textEditor != nil {
            drawTextControls(imageWidth: imageWidth, in: context)
        } else if let geometry = drawingDraft?.geometry {
            for handle in drawingHandles(for: geometry, width: imageWidth) {
                context.fillEllipse(in: handle.frame)
                context.strokeEllipse(in: handle.frame)
            }
        }
        if tool == .cloneStamp, let source = cloneCursor ?? cloneSource?.point, !imageRect.isEmpty {
            let center = marquee(for: CGRect(origin: source, size: .zero), imageWidth: imageWidth).origin
            let radius = max(4, brushSize * imageRect.width / CGFloat(imageWidth) / 2)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    func rotated(by angle: CGFloat) -> CGPoint {
        applying(CGAffineTransform(rotationAngle: angle))
    }
}

extension CanvasView {
    private func beginTextInput() {
        let input = CanvasTextInput()
        input.delegate = self
        input.finish = { [weak self] in self?.finishDrawing() }
        input.nudgeHandle = { [weak self] event in self?.nudgeTextHandle(with: event) ?? false }
        input.screenRect = { [weak self] index in
            guard let self, let window, let caret = textCaretFrame(at: index) else { return .zero }
            return window.convertToScreen(convert(caret, to: nil))
        }
        input.indexAtScreenPoint = { [weak self] point in
            guard let self, let window, let textLayout else { return NSNotFound }
            let location = convert(window.convertPoint(fromScreen: point), from: nil)
            return textLayout.characterIndex(at: imagePoint(location))
        }
        addSubview(input)
        textEditor = input
        focusTextInput()
        textCaretVisible = true
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.textCaretVisible.toggle()
            self.invalidateTextBlink()
        }
        RunLoop.main.add(timer, forMode: .common)
        textBlinkTimer = timer
    }

    private func endTextInput() {
        guard let input = textEditor else { return }
        textEditor = nil
        textLayout = nil
        textBlinkTimer?.invalidate()
        textBlinkTimer = nil
        input.delegate = nil
        if window?.firstResponder === input { window?.makeFirstResponder(self) }
        input.removeFromSuperview()
        window?.invalidateCursorRects(for: self)
    }

    func textDidChange(_ notification: Notification) {
        guard let input = notification.object as? CanvasTextInput, input === textEditor else { return }
        drawingStyle.text = input.string
        updateTextCaret()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let input = notification.object as? CanvasTextInput, input === textEditor else { return }
        updateTextCaret()
    }

    private func updateTextCaret() {
        textCaretVisible = true
        window?.invalidateCursorRects(for: self)
        invalidateTextControls()
        guard drawingDrag == nil, let input = textEditor, let caret = textCaretFrame(at: NSMaxRange(input.selectedRange())),
              imageRect.intersects(caret) else { return }
        scrollToVisible(caret.insetBy(dx: -12, dy: -8).intersection(imageRect))
    }

    private func invalidateTextBlink() {
        guard let input = textEditor, let width = document?.image?.width else { return }
        if let overlay = metalOverlay, !overlay.isHidden {
            overlay.needsDisplay = true
        } else {
            if input.selectedRange().length == 0, let caret = textCaretFrame(at: input.selectedRange().location) {
                setNeedsDisplay(caret.insetBy(dx: -2, dy: -2))
            }
            if let handle = textHandleFrame(imageWidth: width) {
                setNeedsDisplay(handle.insetBy(dx: -1, dy: -1))
            }
        }
    }

    private func invalidateTextControls() {
        if let overlay = metalOverlay, !overlay.isHidden { overlay.needsDisplay = true }
        else { needsDisplay = true }
    }

    private func textCaretFrame(at index: Int) -> CGRect? {
        guard let textLayout, let image = document?.image else { return nil }
        let caret = marquee(for: textLayout.caret(at: index), imageWidth: image.width)
        return CGRect(x: caret.minX, y: caret.minY, width: 1, height: max(1, caret.height))
    }

    func textHandleFrame(imageWidth: Int) -> CGRect? {
        guard let input = textEditor, let textLayout else { return nil }
        let caret = marquee(for: textLayout.caret(at: NSMaxRange(input.selectedRange())), imageWidth: imageWidth)
        let viewport = visibleRect.insetBy(dx: 2, dy: 2)
        let x = max(viewport.minX, min(viewport.maxX - 16, caret.minX + 6))
        let y = max(viewport.minY, min(viewport.maxY - 16, caret.minY - 18))
        return CGRect(x: x, y: y, width: 16, height: 16)
    }

    private func nudgeTextHandle(with event: NSEvent) -> Bool {
        guard let drag = drawingDrag, let draft = drawingDraft, let delta = nudge(for: event) else { return false }
        drawingDrag = (drag.anchor, drag.mode, drag.initial.translated(by: delta))
        drawingDraft?.geometry = draft.geometry.translated(by: delta)
        updateDrawingPreview()
        return true
    }

    private func drawTextControls(imageWidth: Int, in context: CGContext) {
        guard let input = textEditor, let layout = textLayout else { return }
        let selected = input.selectedRange()
        context.saveGState()
        context.clip(to: imageRect)
        if selected.length > 0 {
            context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).cgColor)
            for rect in layout.selectionRects(for: selected) {
                context.fill(marquee(for: rect, imageWidth: imageWidth))
            }
        } else if textCaretVisible, let caret = textCaretFrame(at: selected.location) {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(caret.insetBy(dx: -1, dy: -1))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(caret)
        }
        if input.hasMarkedText() {
            context.setFillColor(NSColor.keyboardFocusIndicatorColor.cgColor)
            for rect in layout.selectionRects(for: input.markedRange()) {
                let frame = marquee(for: rect, imageWidth: imageWidth)
                context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1))
            }
        }
        context.restoreGState()
        if let frame = textHandleFrame(imageWidth: imageWidth) {
            context.setFillColor(NSColor.white.withAlphaComponent(textCaretVisible ? 1 : 0.65).cgColor)
            context.fill(frame)
            context.setStrokeColor(NSColor.black.cgColor)
            context.stroke(frame)
            Self.floodHandleIcon?.draw(in: frame.insetBy(dx: 2, dy: 2))
        }
    }
}
