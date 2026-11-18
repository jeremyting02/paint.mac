import CoreImage

extension RasterFilter {
    static let effects = (primaryEffects + spatialEffects + renderEffects + colorEffects + artisticEffects
                          + distortionEffects + blurEffects).sorted { $0.title < $1.title }

    private static let primaryEffects: [Self] = [
        coreImage("Gaussian Blur", category: "Blurs", [.init("Radius", 0...200, 2)]) { image, values in
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: values[0]])
        },
        coreImage("Sharpen", category: "Photo", [.init("Amount", 0...100, 25)]) { image, values in
            image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": values[0] / 50])
        },
        coreImage("Vignette", category: "Photo", [.init("Intensity", 0...100, 50), .init("Radius", 0...100, 50)]) {
            image, values in
            image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: values[0] / 25,
                kCIInputRadiusKey: values[1] * min(image.extent.width, image.extent.height) / 100
            ])
        },
        coreImage("Edge Detect", category: "Stylize", [.init("Intensity", 0...100, 25)]) { image, values in
            image.clampedToExtent().applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: values[0] / 10])
        },
        coreImage("Emboss", category: "Stylize", [.init("Angle", -180...180, 45)]) { image, values in
            let direction = values[0] * .pi / 180
            let x = cos(direction), y = sin(direction)
            let weights = CIVector(values: [-x - y, -y, x - y, -x, 0, x, -x + y, y, x + y], count: 9)
            return image.clampedToExtent().applyingFilter("CIConvolutionRGB3X3",
                                                           parameters: ["inputWeights": weights, "inputBias": 0.5])
        }
    ]
}
