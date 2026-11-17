import AppKit
import CoreText

enum DrawingShape: String, CaseIterable {
    case rectangle = "Rectangle", roundedRectangle = "Rounded Rectangle", ellipse = "Ellipse"
    case diamond = "Diamond", trapezoid = "Trapezoid", parallelogram = "Parallelogram"
    case triangle = "Triangle", rightTriangle = "Right Triangle"
    case pentagon = "Pentagon", hexagon = "Hexagon", heptagon = "Heptagon", octagon = "Octagon"
    case star3 = "Three-Point Star", star4 = "Four-Point Star", star5 = "Five-Point Star", star6 = "Six-Point Star"
    case arrow = "Arrow", notchedArrow = "Notched Arrow", pentagonArrow = "Pentagon Arrow", chevronArrow = "Chevron Arrow"
    case rectangleCallout = "Rectangular Callout", roundedCallout = "Rounded Rectangle Callout"
    case ellipseCallout = "Ellipse Callout", cloud = "Cloud Callout"
    case lightning = "Lightning Bolt", checkmark = "Check Mark", multiply = "Multiply", gear = "Gear", heart = "Heart"

    func path(in rect: CGRect, cornerRadius: CGFloat? = nil) -> CGPath {
        switch self {
        case .rectangle: return CGPath(rect: rect, transform: nil)
        case .roundedRectangle:
            let side = min(rect.width, rect.height)
            let radius = min(side / 2, cornerRadius ?? side / 5)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        default: break
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let path = CGMutablePath()
        if self == .heart {
            path.move(to: point(0.5, 0))
            path.addCurve(to: point(0.5, 0.75), control1: point(-0.45, 0.65), control2: point(0.14, 1.35))
            path.addCurve(to: point(0.5, 0), control1: point(0.86, 1.35), control2: point(1.45, 0.65))
        } else if self == .rectangleCallout || self == .roundedCallout || self == .ellipseCallout || self == .cloud {
            func curve(_ end: CGPoint, _ first: CGPoint, _ second: CGPoint) {
                path.addQuadCurve(to: second, control: first)
                path.addLine(to: end)
            }
            path.move(to: point(0.38, 0.19))
            path.addLines(between: [point(0.17, 0), point(0.22, 0.21)])
            switch self {
            case .rectangleCallout:
                path.addLines(between: [point(0, 0.21), point(0, 1), point(1, 1), point(1, 0.21),
                                        point(0.38, 0.21)])
            case .roundedCallout:
                path.addLine(to: point(0.16, 0.21))
                curve(point(0, 0.84), point(0, 0.21), point(0, 0.37))
                curve(point(0.84, 1), point(0, 1), point(0.16, 1))
                curve(point(1, 0.37), point(1, 1), point(1, 0.84))
                curve(point(0.38, 0.21), point(1, 0.21), point(0.84, 0.21))
            case .ellipseCallout:
                path.addCurve(to: point(0.5, 1), control1: point(-0.20, 0.38), control2: point(0.01, 1))
                path.addCurve(to: point(0.38, 0.19), control1: point(1.24, 1), control2: point(1.17, 0.1))
            default:
                for (end, control) in [((0.08, 0.45), (-0.10, 0.22)), ((0.23, 0.69), (-0.05, 0.72)),
                                       ((0.49, 0.86), (0.24, 1.04)), ((0.78, 0.83), (0.69, 1.11)),
                                       ((0.93, 0.59), (1.04, 0.89)), ((0.88, 0.33), (1.10, 0.41)),
                                       ((0.60, 0.21), (0.86, 0.11)), ((0.38, 0.19), (0.51, 0.05))] {
                    path.addQuadCurve(to: point(end.0, end.1), control: point(control.0, control.1))
                }
            }
        } else {
            path.addLines(between: vertices.map { point($0.0, $0.1) })
        }
        path.closeSubpath()
        if self == .gear {
            let hole = CGRect(x: rect.midX - rect.width * 0.14, y: rect.midY - rect.height * 0.14,
                              width: rect.width * 0.28, height: rect.height * 0.28)
            path.addEllipse(in: hole)
        }
        return path
    }

    private var vertices: [(CGFloat, CGFloat)] {
        switch self {
        case .triangle: return [(0, 0), (1, 0), (0.5, 1)]
        case .rightTriangle: return [(0, 0), (1, 0), (0, 1)]
        case .diamond: return [(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)]
        case .trapezoid: return [(0, 0), (1, 0), (0.78, 1), (0.22, 1)]
        case .parallelogram: return [(0, 0), (0.78, 0), (1, 1), (0.22, 1)]
        case .arrow, .notchedArrow:
            let arrow: [(CGFloat, CGFloat)] = [(0, 0.29), (0.59, 0.29), (0.59, 0), (1, 0.5),
                                                (0.59, 1), (0.59, 0.71), (0, 0.71)]
            return self == .notchedArrow ? arrow + [(0.22, 0.5)] : arrow
        case .pentagonArrow: return [(0, 0), (0.62, 0), (1, 0.5), (0.62, 1), (0, 1)]
        case .chevronArrow: return [(0, 0), (0.53, 0), (1, 0.5), (0.53, 1), (0, 1), (0.47, 0.5)]
        case .lightning: return [(0.65, 1), (0.23, 0.51), (0.47, 0.51), (0.35, 0), (0.78, 0.59), (0.51, 0.59)]
        case .checkmark: return [(0.0, 0.42), (0.13, 0.55), (0.34, 0.31), (0.86, 0.94), (1, 0.81), (0.34, 0.05)]
        case .multiply:
            return [(0.0, 0.16), (0.34, 0.5), (0, 0.84), (0.16, 1), (0.5, 0.66), (0.84, 1),
                    (1, 0.84), (0.66, 0.5), (1, 0.16), (0.84, 0), (0.5, 0.34), (0.16, 0)]
        case .pentagon: return regularVertices(count: 5)
        case .hexagon: return regularVertices(count: 6)
        case .heptagon: return regularVertices(count: 7)
        case .octagon: return regularVertices(count: 8)
        case .star3: return regularVertices(count: 6, inner: 0.22)
        case .star4: return regularVertices(count: 8, inner: 0.22)
        case .star5: return regularVertices(count: 10, inner: 0.22)
        case .star6: return regularVertices(count: 12, inner: 0.22)
        case .gear:
            return (0..<32).map { index in
                let angle = .pi / 2 + 2 * .pi * CGFloat(index) / 32
                let radius: CGFloat = index % 4 < 2 ? 0.5 : 0.37
                return (0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius)
            }
        default: return []
        }
    }

    private func regularVertices(count: Int, inner: CGFloat = 0.5) -> [(CGFloat, CGFloat)] {
        (0..<count).map { index in
            let angle = .pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(count)
            let radius: CGFloat = index.isMultiple(of: 2) ? 0.5 : inner
            return (0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius)
        }
    }
}

enum DrawingFill: String, CaseIterable {
    case outline = "Outline", fill = "Fill", both = "Outline and Fill"
}

enum TextAlignment: String, CaseIterable {
    case left = "Left", center = "Center", right = "Right"
}

enum DrawingLinePattern: String, CaseIterable {
    case solid = "Solid", dash = "Dashed", dot = "Dotted", dashDot = "Dash Dot"

