import AppKit

final class CanvasView: NSView {
    var image: CGImage?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }

        let available = bounds.insetBy(dx: 24, dy: 24)
        guard available.width > 0, available.height > 0 else { return }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(available.width / width, available.height / height, 1)
        let rect = CGRect(x: available.midX - width * scale / 2,
                          y: available.midY - height * scale / 2,
                          width: width * scale, height: height * scale)

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
