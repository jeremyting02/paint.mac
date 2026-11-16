import AppKit

final class CanvasView: NSView {
    private weak var document: PaintDocument?
    var isErasing = false
    var brushColor = NSColor.black
    var brushSize: CGFloat = 12

    private var stroke: (bitmap: CGContext, lastPoint: CGPoint, actionName: String)?

    init(document: PaintDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityLabel("Canvas")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    private var imageRect: CGRect {
        guard let image = document?.image else { return .zero }
        let available = bounds.insetBy(dx: 24, dy: 24)
        guard available.width > 0, available.height > 0 else { return .zero }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(available.width / width, available.height / height, 1)
        return CGRect(x: available.midX - width * scale / 2,
                      y: available.midY - height * scale / 2,
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

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(location), let image = document?.image,
              let bitmap = PaintDocument.makeBitmap(width: image.width, height: image.height)
        else { return }

        window?.makeFirstResponder(self)
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
        guard let current = stroke, !imageRect.isEmpty else { return }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        guard point != current.lastPoint else { return }
        current.bitmap.move(to: current.lastPoint)
        current.bitmap.addLine(to: point)
        current.bitmap.strokePath()
        stroke?.lastPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
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
        guard !rect.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              let image = stroke?.bitmap.makeImage() ?? document?.image else { return }

        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(rect)
        context.setFillColor(gray: 0.73, alpha: 1)
        let square: CGFloat = 12
        for (row, y) in stride(from: rect.minY, to: rect.maxY, by: square).enumerated() {
            let offset = row.isMultiple(of: 2) ? 0 : square
            for x in stride(from: rect.minX + offset, to: rect.maxX, by: square * 2) {
                context.fill(CGRect(x: x, y: y, width: square, height: square))
            }
        }
        context.draw(image, in: rect)
        context.restoreGState()
    }
}
