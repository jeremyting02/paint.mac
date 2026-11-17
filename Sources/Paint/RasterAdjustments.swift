import CoreImage

extension RasterFilter {
    static let adjustments: [Self] = [
        autoLevel,
        point("Black and White") { pixel, _ in
            // Paint.NET weights encoded RGB and rounds the sum in the byte domain.
            let channels = pixel * 255
            let gray = (channels.x * 0.299 + channels.y * 0.587 + channels.z * 0.114).rounded() / 255
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
        point("Invert Alpha") { pixel, _ in Pixel(pixel.x, pixel.y, pixel.z, 1 - pixel.w) },
        point("Invert Colors") { pixel, _ in Pixel(1 - pixel.x, 1 - pixel.y, 1 - pixel.z, pixel.w) },
        LevelSettings().filter(),
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
}
