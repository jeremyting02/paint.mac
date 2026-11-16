import AppKit

final class CanvasView: NSView {
    enum Tool { case brush, eraser, crop }

    private static let zoomSteps: [CGFloat] = [
        1, 2, 3, 5, 6, 8, 12.5, 16, 25, 33, 50, 66, 75, 100, 150, 200, 300, 400, 500,
        600, 800, 1000, 1200, 1400, 1600, 2000, 2400, 2800, 3200, 4000, 4800, 5600, 6400,
        8000, 10000
    ]

    private weak var document: PaintDocument?
    var tool = Tool.brush {
        didSet { if tool != oldValue { clearSelection() } }
    }
    private(set) var zoomPercent: CGFloat?
    private(set) var displayedZoomPercent: CGFloat = 0
    var zoomDidChange: (() -> Void)?
    var brushColor = NSColor.black
    var brushSize: CGFloat = 12
    var selectionDidChange: (() -> Void)?
    var layerPreview: LayerStack? {
        didSet {
            composite = nil
            needsDisplay = true
        }
    }
    private var composite: CGImage?

    private(set) var selection = CGRect.zero {
        didSet {
            needsDisplay = true
            selectionDidChange?()
        }
    }
    private var selectionAnchor: CGPoint?

    private var stroke: (bitmap: CGContext, lastPoint: CGPoint, actionName: String)?
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
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
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
        } else if !imageRect.isEmpty {
            addCursorRect(imageRect, cursor: .crosshair)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let zooming = event.modifierFlags.contains(.control)
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
        guard !imageRect.isEmpty, stroke == nil, selectionAnchor == nil, panLocation == nil,
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
        guard !imageRect.isEmpty, stroke == nil, selectionAnchor == nil else { return }
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
        if visibleRect.contains(location) && imageRect.contains(location) {
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

    func clearSelection() {
        selectionAnchor = nil
        if selection != .zero { selection = .zero }
    }

    func cancelStroke() {
        stroke = nil
        composite = nil
    }

    var cropRect: CGRect? {
        guard let image = document?.image, !selection.isEmpty,
              selection.size != CGSize(width: image.width, height: image.height) else { return nil }
        // The canvas uses a bottom-left origin. CGImage cropping starts at the top left.
        return CGRect(x: selection.minX, y: CGFloat(image.height) - selection.maxY,
                      width: selection.width, height: selection.height)
    }

    func cropSelection() {
        if let cropRect { document?.crop(to: cropRect) }
    }

    override func keyDown(with event: NSEvent) {
        if tool == .crop && (event.keyCode == 36 || event.keyCode == 76) {
            cropSelection()
        } else if tool == .crop && event.keyCode == 53 {
            clearSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard panLocation == nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(location), let image = document?.image else {
            clearSelection()
            return
        }

        window?.makeFirstResponder(self)
        if tool == .crop {
            selectionAnchor = pixelEdge(at: location, in: image)
            selection = .zero
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
        bitmap.setBlendMode(isErasing ? .clear : .normal)
        let color = (brushColor.usingColorSpace(.sRGB) ?? .black).withAlphaComponent(1).cgColor
        bitmap.setFillColor(color)
        bitmap.setStrokeColor(color)
        bitmap.setLineCap(.round)
        bitmap.setLineWidth(brushSize)

        let point = imagePoint(location)
        bitmap.fillEllipse(in: CGRect(x: point.x - brushSize / 2, y: point.y - brushSize / 2,
                                     width: brushSize, height: brushSize))
        stroke = (bitmap, point, isErasing ? "Eraser" : "Paintbrush")
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !imageRect.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        if let start = selectionAnchor, let image = document?.image {
            let end = pixelEdge(at: location, in: image)
            selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(start.x - end.x), height: abs(start.y - end.y))
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
        mouseDragged(with: event)
        selectionAnchor = nil
        guard let current = stroke else { return }
        stroke = nil
        if let image = current.bitmap.makeImage() {
            document?.replaceImage(with: image, actionName: current.actionName)
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
        guard !visible.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              let stack = layerPreview ?? document?.stack else { return }

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
        let imageWidth = CGFloat(stack.activeLayer.image.width)
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
        if !selection.isEmpty {
            let scale = rect.width / imageWidth
            let marquee = CGRect(x: rect.minX + selection.minX * scale, y: rect.minY + selection.minY * scale,
                                 width: selection.width * scale, height: selection.height * scale)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
            context.fill(marquee)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(marquee)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(marquee)
        }
        context.restoreGState()
    }
}
