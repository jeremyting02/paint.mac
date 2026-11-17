import CoreImage

extension RasterFilter {
    static let adjustments: [Self] = [
        autoLevel,
        point("Black and White", accelerate: { source, _, cancelled in
            MetalRasterEffects.grayscale(source, isCancelled: cancelled)
        }) { pixel, _ in
            // Paint.NET weights encoded RGB and rounds the sum in the byte domain.
            let channels = pixel * 255
            let gray = (channels.x * 0.299 + channels.y * 0.587 + channels.z * 0.114).rounded() / 255
            return Pixel(gray, gray, gray, pixel.w)
        },
        point("Brightness / Contrast", [.init("Brightness", -100...100, 0), .init("Contrast", -100...100, 0)],
              accelerate: { source, values, cancelled in
            let brightness = values[0] / 100
            let contrast = (100 + values[1]) / max(1, 100 - values[1])
            let table = channelTable { ($0 - 0.5) * contrast + 0.5 + brightness }
            return MetalRasterEffects.tables([table, table, table], to: source, isCancelled: cancelled)
        }) {
            pixel, values in
            let brightness = values[0] / 100
            let contrast = (100 + values[1]) / max(1, 100 - values[1])
            var output = (pixel - 0.5) * contrast + 0.5 + brightness
            output.w = pixel.w
            return output
        },
        CurveSettings().filter(),
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
        point("Invert Alpha", accelerate: { source, _, cancelled in
            let identity = channelTable { $0 }, inverted = channelTable { 1 - $0 }
            return MetalRasterEffects.tables([identity, identity, identity, inverted], to: source, isCancelled: cancelled)
        }) { pixel, _ in Pixel(pixel.x, pixel.y, pixel.z, 1 - pixel.w) },
        point("Invert Colors", accelerate: { source, _, cancelled in
            let table = channelTable { 1 - $0 }
            return MetalRasterEffects.tables([table, table, table], to: source, isCancelled: cancelled)
        }) { pixel, _ in Pixel(1 - pixel.x, 1 - pixel.y, 1 - pixel.z, pixel.w) },
        LevelSettings().filter(),
        posterize,
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

    private static let posterize = Self("Posterize", [
        .init("Red Levels", 2...64, 16), .init("Green Levels", 2...64, 16), .init("Blue Levels", 2...64, 16),
        .init("Alpha Levels", 2...256, 256)
    ], editor: .posterize) { source, _, _, values, isCancelled in
        let tables = [values[2], values[1], values[0], values[3]].map { levels in
            let count = Int(levels)
            return (0...255).map { byte in
                // The encoded input is divided into equal-width buckets, including alpha.
                let bucket = byte * count / 256
                return UInt8((bucket * 255 + (count - 1) / 2) / (count - 1))
            }
        }
        if let accelerated = MetalRasterEffects.tables(tables, to: source, isCancelled: isCancelled) {
            return accelerated
        }
        var result = source
        let completed = result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                if offset & 0xffff == 0, isCancelled() { return false }
                for channel in 0..<4 {
                    bytes[offset + channel] = tables[channel][Int(bytes[offset + channel])]
                }
            }
            return true
        }
        return completed ? result : nil
    }
}
