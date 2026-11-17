import CoreImage

extension RasterFilter {
    static let adjustments: [Self] = [
        autoLevel,
        point("Black and White") { pixel, _ in
            let gray = luminance(pixel)
            return Pixel(gray, gray, gray, pixel.w)
        },
        point("Brightness / Contrast", [.init("Brightness", -100...100, 0), .init("Contrast", -100...100, 0)]) {
            pixel, values in
            let brightness = values[0] / 100
            let contrast = (100 + values[1]) / max(1, 100 - values[1])
            var output = (pixel - 0.5) * contrast + 0.5 + brightness
            output.w = pixel.w
            return output
        },
        point("Curves", [.init("Quarter tones", 0...255, 64), .init("Midtones", 0...255, 128),
                         .init("Three-quarter tones", 0...255, 191)]) { pixel, values in
            let points = [0, values[0], values[1], values[2], 255]
            let stops = [0.0, 64, 128, 191, 255]
            var output = pixel
            for channel in 0..<3 {
                let value = pixel[channel] * 255
                let index = stops.dropFirst().firstIndex { value <= $0 }.map { $0 - 1 } ?? 3
                let t = (value - stops[index]) / (stops[index + 1] - stops[index])
                output[channel] = (points[index] + t * (points[index + 1] - points[index])) / 255
            }
            return output
        },
        coreImage("Exposure", [.init("Exposure (EV)", -8...8, 0, step: 0.01)]) { image, values in
            image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: values[0]])
        },
        coreImage("Highlights / Shadows", [.init("Highlights", -100...100, 0), .init("Shadows", -100...100, 0)]) {
            image, values in
            image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + values[0] / 100,
                "inputShadowAmount": values[1] / 100
            ])
        },
        coreImage("Hue / Saturation", [.init("Hue", -180...180, 0), .init("Saturation", 0...200, 100),
                                       .init("Lightness", -100...100, 0)]) { image, values in
            image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: values[0] * .pi / 180])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: values[1] / 100, kCIInputBrightnessKey: values[2] / 100
                ])
        },
        point("Invert Alpha") { pixel, _ in Pixel(pixel.x, pixel.y, pixel.z, 1 - pixel.w) },
        point("Invert Colors") { pixel, _ in Pixel(1 - pixel.x, 1 - pixel.y, 1 - pixel.z, pixel.w) },
        point("Levels", [.init("Input Black", 0...254, 0), .init("Input White", 1...255, 255),
                         .init("Gamma", 0.1...10, 1, step: 0.01),
                         .init("Output Black", 0...255, 0), .init("Output White", 0...255, 255)]) { pixel, values in
            let black = min(values[0], values[1] - 1)
            let range = values[1] - black
            var output = pixel
            for channel in 0..<3 {
                let level = min(1, max(0, (pixel[channel] * 255 - black) / range))
                output[channel] = (values[3] + pow(level, 1 / values[2]) * (values[4] - values[3])) / 255
            }
            return output
        },
        point("Posterize", [.init("Red Levels", 2...64, 16), .init("Green Levels", 2...64, 16),
                            .init("Blue Levels", 2...64, 16)]) { pixel, values in
            var output = pixel
            for channel in 0..<3 {
                let steps = values[channel] - 1
                output[channel] = (pixel[channel] * steps).rounded() / steps
            }
            return output
        },
        coreImage("Sepia", [.init("Intensity", 0...100, 100)]) { image, values in
            image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: values[0] / 100])
        },
        coreImage("Temperature and Tint", [.init("Temperature", 1000...15000, 6500, step: 50),
                                           .init("Tint", -150...150, 0)]) { image, values in
            image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: values[0], y: values[1])
            ])
        }
    ]

    private static let autoLevel = Self("Auto-Level") { source, _, _, _ in
        var minimum = [UInt8](repeating: 255, count: 3)
        var maximum = [UInt8](repeating: 0, count: 3)
        source.withUnsafeBytes { (pixels: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
                for channel in 0..<3 {
                    minimum[channel] = min(minimum[channel], pixels[index + channel])
                    maximum[channel] = max(maximum[channel], pixels[index + channel])
                }
            }
        }
        var result = source
        result.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
                for channel in 0..<3 where maximum[channel] > minimum[channel] {
                    let low = Int(minimum[channel])
                    let range = Int(maximum[channel]) - low
                    let value = (Int(pixels[index + channel]) - low) * 255
                    pixels[index + channel] = UInt8((value + range / 2) / range)
                }
            }
        }
        return result
    }
}
