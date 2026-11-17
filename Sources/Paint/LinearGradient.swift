import CoreGraphics
import Foundation

struct LinearGradient {
    var start: CGPoint
    var end: CGPoint

    func applying(to layer: PaintLayer, primary: CGColor, secondary: CGColor,
                  selection: SelectionOutline?) -> PaintLayer? {
        guard start != end, let original = layer.straightPixels,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [primary, secondary] as CFArray, locations: nil) else { return nil }
        let width = layer.image.width, height = layer.image.height
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let region = selection?.bounds.integral.intersection(canvas) ?? canvas
        guard !region.isEmpty else { return nil }
        let rowBytes = Int(region.width) * 4
        let rows = Int(region.height)
        guard let foreground = BGRA8.render(width: Int(region.width), height: rows, draw: { context in
            context.translateBy(x: -region.minX, y: -region.minY)
            if let selection {
                context.addPath(selection.path)
                context.clip(using: .evenOdd)
            }
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }) else { return nil }

        // Blend straight-alpha pixels into the original bytes so untouched PDN pixels stay exact.
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
}
