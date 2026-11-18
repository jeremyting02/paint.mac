import AppKit
import CoreText

enum TextMetric: String, CaseIterable {
    case points = "Points (image DPI)"
    case fixed = "Fixed (96 DPI)"

    func pixelSize(_ points: CGFloat, resolution: ImageResolution) -> CGFloat {
        let dpi = self == .points ? resolution.vertical : ImageResolution.standard.vertical
        return points * dpi / 72
    }
}

enum TextRendering: String, CaseIterable {
    case smooth = "Smooth"
    case sharpModern = "Sharp (Modern)"
    case sharpClassic = "Sharp (Classic)"
}

struct TextLayout {
    private struct Line {
        let range: NSRange
        let glyphs: CTLine
        let position: CGPoint
        let width: CGFloat

        func x(at index: Int) -> CGFloat {
            position.x + CTLineGetOffsetForStringIndex(glyphs, index - range.location, nil)
        }
    }

    private let font: NSFont
    private let lines: [Line]
    private let lineHeight: CGFloat
    private let scaleX: CGFloat
    private let rendering: TextRendering
    private let ink: NSColor

    init(origin: CGPoint, style: DrawingStyle) {
        let size = style.textMetric.pixelSize(style.fontSize, resolution: style.textResolution)
        // Bound the font size passed to Core Text for extreme document resolutions.
        let safeSize = min(32_768, max(0.1, size))
        let base = NSFont(name: style.fontName, size: safeSize) ?? .systemFont(ofSize: safeSize)
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        font = traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
        lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        scaleX = style.textMetric == .fixed ? 1 : style.textResolution.horizontal / style.textResolution.vertical
        rendering = style.textRendering
        ink = style.primary.usingColorSpace(.sRGB) ?? .black
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.withAlphaComponent(1).cgColor
        ]
        let source = style.text as NSString
        var start = 0
        var baseline = origin.y - font.ascender
        var result: [Line] = []
        repeat {
            var end = start
            var contentsEnd = start
            if start < source.length {
                source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            }
            let range = NSRange(location: start, length: contentsEnd - start)
            let text = NSAttributedString(string: source.substring(with: range), attributes: attributes)
            let glyphs = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(glyphs, nil, nil, nil)
            let offset = style.alignment == .left ? 0 : style.alignment == .center ? width / 2 : width
            let position = CGPoint(x: origin.x - offset * scaleX, y: baseline)
            result.append(Line(range: range, glyphs: glyphs, position: position, width: width))
            baseline -= lineHeight
            if end == contentsEnd { break }
            start = end
        } while start <= source.length
        lines = result
    }

    func caret(at index: Int) -> CGRect {
        let line = lines.last(where: { $0.range.location <= index }) ?? lines[0]
        let clamped = min(max(index, line.range.location), NSMaxRange(line.range))
        let x = position(of: line).x + (line.x(at: clamped) - line.position.x) * scaleX
        return CGRect(x: x, y: position(of: line).y + font.descender, width: 0, height: lineHeight)
    }

    func characterIndex(at point: CGPoint) -> Int {
        let line = lines[min(lines.count - 1, max(0, Int((caret(at: 0).maxY - point.y) / lineHeight)))]
        let offset = CTLineGetStringIndexForPosition(line.glyphs,
                                                    CGPoint(x: (point.x - position(of: line).x) / scaleX, y: 0))
        if offset == kCFNotFound { return line.range.location }
        return line.range.location + offset
    }

    func selectionRects(for range: NSRange) -> [CGRect] {
        lines.compactMap { line in
            let overlap = NSIntersectionRange(range, line.range)
            guard overlap.length > 0 else { return nil }
            let left = caret(at: overlap.location)
            let right = caret(at: NSMaxRange(overlap)).minX
            return CGRect(x: min(left.minX, right), y: left.minY,
                          width: abs(right - left.minX), height: left.height)
        }
    }

    private func position(of line: Line) -> CGPoint {
        guard rendering == .sharpClassic else { return line.position }
        return CGPoint(x: line.position.x.rounded(), y: line.position.y.rounded())
    }

    func applying(to layer: PaintLayer, selection: SelectionOutline?, style: DrawingStyle,
                  allowsMetal: Bool = true) -> PaintLayer? {
        guard !style.text.isEmpty else { return nil }
        let width = layer.image.width
        let height = layer.image.height
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        var bounds = CGRect.null
        for line in lines where line.range.length > 0 {
            let origin = position(of: line)
            let glyphs = CTLineGetImageBounds(line.glyphs, nil)
            if !glyphs.isNull && !glyphs.isEmpty {
                let ink = glyphs.applying(CGAffineTransform(scaleX: scaleX, y: 1))
                bounds = bounds.union(ink.offsetBy(dx: origin.x, dy: origin.y))
            }
            if style.underline || style.strikeout {
                bounds = bounds.union(CGRect(x: origin.x, y: origin.y + font.descender,
                                             width: line.width * scaleX, height: lineHeight))
            }
        }
        let clipped = bounds.insetBy(dx: -2, dy: -2).integral.intersection(canvas)
        let rect = selection.map { clipped.intersection($0.bounds.integral) } ?? clipped
        guard !rect.isEmpty, let original = layer.straightPixels else { return nil }
        let region = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        let rowWidth = Int(region.width)
        guard var overlay = BGRA8.render(width: rowWidth, height: Int(region.height),
                                         colorSpace: layer.workingColorSpace, draw: { context in
            context.translateBy(x: -rect.minX, y: -rect.minY)
            draw(in: context, style: style)
        }) else { return nil }
        if let selection, !selection.pixelRectangle {
            guard let mask = selection.mask(in: region, imageHeight: height,
                                            antialiased: style.textAntialiasedSelection) else { return nil }
            overlay.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                mask.withUnsafeBytes { (mask: UnsafeRawBufferPointer) in
                    for index in mask.indices {
                        let alpha = index * 4 + 3
                        target[alpha] = UInt8((Int(target[alpha]) * Int(mask[index]) + 127) / 255)
                    }
                }
            }
        }

        let opacity = UInt8((ink.alphaComponent * 255).rounded())
        if case .layer(let mode) = style.textBlend, opacity == 255, allowsMetal,
           let pixels = MetalRasterTools.composite(overlay, on: original, width: width, rect: region, mode: mode) {
            return pixels == original ? nil : layer.withPixels(pixels)
        }
        var pixels = original
        pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            overlay.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                let rowBytes = rowWidth * 4
                for row in 0..<Int(region.height) {
                    let offset = ((Int(region.minY) + row) * width + Int(region.minX)) * 4
                    let input = UnsafeRawBufferPointer(rebasing: source[(row * rowBytes)..<((row + 1) * rowBytes)])
                    let output = UnsafeMutableRawBufferPointer(rebasing: target[offset..<(offset + rowBytes)])
                    switch style.textBlend {
                    case .layer(let mode):
                        mode.composite(input, onto: output, opacity: opacity)
                    case .overwrite:
                        for pixel in stride(from: 0, to: rowBytes, by: 4) where input[pixel + 3] > 0 {
                            let color = SIMD4(input[pixel], input[pixel + 1], input[pixel + 2], opacity)
                            BGRA8.overwrite(color, coverage: Int(input[pixel + 3]), pixel: pixel, in: output)
                        }
                    }
                }
            }
        }
        return pixels == original ? nil : layer.withPixels(pixels)
    }

    private func draw(in context: CGContext, style: DrawingStyle) {
        context.setShouldAntialias(style.antialiased)
        context.setAllowsAntialiasing(style.antialiased)
        context.setShouldSmoothFonts(rendering != .smooth && style.antialiased)
        context.setShouldSubpixelPositionFonts(rendering != .sharpClassic)
        context.setShouldSubpixelQuantizeFonts(rendering == .sharpModern)
        context.setFillColor(ink.withAlphaComponent(1).cgColor)
        for line in lines where line.range.length > 0 {
            context.saveGState()
            let origin = position(of: line)
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scaleX, y: 1)
            context.textPosition = .zero
            if rendering == .smooth, let outline = outline(of: line.glyphs) {
                context.addPath(outline)
                context.fillPath()
            } else {
                CTLineDraw(line.glyphs, context)
            }
            let thickness = max(1, font.underlineThickness)
            if style.underline {
                context.fill(CGRect(x: 0, y: font.underlinePosition - thickness / 2,
                                    width: line.width, height: thickness))
            }
            if style.strikeout {
                context.fill(CGRect(x: 0, y: font.xHeight / 2 - thickness / 2,
                                    width: line.width, height: thickness))
            }
            context.restoreGState()
        }
    }

    private func outline(of line: CTLine) -> CGPath? {
        let outline = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { return nil }
            let runFont = font as! CTFont
            if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) { return nil }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            for (glyph, position) in zip(glyphs, positions) {
                var transform = CTRunGetTextMatrix(run)
                if let path = CTFontCreatePathForGlyph(runFont, glyph, &transform) {
                    outline.addPath(path, transform: CGAffineTransform(translationX: position.x, y: position.y))
                }
            }
        }
        return outline
    }
}
