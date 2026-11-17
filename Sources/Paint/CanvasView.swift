import AppKit

final class CanvasView: NSView {
    enum Tool {
        case brush, eraser, rectangleSelect, ellipseSelect, lassoSelect, moveSelectedPixels, moveSelection

        var selectionName: String? {
            switch self {
            case .rectangleSelect: return "Rectangle Select"
            case .ellipseSelect: return "Ellipse Select"
            case .lassoSelect: return "Lasso Select"
            default: return nil
            }
        }
        var drawsSelection: Bool { selectionName != nil }
        var transformsSelection: Bool { self == .moveSelectedPixels || self == .moveSelection }
    }

    private struct SelectionDrag {
        let anchor: CGPoint
        var end: CGPoint
        let before: SelectionOutline?
        let mode: SelectionOutline.Mode
        let lassoPath: CGMutablePath?
    }

    struct MoveGeometry: Equatable {
        var rect: CGRect
        var pivot: CGPoint
        var angle: CGFloat = 0
        var flipX = false
        var flipY = false
    }

    struct MoveSession {
        let layerIndex: Int
        let pixels: SelectedPixelsTransform?
        let outline: SelectionOutline
        let source: CGRect
        var geometry: MoveGeometry
        var copy = false
        var preview: PaintLayer?
        var actionName = "Move Selected Pixels"
        var recorded = false

        var isPaste: Bool { pixels?.isPaste == true }
        var changed: Bool { isPaste || geometry.rect != source || geometry.angle != 0 || geometry.flipX || geometry.flipY }

        var transformedOutline: SelectionOutline? {
            let transform = CGAffineTransform(translationX: geometry.rect.midX, y: geometry.rect.midY)
                .rotated(by: geometry.angle)
                .scaledBy(x: (geometry.flipX ? -1 : 1) * geometry.rect.width / source.width,
                          y: (geometry.flipY ? -1 : 1) * geometry.rect.height / source.height)
                .translatedBy(x: -source.midX, y: -source.midY)
            return outline.transformed(by: transform)
        }
    }

    private struct MoveDrag {
        let before: MoveSession?
        let geometry: MoveGeometry
        let anchor: CGPoint
        let handle: TransformHandle
        let rightButton: Bool
        var lastPoint: CGPoint
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

    private static let zoomSteps: [CGFloat] = [
        1, 2, 3, 5, 6, 8, 12.5, 16, 25, 33, 50, 66, 75, 100, 150, 200, 300, 400, 500,
        600, 800, 1000, 1200, 1400, 1600, 2000, 2400, 2800, 3200, 4000, 4800, 5600, 6400,
        8000, 10000
    ]
    private static let rotationCursor: NSCursor = {
        guard let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rotate Selected Pixels") else {
            return .crosshair
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
    }()

    private weak var document: PaintDocument?
    var tool = Tool.brush {
        willSet {
            if newValue != tool {
                cancelSelectionDrag()
                finishMove()
            }
        }
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            selectionDidChange?()
        }
    }
    private(set) var zoomPercent: CGFloat?
    private(set) var displayedZoomPercent: CGFloat = 0
    var zoomDidChange: (() -> Void)?
    var brushColor = NSColor.black
    var brushSize: CGFloat = 12
    var selectionDidChange: (() -> Void)?
    var selectTransformTool: ((Tool) -> Void)?
    var layerPreview: LayerStack? {
        didSet {
            composite = nil
            needsDisplay = true
        }
    }
    private var composite: CGImage?

    private(set) var selectionOutline: SelectionOutline?
    var selectionMode: SelectionOutline.Mode = .replace
    var selection: CGRect { selectionOutline?.bounds.integral ?? .zero }
    private var selectionDrag: SelectionDrag?

