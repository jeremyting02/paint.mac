import AppKit

struct WorkspacePixelAxis {
    let origin: CGFloat
    let pointPerPixel: CGFloat

    func point(at pixel: CGFloat) -> CGFloat { origin + pixel * pointPerPixel }

    func pixels(in visible: ClosedRange<CGFloat>, every interval: CGFloat) -> ClosedRange<Int>? {
        guard pointPerPixel != 0, interval > 0 else { return nil }
        let first = (visible.lowerBound - origin) / pointPerPixel / interval
        let last = (visible.upperBound - origin) / pointPerPixel / interval
        let lower = Int(ceil(min(first, last)))
        let upper = Int(floor(max(first, last)))
        return lower <= upper ? lower...upper : nil
    }

    var rulerMajorInterval: CGFloat {
        guard pointPerPixel != 0 else { return 1 }
        let minimum = max(5, 48 / abs(pointPerPixel))
        let power = pow(10, floor(log10(minimum)))
        return [power, 2 * power, 5 * power, 10 * power].first(where: { $0 >= minimum }) ?? power
    }
}

final class WorkspaceRuler: NSRulerView {
    private weak var canvas: CanvasView?
    var pixelCount: Int = 0 { didSet { needsDisplay = true } }
    var pointer: CGFloat? { didSet { if oldValue != pointer { needsDisplay = true } } }

    init(scrollView: NSScrollView, canvas: CanvasView, orientation: NSRulerView.Orientation) {
        self.canvas = canvas
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = isHorizontal ? 20 : 32
        reservedThicknessForMarkers = 0
        setAccessibilityLabel(isHorizontal ? "Horizontal ruler" : "Vertical ruler")
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    private var isHorizontal: Bool { orientation == .horizontalRuler }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let canvas, pixelCount > 0, !canvas.canvasImageRect.isEmpty else { return }
        let image = convert(canvas.canvasImageRect, from: canvas)
        let horizontal = isHorizontal
        let top = convert(CGPoint(x: canvas.canvasImageRect.minX, y: canvas.canvasImageRect.maxY), from: canvas).y
        let bottom = convert(CGPoint(x: canvas.canvasImageRect.minX, y: canvas.canvasImageRect.minY), from: canvas).y
        let axis = horizontal
            ? WorkspacePixelAxis(origin: image.minX, pointPerPixel: image.width / CGFloat(pixelCount))
            : WorkspacePixelAxis(origin: top, pointPerPixel: (bottom - top) / CGFloat(pixelCount))
        let interval = axis.rulerMajorInterval / 5
        let visible = horizontal ? rect.minX...rect.maxX : rect.minY...rect.maxY
        guard let indices = axis.pixels(in: visible, every: interval) else { return }

        if let selection = canvas.imageSelection {
            let start = axis.point(at: horizontal ? selection.minX : selection.minY)
            let end = axis.point(at: horizontal ? selection.maxX : selection.maxY)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            if horizontal {
                CGRect(x: min(start, end), y: bounds.minY, width: abs(end - start), height: bounds.height).fill()
            } else {
                CGRect(x: bounds.minX, y: min(start, end), width: bounds.width, height: abs(end - start)).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        NSColor.secondaryLabelColor.setStroke()
        let ticks = NSBezierPath()
        ticks.lineWidth = 0.5
        for index in indices {
            let pixel = CGFloat(index) * interval
            guard pixel >= 0, pixel <= CGFloat(pixelCount) else { continue }
            let point = axis.point(at: pixel)
            let major = index.isMultiple(of: 5)
            let length: CGFloat = major ? 8 : 4
            if horizontal {
                ticks.move(to: NSPoint(x: point, y: bounds.maxY))
                ticks.line(to: NSPoint(x: point, y: bounds.maxY - length))
                if major { String(Int(pixel)).draw(at: NSPoint(x: point + 2, y: bounds.minY), withAttributes: attributes) }
            } else {
                ticks.move(to: NSPoint(x: bounds.maxX, y: point))
                ticks.line(to: NSPoint(x: bounds.maxX - length, y: point))
                if major { String(Int(pixel)).draw(at: NSPoint(x: bounds.minX + 2, y: point), withAttributes: attributes) }
            }
        }
        ticks.stroke()

        if let pointer {
            NSColor.controlAccentColor.setFill()
            let point = axis.point(at: pointer)
            if horizontal { CGRect(x: point, y: bounds.minY, width: 1, height: bounds.height).fill() }
            else { CGRect(x: bounds.minX, y: point, width: bounds.width, height: 1).fill() }
        }
    }
}

extension CanvasView {
    func drawWorkspaceGrid(in context: CGContext) {
        let rect = canvasImageRect
        let visible = rect.intersection(visibleRect)
        let pixelSize = displayedZoomPercent / (100 * (window?.backingScaleFactor ?? 1))
        guard displayedZoomPercent >= 200, !visible.isEmpty else { return }
        let horizontal = WorkspacePixelAxis(origin: rect.minX, pointPerPixel: pixelSize)
        let vertical = WorkspacePixelAxis(origin: rect.minY, pointPerPixel: pixelSize)
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(gray: 0.25, alpha: 0.44)
        context.setLineWidth(0.5 / (window?.backingScaleFactor ?? 1))
        context.setShouldAntialias(false)
        context.beginPath()
        if let columns = horizontal.pixels(in: visible.minX...visible.maxX, every: 1) {
            for column in columns {
                let x = horizontal.point(at: CGFloat(column))
                context.move(to: CGPoint(x: x, y: visible.minY))
                context.addLine(to: CGPoint(x: x, y: visible.maxY))
            }
        }
        if let rows = vertical.pixels(in: visible.minY...visible.maxY, every: 1) {
            for row in rows {
                let y = vertical.point(at: CGFloat(row))
                context.move(to: CGPoint(x: visible.minX, y: y))
                context.addLine(to: CGPoint(x: visible.maxX, y: y))
            }
        }
        context.strokePath()
        context.restoreGState()
    }
}
