import CoreGraphics
import Foundation

struct GradientOptions {
    enum Shape: String, CaseIterable {
        case linear = "Linear", reflected = "Linear (Reflected)", diamond = "Diamond", radial = "Radial"
        case conical = "Conical", clockwise = "Spiral (Clockwise)", anticlockwise = "Spiral (Anticlockwise)"
    }

    enum Repeat: String, CaseIterable {
        case none = "No Repeat", wrapped = "Wrapped", reflected = "Reflected"
    }

    var shape: Shape = .linear
    var repeats: Repeat = .none
    var transparency = false
    var blendMode: LayerBlendMode = .normal

    func position(x: CGFloat, y: CGFloat) -> CGFloat {
        let position: CGFloat
        switch shape {
        case .linear: position = x
        case .reflected: position = abs(x)
        case .diamond: position = abs(x) + abs(y)
        case .radial: position = hypot(x, y)
        case .conical: position = atan2(y, x) / (2 * .pi) + 0.5
        case .clockwise: position = hypot(x, y) + atan2(y, x) / (2 * .pi)
        case .anticlockwise: position = hypot(x, y) - atan2(y, x) / (2 * .pi)
        }
        switch repeats {
        case .none: return max(0, min(1, position))
        case .wrapped: return position - floor(position)
        case .reflected:
            let period = position - 2 * floor(position / 2)
            return period <= 1 ? period : 2 - period
        }
    }
}

struct LinearGradient {
    var start: CGPoint
    var end: CGPoint

    func applying(to layer: PaintLayer, primary: CGColor, secondary: CGColor,
                  selection: SelectionOutline?, options: GradientOptions = GradientOptions(),
                  reversed: Bool = false, allowsMetal: Bool = true) -> PaintLayer? {
        if options.shape != .linear || options.repeats != .none || options.transparency || options.blendMode != .normal {
            return render(to: layer, primary: primary, secondary: secondary, selection: selection,
                          options: options, reversed: reversed)
        }
        let colors = reversed ? [secondary, primary] : [primary, secondary]
        guard start != end, let original = layer.straightPixels,
              let gradient = CGGradient(colorsSpace: layer.workingColorSpace,
                                        colors: colors as CFArray, locations: nil) else { return nil }
        let width = layer.image.width, height = layer.image.height
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let region = selection?.bounds.integral.intersection(canvas) ?? canvas
        guard !region.isEmpty else { return nil }
        let rows = Int(region.height)
        let length = hypot(end.x - start.x, end.y - start.y)
        // Keep normal compositing for subpixel lines, since Core Graphics may skip a nearly coincident gradient.
        let replacesLayer = selection == nil && primary.alpha == 1 && secondary.alpha == 1 && length >= 1
        let rendered = BGRA8.render(width: Int(region.width), height: rows, opaque: replacesLayer,
                                    colorSpace: layer.workingColorSpace) { context in
            context.translateBy(x: -region.minX, y: -region.minY)
            if let selection {
                context.addPath(selection.path)
                context.clip(using: .evenOdd)
            }
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        guard let foreground = rendered else { return nil }
        if replacesLayer { return foreground == original ? nil : layer.withPixels(foreground) }

        // Blend straight-alpha pixels into the original bytes so untouched PDN pixels stay exact.
        let pixelRect = CGRect(x: region.minX, y: CGFloat(height) - region.maxY, width: region.width, height: region.height)
        if allowsMetal, let result = MetalRasterTools.composite(foreground, on: original, width: width,
                                                                 rect: pixelRect, mode: .normal) {
            return result == original ? nil : layer.withPixels(result)
        }
        let rowBytes = Int(region.width) * 4
        var result = original
        let origin = (height - Int(region.maxY)) * width * 4 + Int(region.minX) * 4
        result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            foreground.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0..<rows {
                    let offset = origin + row * width * 4
                    LayerBlendMode.normal.composite(
                        UnsafeRawBufferPointer(rebasing: source[(row * rowBytes)..<((row + 1) * rowBytes)]),
                        onto: UnsafeMutableRawBufferPointer(rebasing: target[offset..<(offset + rowBytes)]),
                        opacity: 255
                    )
                }
            }
        }
        return result == original ? nil : layer.withPixels(result)
    }

    private func render(to layer: PaintLayer, primary: CGColor, secondary: CGColor,
                        selection: SelectionOutline?, options: GradientOptions, reversed: Bool) -> PaintLayer? {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let width = layer.image.width, height = layer.image.height
        let colorSpace = layer.workingColorSpace
        guard lengthSquared > 0, let original = layer.straightPixels,
              let a = primary.converted(to: colorSpace, intent: .defaultIntent, options: nil)?.components,
              let b = secondary.converted(to: colorSpace, intent: .defaultIntent, options: nil)?.components,
              a.count >= 4, b.count >= 4 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let region = selection?.bounds.integral.intersection(canvas) ?? canvas
        guard !region.isEmpty else { return nil }
        let rows = Int(region.height), columns = Int(region.width)
        let topRow = height - Int(region.maxY), leftColumn = Int(region.minX)
        let mask = selection?.mask(in: CGRect(x: leftColumn, y: topRow, width: columns, height: rows),
                                   imageHeight: height)
        if selection != nil && mask == nil { return nil }
        var result = original
        var fillRow = Data(count: columns * 4)
        result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            for row in 0..<rows {
                let startIndex = ((topRow + row) * width + leftColumn) * 4
                let destination = UnsafeMutableRawBufferPointer(rebasing: target[startIndex..<(startIndex + columns * 4)])
                fillRow.withUnsafeMutableBytes { (fill: UnsafeMutableRawBufferPointer) in
                    for column in 0..<columns {
                        let byte = column * 4
                        if mask?[row * columns + column] == 0 {
                            fill[byte + 3] = 0
                            continue
                        }
                        let x = CGFloat(leftColumn + column) + 0.5 - start.x
                        let y = CGFloat(height - topRow - row) - 0.5 - start.y
                        let along = (x * dx + y * dy) / lengthSquared
                        let across = (y * dx - x * dy) / lengthSquared
                        let raw = options.position(x: along, y: across)
                        let fraction = reversed ? 1 - raw : raw
                        let keep = 1 - fraction
                        if options.transparency {
                            let multiplier = a[3] * keep + (1 - b[3]) * fraction
                            destination[byte + 3] = UInt8(clamping: Int((CGFloat(destination[byte + 3]) * multiplier).rounded()))
                        } else {
                            for channel in 0..<3 {
                                let value = (a[2 - channel] * keep + b[2 - channel] * fraction) * 255
                                fill[byte + channel] = UInt8(clamping: Int(value.rounded()))
                            }
                            let alpha = (a[3] * keep + b[3] * fraction) * 255
                            fill[byte + 3] = UInt8(clamping: Int(alpha.rounded()))
                        }
                    }
                    if !options.transparency {
                        options.blendMode.composite(UnsafeRawBufferPointer(fill), onto: destination, opacity: 255)
                    }
                }
            }
        }
        return result == original ? nil : layer.withPixels(result)
    }
}
