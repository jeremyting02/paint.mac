import CoreGraphics
import Foundation
import ImageIO

struct ComparisonError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func readPNG(_ path: String) throws -> (width: Int, height: Int, rgba: [UInt8]) {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) == "public.png" as CFString,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ComparisonError("Could not decode PNG at \(path)")
    }

    let rgb = image.bitsPerPixel == 24 && image.alphaInfo == .none
    let rgbx = image.bitsPerPixel == 32 && image.alphaInfo == .noneSkipLast
    let rgba = image.bitsPerPixel == 32 && image.alphaInfo == .last
    let bytesPerPixel = rgb ? 3 : 4
    guard image.bitsPerComponent == 8,
          image.bitmapInfo.intersection(.byteOrderMask) == .byteOrderDefault,
          image.colorSpace?.name == CGColorSpace.sRGB,
          rgb || rgbx || rgba,
          let storage = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(storage),
          image.bytesPerRow >= image.width * bytesPerPixel,
          CFDataGetLength(storage) >= (image.height - 1) * image.bytesPerRow + image.width * bytesPerPixel else {
        throw ComparisonError("Expected an 8-bit straight RGB or RGBA sRGB PNG at \(path)")
    }

    // Inspect stored channels, including RGB at alpha zero.
    var pixels: [UInt8] = []
    pixels.reserveCapacity(image.width * image.height * 4)
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            pixels += [bytes[offset], bytes[offset + 1], bytes[offset + 2], rgba ? bytes[offset + 3] : 255]
        }
    }
    return (image.width, image.height, pixels)
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw ComparisonError("Usage: swift Tests/compare-paintnet-png.swift EXPECTED.png ACTUAL.png")
    }
    let expected = try readPNG(CommandLine.arguments[1])
    let actual = try readPNG(CommandLine.arguments[2])
    guard actual.width == expected.width, actual.height == expected.height else {
        throw ComparisonError("Expected \(expected.width) × \(expected.height), got \(actual.width) × \(actual.height)")
    }
    let count = actual.width * actual.height
    var mismatches = 0
    for index in stride(from: 0, to: actual.rgba.count, by: 4) {
        let range = index..<(index + 4)
        guard expected.rgba[range] != actual.rgba[range] else { continue }
        if mismatches == 0 {
            let x = (index / 4) % actual.width
            let y = (index / 4) / actual.width
            print("First mismatch at (\(x), \(y)) with expected RGBA \(Array(expected.rgba[range])), got \(Array(actual.rgba[range]))")
        }
        mismatches += 1
    }
    guard mismatches == 0 else {
        throw ComparisonError("\(mismatches) of \(count) pixels differ")
    }
    print("All \(count) pixels match (\(actual.width) × \(actual.height), straight RGBA).")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
