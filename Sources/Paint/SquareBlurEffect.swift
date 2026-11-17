import Foundation

enum SquareBlurEffect {
    static let filter = RasterFilter("Square Blur", category: "Blurs", [.init("Radius", 0...100, 4)],
                                     renderInColorSpace: { source, width, height, colorSpace, _, values, isCancelled in
        let radius = Int(values[0])
        guard radius > 0 else { return source }
        let transfer = LinearEffectTransfer(colorSpace: colorSpace)
        return blur(source, width: width, height: height, radius: radius, transfer: transfer, isCancelled: isCancelled)
    })

    private static func mirror(_ index: Int, count: Int) -> Int {
        let period = count * 2
        let wrapped = (index % period + period) % period
        return wrapped < count ? wrapped : period - 1 - wrapped
    }

    private static func blur(_ pixels: Data, width: Int, height: Int, radius: Int,
                             transfer: LinearEffectTransfer, isCancelled: () -> Bool) -> Data? {
        let diameter = 2 * radius + 1
        let area = Double(diameter * diameter)
        var result = Data(count: pixels.count)
        let finished = pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                // Retain only one row of vertical sums. Each pass slides the square by one pixel.
                var columns = [SIMD4<Double>](repeating: .zero, count: width)
                for dy in -radius...radius {
                    if isCancelled() { return false }
                    let row = mirror(dy, count: height) * width * 4
                    for x in 0..<width {
                        columns[x] += transfer.premultipliedPixel(in: source, at: row + x * 4)
                    }
                }

                for y in 0..<height {
                    if isCancelled() { return false }
                    var sum = SIMD4<Double>.zero
                    for dx in -radius...radius {
                        sum += columns[mirror(dx, count: width)]
                    }
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        let alpha = UInt8(clamping: Int((sum.w * 255 / area).rounded(.toNearestOrEven)))
                        target[offset + 3] = alpha
                        if alpha > 0 {
                            for channel in 0..<3 {
                                target[offset + channel] = transfer.encode(sum[channel] / sum.w, channel: channel)
                            }
                        }
                        sum -= columns[mirror(x - radius, count: width)]
                        sum += columns[mirror(x + radius + 1, count: width)]
                    }

                    let outgoing = mirror(y - radius, count: height) * width * 4
                    let incoming = mirror(y + radius + 1, count: height) * width * 4
                    for x in 0..<width {
                        columns[x] -= transfer.premultipliedPixel(in: source, at: outgoing + x * 4)
                        columns[x] += transfer.premultipliedPixel(in: source, at: incoming + x * 4)
                    }
                }
                return true
            }
        }
        return finished ? result : nil
    }
}