    var lengths: [CGFloat] {
        switch self {
        case .solid: return []
        case .dash: return [4, 2]
        case .dot: return [1, 2]
        case .dashDot: return [4, 2, 1, 2]
        }
    }
}

struct DrawingStyle {
    var primary = NSColor.black
    var secondary = NSColor.white
    var width: CGFloat = 1
    var antialiased = true
    var shape: DrawingShape = .rectangle
    var fill: DrawingFill = .outline
    var curve = false
    var linePattern: DrawingLinePattern = .solid
    var blendMode: LayerBlendMode = .normal
    var cornerRadius: CGFloat = 12
    var text = ""
    var fontName = NSFont.systemFont(ofSize: 16).fontName
    var fontSize: CGFloat = 16
    var alignment: TextAlignment = .left
    var bold = false
    var italic = false
}

enum VectorDrawing {
    case line([CGPoint])
    case shape(CGRect, angle: CGFloat = 0)
    case text(CGPoint)

    var handles: [CGPoint] {
        switch self {
        case .line(let points): return points
        case .shape(let rect, let angle):
            let local = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            return local.map { $0.applying(shapeTransform(rect, angle: angle)) }
        case .text(let origin): return [origin]
        }
    }

    func translated(by delta: CGPoint) -> Self {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.x, y: point.y + delta.y) }
        switch self {
        case .line(let points): return .line(points.map(move))
        case .shape(let rect, let angle): return .shape(rect.offsetBy(dx: delta.x, dy: delta.y), angle: angle)
        case .text(let origin): return .text(move(origin))
        }
    }

    var center: CGPoint {
        switch self {
        case .line(let points):
            return CGPoint(x: (points[0].x + points[3].x) / 2, y: (points[0].y + points[3].y) / 2)
        case .shape(let rect, _): return CGPoint(x: rect.midX, y: rect.midY)
        case .text(let origin): return origin
        }
    }

    func rotated(by angle: CGFloat) -> Self {
        let pivot = center
        switch self {
        case .line(let points):
            let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .rotated(by: angle).translatedBy(x: -pivot.x, y: -pivot.y)
            return .line(points.map { $0.applying(transform) })
        case .shape(let rect, let previous): return .shape(rect, angle: previous + angle)
        case .text: return self
        }
    }

    func shapeContains(_ point: CGPoint) -> Bool {
        guard case .shape(let rect, let angle) = self else { return false }
        return rect.contains(point.applying(shapeTransform(rect, angle: -angle)))
    }

    private func shapeTransform(_ rect: CGRect, angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: angle).translatedBy(x: -rect.midX, y: -rect.midY)
    }

    func applying(to layer: PaintLayer, selection: SelectionOutline?, style: DrawingStyle,
                  allowsMetal: Bool = true) -> PaintLayer? {
        let width = layer.image.width, height = layer.image.height
        guard let original = layer.straightPixels,
              let overlay = BGRA8.render(width: width, height: height, colorSpace: layer.workingColorSpace, draw: { context in
                  if let selection {
                      context.addPath(selection.path)
                      context.clip(using: .evenOdd)
                  }
                  draw(in: context, style: style)
              }) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if allowsMetal, let result = MetalRasterTools.composite(overlay, on: original, width: width, rect: rect,
                                                                 mode: style.blendMode) {
            return result == original ? nil : layer.withPixels(result)
        }
        var result = original
        style.blendMode.composite(overlay, onto: &result, opacity: 255)
        return result == original ? nil : layer.withPixels(result)
    }

    private func draw(in context: CGContext, style: DrawingStyle) {
        let primary = (style.primary.usingColorSpace(.sRGB) ?? .black).cgColor
        let secondary = (style.secondary.usingColorSpace(.sRGB) ?? .white).cgColor
        context.setShouldAntialias(style.antialiased)
        context.setLineWidth(style.width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(primary)
        context.setFillColor(primary)
        context.setLineDash(phase: 0, lengths: style.linePattern.lengths.map { $0 * style.width })
        switch self {
        case .line(let points):
            guard points.count == 4, points[0] != points[3] else { return }
            context.move(to: points[0])
            if style.curve { context.addCurve(to: points[3], control1: points[1], control2: points[2]) }
            else { context.addLine(to: points[3]) }
            context.strokePath()
        case .shape(let rect, let angle):
            guard !rect.isEmpty else { return }
            context.concatenate(shapeTransform(rect, angle: angle))
            context.addPath(style.shape.path(in: rect, cornerRadius: style.cornerRadius))
            switch style.fill {
            case .outline: context.strokePath()
            case .fill: context.fillPath(using: .evenOdd)
            case .both:
                context.setFillColor(secondary)
                context.drawPath(using: .eoFillStroke)
            }
        case .text(let origin):
            let size = style.fontSize
            var font = NSFont(name: style.fontName, size: size) ?? .systemFont(ofSize: size)
            if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): primary
            ]
            var baseline = origin.y - font.ascender
            for content in style.text.components(separatedBy: .newlines) {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: attributes))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                let offset = style.alignment == .left ? 0 : style.alignment == .center ? width / 2 : width
                context.textPosition = CGPoint(x: origin.x - offset, y: baseline)
                CTLineDraw(line, context)
                baseline -= font.ascender - font.descender + font.leading
            }
        }
    }
}
