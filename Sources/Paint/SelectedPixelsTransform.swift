import CoreGraphics
import Foundation

final class SelectedPixelsTransform {
    struct PreviewSource {
        let original: Data
        let cleared: Data?
        let selection: CGRect
        let cropped: Data?
        let isPaste: Bool
    }

    private let layer: PaintLayer
    private let source: Data
    // A full-layer cut leaves a transparent backdrop everywhere.
    private let cleared: Data?
    private let selection: CGRect
    private let bounds: CGRect
    private let croppedPixels: Data?
    let isPaste: Bool

    var previewSource: PreviewSource {
        PreviewSource(original: source, cleared: cleared, selection: selection, cropped: croppedPixels, isPaste: isPaste)
    }

    init?(layer: PaintLayer, selection: CGRect, mask: Data? = nil) {
        let width = layer.image.width, height = layer.image.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard !selection.isEmpty, bounds.contains(selection), selection == selection.integral,
              let source = layer.straightPixels else { return nil }
        self.layer = layer
        self.source = source
        self.selection = selection
        self.bounds = bounds
        isPaste = false
        if let mask {
            var foreground = layer
            guard foreground.crop(to: selection, keeping: mask),
                  let pixels = foreground.straightPixels else { return nil }
            croppedPixels = pixels
        } else {
            croppedPixels = nil
        }
        cleared = selection == bounds && mask == nil ? nil : layer.clearing(selection, mask: mask, from: source)
    }

    init?(layer: PaintLayer, pastedImage: CGImage, at destination: CGRect) {
        guard let source = layer.straightPixels,
              destination.size == CGSize(width: pastedImage.width, height: pastedImage.height),
              let foreground = BGRA8.pixels(from: pastedImage, in: layer.workingColorSpace) else { return nil }
        self.layer = layer
        self.source = source
        cleared = source
        selection = destination
        bounds = CGRect(x: 0, y: 0, width: layer.image.width, height: layer.image.height)
        croppedPixels = foreground
        isPaste = true
    }

    func transformed(by transform: CGAffineTransform, copy: Bool = false,
                     sampling: MoveResampler.Mode = .bicubic) -> PaintLayer? {
        if !isPaste && transform.isIdentity { return layer }
        return renderedPixels(in: bounds, by: transform, copy: copy, sampling: sampling).flatMap(layer.withPixels)
    }

    func clearedRegion(by transform: CGAffineTransform, copy: Bool) -> CGRect {
        isPaste || copy || transform.isIdentity ? .null : selection
    }

    func destinationRegion(by transform: CGAffineTransform) -> CGRect {
        !isPaste && transform.isIdentity ? .null : placement(by: transform).target
    }

    func retainedImageOffset(by transform: CGAffineTransform, copy: Bool) -> CGPoint? {
        guard cleared == nil, !copy,
              transform.a == 1, transform.b == 0, transform.c == 0, transform.d == 1,
              transform.tx.isFinite, transform.ty.isFinite,
              transform.tx == transform.tx.rounded(), transform.ty == transform.ty.rounded() else { return nil }
        return CGPoint(x: transform.tx, y: transform.ty)
    }

    private func placement(by transform: CGAffineTransform)
        -> (target: CGRect, destination: CGRect, translationOnly: Bool) {
        let height = CGFloat(layer.image.height)
        let sourceRect = CGRect(x: selection.minX, y: height - selection.maxY,
                                width: selection.width, height: selection.height)
        let transformedRect = sourceRect.applying(transform)
        let destination = CGRect(x: transformedRect.minX, y: height - transformedRect.maxY,
                                 width: transformedRect.width, height: transformedRect.height)
        let translationOnly = transform.a == 1 && transform.b == 0 && transform.c == 0 && transform.d == 1
        // Avoid expanding exact pixel edges due to trigonometric rounding.
        let renderBounds = translationOnly ? destination : destination.insetBy(dx: 1e-9, dy: 1e-9)
        return (renderBounds.integral.intersection(bounds), destination, translationOnly)
    }

    func renderedPixels(in region: CGRect, by transform: CGAffineTransform, copy: Bool,
                        sampling: MoveResampler.Mode) -> Data? {
        guard !region.isEmpty, bounds.contains(region), region == region.integral else { return nil }
        let width = layer.image.width
        let identity = !isPaste && transform.isIdentity
        let base = copy || identity ? source : cleared
        let stride = Int(region.width) * 4
        var pixels = (region == bounds ? base : nil) ?? Data(count: stride * Int(region.height))
        if region != bounds, let base {
            pixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                base.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                    let first = (Int(region.minY) * width + Int(region.minX)) * 4
                    for row in 0..<Int(region.height) {
                        output.baseAddress!.advanced(by: row * stride).copyMemory(
                            from: input.baseAddress!.advanced(by: first + row * width * 4), byteCount: stride
                        )
                    }
                }
            }
        }
        if identity { return pixels }
        let (placement, destination, translationOnly) = placement(by: transform)
        let target = placement.intersection(region)
        if !target.isEmpty {
            let rowBytes = Int(target.width) * 4
            let targetStart = Int(target.minY - region.minY) * stride + Int(target.minX - region.minX) * 4
            let sampled: Data
            let sampledStart: Int
            let sampledStride: Int
            let foreground = croppedPixels ?? source
            let foregroundStride = (croppedPixels == nil ? width : Int(selection.width)) * 4
            let foregroundStart = croppedPixels == nil
                ? Int(selection.minY) * foregroundStride + Int(selection.minX) * 4 : 0
            if translationOnly && destination == destination.integral {
                let x = Int(target.minX - destination.minX), y = Int(target.minY - destination.minY)
                sampled = foreground
                sampledStride = foregroundStride
                sampledStart = foregroundStart + y * foregroundStride + x * 4
            } else {
                guard let result = MoveResampler.sample(foreground, stride: foregroundStride, start: foregroundStart,
                                                        selection: selection, transform: transform, region: target,
                                                        canvasHeight: layer.image.height, mode: sampling) else { return nil }
                sampled = result
                sampledStride = rowBytes
                sampledStart = 0
            }
            pixels.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                sampled.withUnsafeBytes { (original: UnsafeRawBufferPointer) in
                    for row in 0..<Int(target.height) {
                        let start = targetStart + row * stride
                        let sourceStart = sampledStart + row * sampledStride
                        LayerBlendMode.normal.composite(
                            UnsafeRawBufferPointer(rebasing: original[sourceStart..<(sourceStart + rowBytes)]),
                            onto: UnsafeMutableRawBufferPointer(rebasing: destination[start..<(start + rowBytes)]),
                            opacity: 255
                        )
                    }
                }
            }
        }
        return pixels
    }
}
