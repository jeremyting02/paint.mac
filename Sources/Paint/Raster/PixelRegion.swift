import CoreGraphics
import Foundation

enum PixelRegion {
    static func read(_ pixels: Data, width: Int, region: CGRect) -> Data {
        var bytes = Data(count: Int(region.width) * Int(region.height) * 4)
        bytes.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            copy(pixels, sourceWidth: width, sourceOrigin: region.origin, to: target,
                 targetWidth: Int(region.width), targetOrigin: .zero, size: region.size)
        }
        return bytes
    }

    static func copy(_ pixels: Data, sourceWidth: Int, sourceOrigin: CGPoint,
                     to target: UnsafeMutableRawBufferPointer, targetWidth: Int, targetOrigin: CGPoint,
                     size: CGSize) {
        let sourceStart = Int(sourceOrigin.y) * sourceWidth + Int(sourceOrigin.x)
        let targetStart = Int(targetOrigin.y) * targetWidth + Int(targetOrigin.x)
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for row in 0..<Int(size.height) {
                let input = (sourceStart + row * sourceWidth) * 4
                let output = (targetStart + row * targetWidth) * 4
                target.baseAddress!.advanced(by: output).copyMemory(
                    from: source.baseAddress!.advanced(by: input), byteCount: Int(size.width) * 4
                )
            }
        }
    }
}
