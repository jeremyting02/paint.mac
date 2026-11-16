import AppKit

final class CanvasView: NSView {
    enum Tool { case brush, eraser, crop }

    private weak var document: PaintDocument?
    var tool = Tool.brush {
        didSet { if tool != oldValue { clearSelection() } }
    }
    var fitsToWindow = true
    var brushColor = NSColor.black
    var brushSize: CGFloat = 12
    var selectionDidChange: (() -> Void)?

    private(set) var selection = CGRect.zero {
        didSet {
            needsDisplay = true
            selectionDidChange?()
        }
    }
    private var selectionAnchor: CGPoint?

    private var stroke: (bitmap: CGContext, lastPoint: CGPoint, actionName: String)?

    init(document: PaintDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityLabel("Canvas")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    private let margin: CGFloat = 24
    private var backingScale: CGFloat { window?.backingScaleFactor ?? 1 }

    func fitViewport() {
        guard let viewport = enclosingScrollView?.contentSize, let image = document?.image else { return }
        var size = viewport
        if !fitsToWindow {
            size.width = max(size.width, CGFloat(image.width) / backingScale + 2 * margin)
            size.height = max(size.height, CGFloat(image.height) / backingScale + 2 * margin)
        }
        if frame.size != size { setFrameSize(size) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fitViewport()
    }

    private var imageRect: CGRect {
        guard let image = document?.image else { return .zero }
        let available = bounds.insetBy(dx: margin, dy: margin)
        guard available.width > 0, available.height > 0 else { return .zero }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = fitsToWindow ? min(available.width / width, available.height / height) : 1 / backingScale
        return CGRect(x: (available.midX * backingScale - width * scale * backingScale / 2).rounded() / backingScale,
                      y: (available.midY * backingScale - height * scale * backingScale / 2).rounded() / backingScale,
                      width: width * scale, height: height * scale)
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
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

    var cropRect: CGRect? {
        guard let image = document?.image, !selection.isEmpty,
              selection.size != CGSize(width: image.width, height: image.height) else { return nil }
        // The canvas uses a bottom-left origin. CGImage cropping starts at the top left.
        return CGRect(x: selection.minX, y: CGFloat(image.height) - selection.maxY,
                      width: selection.width, height: selection.height)
    }

    func cropSelection() {
        guard let cropRect, let image = document?.image?.cropping(to: cropRect) else { return }
        document?.replaceImage(with: image, actionName: "Crop")
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

        guard let bitmap = PaintDocument.makeBitmap(width: image.width, height: image.height) else { return }
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
              let image = stroke?.bitmap.makeImage() ?? document?.image else { return }

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
        if !fitsToWindow { context.interpolationQuality = .none }
        context.draw(image, in: rect)
        if !selection.isEmpty {
            let scale = rect.width / CGFloat(image.width)
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