    private var stroke: (bitmap: CGContext, lastPoint: CGPoint, actionName: String, imageSelection: CGRect?)?
    private(set) var move: MoveSession?
    private var moveDrag: MoveDrag?
    private var cursorTracking: NSTrackingArea?
    private var panLocation: CGPoint?
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
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        panLocation = nil
        cancelEditingGesture()
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        completeMoveDrag()
        cancelSelectionDrag()
        guard panLocation != nil else { return }
        panLocation = nil
        window?.invalidateCursorRects(for: self)
    }

    private func scroll(to origin: CGPoint, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let proposedBounds = CGRect(origin: origin, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposedBounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func resetCursorRects() {
        if panLocation != nil {
            addCursorRect(visibleRect, cursor: .closedHand)
        } else if !tool.transformsSelection && !imageRect.isEmpty {
            addCursorRect(imageRect, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        cursorTracking = tracking
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        if tool.transformsSelection { updateMoveCursor(at: convert(event.locationInWindow, from: nil)) }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if tool.transformsSelection { updateMoveCursor(at: convert(event.locationInWindow, from: nil)) }
        else { super.mouseMoved(with: event) }
    }

    private func updateMoveCursor(at location: CGPoint) {
        guard let layer = document?.stack?.activeLayer, !imageRect.isEmpty,
              tool == .moveSelection ? selectionOutline != nil : layer.isVisible else {
            NSCursor.arrow.set()
            return
        }
        if panLocation != nil {
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
        guard !imageRect.isEmpty, stroke == nil, selectionDrag == nil, moveDrag == nil, panLocation == nil,
              let scrollView = enclosingScrollView else { return }

        let steps: Int
        if event.hasPreciseScrollingDeltas {
            let pointsPerStep: CGFloat = 24
            zoomScrollDistance += event.scrollingDeltaY
            steps = Int(zoomScrollDistance / pointsPerStep)
            zoomScrollDistance -= CGFloat(steps) * pointsPerStep
        } else {
            steps = Int(event.scrollingDeltaY.rounded(.awayFromZero))
        }
        guard steps != 0 else { return }

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

        let pointer = convert(event.locationInWindow, from: nil)
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
        guard !imageRect.isEmpty, stroke == nil, selectionDrag == nil, moveDrag == nil else { return }
        panLocation = event.locationInWindow
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        guard let lastLocation = panLocation, let scrollView = enclosingScrollView else { return }
        let last = convert(lastLocation, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        let origin = scrollView.contentView.bounds.origin
        panLocation = event.locationInWindow
        scroll(to: CGPoint(x: origin.x + last.x - current.x, y: origin.y + last.y - current.y), in: scrollView)
        NSCursor.closedHand.set()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard panLocation != nil else { return }
        otherMouseDragged(with: event)
        panLocation = nil
        let location = convert(event.locationInWindow, from: nil)
        if tool.transformsSelection && visibleRect.contains(location) {
            updateMoveCursor(at: location)
        } else if visibleRect.contains(location) && imageRect.contains(location) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
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

    private func updateSelectionDrag(in image: CGImage, modifiers: NSEvent.ModifierFlags) {
        guard let drag = selectionDrag else { return }
        let outline: SelectionOutline?
        if let path = drag.lassoPath?.mutableCopy() {
            path.closeSubpath()
            outline = SelectionOutline(path: path.normalized(using: .evenOdd))
        } else {
            outline = shapeSelection(from: drag.anchor, to: drag.end, modifiers: modifiers)
        }
        let clipped = outline?.clipped(to: canvasBounds(for: image))
        setSelection(drag.mode.applying(clipped, to: drag.before))
    }

    private func shapeSelection(from anchor: CGPoint, to end: CGPoint,
                                modifiers: NSEvent.ModifierFlags) -> SelectionOutline? {
        let rect = CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                          width: abs(anchor.x - end.x), height: abs(anchor.y - end.y))
        guard tool == .ellipseSelect else { return SelectionOutline(rect: rect) }
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

    var copyableLayer: PaintLayer? { move?.preview ?? document?.stack?.activeLayer }
    var canCopyPixels: Bool {
        copyableLayer != nil && (copyableOutline != nil || (selectionOutline == nil && move?.isPaste != true))
    }

    func pastePixels(_ pastedImage: CGImage) {
        guard let document, let stack = document.stack, let layer = copyableLayer,
              layer.isVisible, layerPreview == nil else { return }
        let corner: CGPoint
        if selectionOutline != nil || move?.isPaste == true, let bounds = copyableOutline?.bounds.integral {
            corner = CGPoint(x: bounds.minX, y: bounds.maxY)
        } else {
            let visible = imageRect.intersection(visibleRect)
            corner = visible.isEmpty ? CGPoint(x: 0, y: layer.image.height)
                : pixelEdge(at: CGPoint(x: visible.minX, y: visible.maxY), in: layer.image)
        }
        let rect = CGRect(x: corner.x, y: corner.y - CGFloat(pastedImage.height),
                          width: CGFloat(pastedImage.width), height: CGFloat(pastedImage.height))
        let destination = topLeftRect(rect, imageHeight: layer.image.height)
        guard let outline = SelectionOutline(rect: rect),
              let pixels = SelectedPixelsTransform(layer: layer, pastedImage: pastedImage, at: destination),
              let preview = pixels.transformed(to: destination) else { return }

        finishMove()
        let session = MoveSession(layerIndex: stack.active, pixels: pixels, outline: outline, source: rect,
                                  geometry: MoveGeometry(rect: rect, pivot: rect.center), preview: preview, recorded: true)
        document.recordMove(from: nil, to: session, actionName: "Paste")
        window?.makeFirstResponder(self)
    }

    func cancelEditingGesture() {
        stroke = nil
        cancelSelectionDrag()
        if let drag = moveDrag {
            moveDrag = nil
            move = drag.before
        }
        composite = nil
        needsDisplay = true
        selectionDidChange?()
    }

    var hasPendingMove: Bool { move?.recorded == true || move?.changed == true }
    var hasPendingPixelMove: Bool { move?.preview != nil }
    var rotationDegrees: CGFloat? { move.map { $0.geometry.angle * 180 / .pi } }

    func restoreMove(_ session: MoveSession?) {
        move = nil
        if let session {
            let transformTool: Tool = session.pixels == nil ? .moveSelection : .moveSelectedPixels
            if tool != transformTool {
                if let selectTransformTool { selectTransformTool(transformTool) }
                else { tool = transformTool }
            }
        }
        move = session
        composite = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        selectionDidChange?()
    }

    func finishMove() {
        completeMoveDrag()
        guard let session = move, let image = document?.image else { return }
        guard session.recorded else {
            restoreMove(nil)
            return
        }
        let keepsOutline = session.isPaste || selectionOutline != nil
        let destination = keepsOutline ? session.transformedOutline?.clipped(to: canvasBounds(for: image)) : nil
        document?.commitSelectedPixelsTransform(session.preview, to: destination, actionName: "Finish Selection")
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
        let isEscape = event.keyCode == 53
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let deselects = (isEscape || isReturn) && (move != nil || !selection.isEmpty || selectionDrag != nil)
        if event.isARepeat && (isEscape || deselects) { return }
        if !event.isARepeat, event.charactersIgnoringModifiers?.lowercased() == "m",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let selectTransformTool {
            let outline = event.modifierFlags.contains(.shift) || tool == .moveSelectedPixels
            selectTransformTool(outline ? .moveSelection : .moveSelectedPixels)
        } else if deselects {
            document?.deselect(nil)
        } else if tool.transformsSelection, let delta = nudge(for: event), moveDrag == nil,
                  let stack = document?.stack {
            let before = move
            if beginMove(on: stack) {
                let image = stack.activeLayer.image
                let geometry = moveGeometry(for: image)
                updateMove(with: translated(geometry, by: delta), actionName: "Move Selected Pixels",
                           copy: false, imageHeight: image.height)
                recordMove(from: before, geometry: geometry)
            } else {
                super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
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
            let region = topLeftRect(geometry.rect, imageHeight: height)
            let mask = outline.pixelRectangle ? nil : outline.mask(in: region, imageHeight: height)
            guard outline.pixelRectangle || mask != nil,
                  let transform = SelectedPixelsTransform(layer: layer, selection: region, mask: mask) else { return false }
            pixels = transform
        }
        move = MoveSession(layerIndex: stack.active, pixels: pixels, outline: outline,
                           source: geometry.rect, geometry: geometry)
        return true
    }

    private func beginMoveDrag(with event: NSEvent, rightButton: Bool) {
        let before = move
        guard panLocation == nil, moveDrag == nil, let stack = document?.stack else { return }
        let location = convert(event.locationInWindow, from: nil)
        let handle = rightButton ? .rotate : transformHandle(at: location, layer: stack.activeLayer)
        guard beginMove(on: stack) else { return }
        window?.makeFirstResponder(self)
        let point = imagePoint(location)
        moveDrag = MoveDrag(before: before, geometry: moveGeometry(for: stack.activeLayer.image), anchor: point,
                            handle: handle, rightButton: rightButton, lastPoint: point)
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
        moveDrag?.lastPoint = point
        updateMoveDrag(at: point, modifiers: event.modifierFlags)
    }

    private func updateMoveDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let drag = moveDrag, let image = document?.image else { return }
        let delta = point - drag.anchor
        var geometry = drag.geometry
        let actionName: String
        switch drag.handle {
        case .pivot:
            move?.geometry.pivot = geometry.pivot + delta
            needsDisplay = true
            return
        case .move:
            geometry = translated(geometry, by: CGPoint(x: delta.x.rounded(), y: delta.y.rounded()))
            actionName = "Move Selected Pixels"
        case .resize(let handle):
            geometry = handle.resized(geometry, delta: delta, proportional: modifiers.contains(.shift),
                                      centered: modifiers.contains(.option))
            actionName = "Resize Selected Pixels"
        case .rotate:
            let from = drag.anchor - geometry.pivot, to = point - geometry.pivot
            guard from != .zero, to != .zero else { return }
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
        let copy = !modifiers.intersection([.control, .command]).isEmpty
        updateMove(with: geometry, actionName: actionName, copy: copy, imageHeight: image.height)
    }

    private func updateMove(with geometry: MoveGeometry, actionName: String, copy: Bool, imageHeight: Int) {
        guard var session = move else { return }
        let keepSource = session.copy || copy
        guard session.geometry != geometry || session.copy != keepSource else { return }
        session.geometry = geometry
        if session.changed, let pixels = session.pixels {
            let destination = topLeftRect(geometry.rect, imageHeight: imageHeight)
            guard let preview = pixels.transformed(to: destination, rotation: geometry.angle,
                                                           flipX: geometry.flipX, flipY: geometry.flipY,
                                                           copy: keepSource) else { return }
            session.preview = preview
        } else {
            session.preview = nil
        }
        session.copy = keepSource
        session.actionName = tool == .moveSelection ? "Transform Selection" : actionName
        move = session
        composite = nil
        needsDisplay = true
        selectionDidChange?()
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
            if let session = move, !session.recorded, session.geometry.pivot == session.source.center {
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
        if tool.transformsSelection { beginMoveDrag(with: event, rightButton: true) }
        else { super.rightMouseDown(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if tool.transformsSelection { updateMoveDrag(with: event, rightButton: true) }
        else { super.rightMouseDragged(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if tool.transformsSelection { endMoveDrag(with: event, rightButton: true) }
        else { super.rightMouseUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if let point = moveDrag?.lastPoint { updateMoveDrag(at: point, modifiers: event.modifierFlags) }
        if tool == .ellipseSelect, selectionDrag != nil, let image = document?.image {
            updateSelectionDrag(in: image, modifiers: event.modifierFlags)
        }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard panLocation == nil else { return }
        if tool.transformsSelection {
            beginMoveDrag(with: event, rightButton: false)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(location), let image = document?.image else {
            if tool.drawsSelection { document?.deselect(nil) }
            return
        }

        window?.makeFirstResponder(self)
        if tool.drawsSelection {
            let anchor = pixelEdge(at: location, in: image)
            let path = tool == .lassoSelect ? CGMutablePath() : nil
            path?.move(to: anchor)
            selectionDrag = SelectionDrag(anchor: anchor, end: anchor, before: selectionOutline,
                                          mode: selectionMode, lassoPath: path)
            if selectionMode == .replace { setSelection(nil) }
            return
        }
        guard document?.stack?.activeLayer.isVisible == true else {
            NSSound.beep()
            return
        }
        guard let bitmap = LayerStack.makeBitmap(width: image.width, height: image.height) else { return }
        let isErasing = tool == .eraser
        bitmap.setBlendMode(.copy)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let selectionOutline {
            bitmap.addPath(selectionOutline.path)
            bitmap.clip(using: .evenOdd)
        }
        bitmap.setBlendMode(isErasing ? .clear : .normal)
        let color = (brushColor.usingColorSpace(.sRGB) ?? .black).withAlphaComponent(1).cgColor
        bitmap.setFillColor(color)
        bitmap.setStrokeColor(color)
        bitmap.setLineCap(.round)
        bitmap.setLineWidth(brushSize)

        let point = imagePoint(location)
        bitmap.fillEllipse(in: CGRect(x: point.x - brushSize / 2, y: point.y - brushSize / 2,
                                     width: brushSize, height: brushSize))
        stroke = (bitmap, point, isErasing ? "Eraser" : "Paintbrush", imageSelection)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !imageRect.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        if var drag = selectionDrag, let image = document?.image {
            let point = imagePoint(location)
            let end = drag.lassoPath == nil ? pixelEdge(at: location, in: image)
                : CGPoint(x: point.x.rounded(), y: point.y.rounded())
            if end != drag.end {
                drag.lassoPath?.addLine(to: end)
                drag.end = end
                selectionDrag = drag
            }
            updateSelectionDrag(in: image, modifiers: event.modifierFlags)
            return
        }
        if moveDrag != nil {
            updateMoveDrag(with: event, rightButton: false)
            return
        }
        guard let current = stroke else { return }
        let point = imagePoint(location)
        guard point != current.lastPoint else { return }
        current.bitmap.move(to: current.lastPoint)
        current.bitmap.addLine(to: point)
        current.bitmap.strokePath()
        stroke?.lastPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moveDrag != nil {
            endMoveDrag(with: event, rightButton: false)
            return
        }
        mouseDragged(with: event)
        if let drag = selectionDrag, let name = tool.selectionName {
            let outline = selectionOutline
            cancelSelectionDrag()
            let actionName = drag.mode == .replace ? (outline == nil ? "Deselect" : name) : "\(name) (\(drag.mode.rawValue))"
            document?.commitSelection(outline, actionName: actionName)
            return
        }
        guard let current = stroke else { return }
        stroke = nil
        if let image = current.bitmap.makeImage() {
            document?.replaceImage(with: image, actionName: current.actionName, in: current.imageSelection)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.gray.withAlphaComponent(0.22).setFill()
        dirtyRect.fill()
        let rect = imageRect
        let visible = rect.intersection(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              var stack = layerPreview ?? document?.stack else { return }
        if let preview = move?.preview { stack.layers[stack.active] = preview }
        let image = stack.activeLayer.image
        let showsHandles = showsTransformHandles(on: stack.activeLayer)
        let geometry = moveGeometry(for: image)
        let marquee = marquee(for: showsHandles ? geometry.rect : selection, imageWidth: image.width)
        defer {
            if showsHandles && !marquee.isEmpty {
                let pivot = self.marquee(for: CGRect(origin: geometry.pivot, size: .zero), imageWidth: image.width).origin
                drawTransformHandles(around: marquee, angle: geometry.angle, pivot: pivot, in: context)
            }
        }
        guard !visible.isEmpty else { return }

        context.saveGState()
        context.clip(to: rect)
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
        if displayedZoomPercent >= 100 {
            context.interpolationQuality = .none
        }
        let strokeImage = stroke?.bitmap.makeImage()
        if stack.needsBlendComposite {
            if let strokeImage {
                if let image = stack.blendComposite(preview: strokeImage)?.image { context.draw(image, in: rect) }
            } else {
                if composite == nil { composite = stack.blendComposite()?.image }
                if let composite { context.draw(composite, in: rect) }
            }
        } else {
            stack.draw(in: context, rect: rect, preview: strokeImage)
        }
        context.restoreGState()
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
