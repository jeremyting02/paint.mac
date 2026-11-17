import CoreImage

extension RasterFilter {
    static let spatialEffects: [Self] = [
        coreImage("Bulge", category: "Distort", [
            .init("Amount", -100...100, 50), .init("Radius", 1...100, 50)
        ]) { image, values in
            image.applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: center(of: image),
                kCIInputRadiusKey: radius(in: image, percent: values[1]), kCIInputScaleKey: values[0] / 100
            ])
        },
        coreImage("Crystalize", category: "Distort", [.init("Cell Size", 1...200, 15)]) { image, values in
            image.clampedToExtent().applyingFilter("CICrystallize", parameters: [
                kCIInputCenterKey: center(of: image), kCIInputRadiusKey: values[0]
            ])
        },
        coreImage("Morphology", category: "Distort", [.init("Radius", -50...50, 1)]) { image, values in
            if values[0] == 0 { return image }
            return image.clampedToExtent().applyingFilter(values[0] > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum",
                                                         parameters: [kCIInputRadiusKey: abs(values[0])])
        },
        coreImage("Pixelate", category: "Distort", [.init("Cell Size", 1...200, 8)]) { image, values in
            if values[0] == 1 { return image }
            let size = values[0]
            return image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: size, kCIInputCenterKey: CIVector(x: size / 2, y: image.extent.maxY - size / 2)
            ])
        },
        coreImage("Spherize", category: "Distort", [.init("Radius", 1...100, 60),
                                                   .init("Refraction", 1...3, 1.5, step: 0.01)]) { image, values in
            image.applyingFilter("CIGlassLozenge", parameters: [
                "inputPoint0": center(of: image), "inputPoint1": CIVector(x: image.extent.midX + 0.01, y: image.extent.midY),
                kCIInputRadiusKey: radius(in: image, percent: values[0]), "inputRefraction": values[1]
            ])
        },
        coreImage("Tile Reflection", category: "Distort", [.init("Tile Size", 1...200, 40),
                                                         .init("Angle", -180...180, 30)]) { image, values in
            image.applyingFilter("CIFourfoldReflectedTile", parameters: [
                kCIInputCenterKey: center(of: image), kCIInputWidthKey: values[0],
                kCIInputAngleKey: values[1] * .pi / 180
            ])
        },
        coreImage("Twist", category: "Distort", [.init("Angle", -720...720, 90),
                                                .init("Radius", 1...100, 70)]) { image, values in
            image.applyingFilter("CITwirlDistortion", parameters: [
                kCIInputCenterKey: center(of: image),
                kCIInputRadiusKey: radius(in: image, percent: values[1]), kCIInputAngleKey: values[0] * .pi / 180
            ])
        },
        coreImage("Drop Shadow", category: "Object", [
            .init("Offset X", -200...200, 4), .init("Offset Y", -200...200, 4),
            .init("Blur Radius", 0...100, 4), .init("Opacity", 0...100, 80)
        ]) { image, values in
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            let alpha = CIVector(x: 0, y: 0, z: 0, w: values[3] / 100)
            let shadow = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": zero, "inputGVector": zero, "inputBVector": zero, "inputAVector": alpha
            ])
                .transformed(by: CGAffineTransform(translationX: values[0], y: -values[1]))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: values[2]])
            return image.composited(over: shadow)
        },
        coreImage("Straighten", category: "Photo", [.init("Angle", -45...45, 0, step: 0.1)]) { image, values in
            image.applyingFilter("CIStraightenFilter", parameters: [kCIInputAngleKey: values[0] * .pi / 180])
        },
        coreImage("Glow", category: "Photo", [.init("Radius", 0...100, 6),
                                            .init("Intensity", 0...100, 45)]) { image, values in
            image.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: values[0], kCIInputIntensityKey: values[1] / 100
            ])
        },
        coreImage("Soften Portrait", category: "Photo", [.init("Softness", 0...50, 4),
                                                       .init("Warmth", 0...100, 15)]) { image, values in
            image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": values[0] / 100, "inputSharpness": 0.15
            ]).applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: values[1] / 100])
        },
        coreImage("Reduce Noise", category: "Noise", [.init("Strength", 0...100, 20),
                                                     .init("Sharpness", 0...100, 40)]) { image, values in
            image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": values[0] / 100, "inputSharpness": values[1] / 100
            ])
        },
        coreImage("Square Blur", category: "Blurs", [.init("Radius", 0...100, 4)]) { image, values in
            image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: values[0]])
        },
        coreImage("Bokeh Blur", category: "Blurs", [.init("Radius", 0...100, 8),
                                                   .init("Highlight Threshold", 0...100, 80)]) { image, values in
            image.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
                kCIInputRadiusKey: values[0], "inputRingAmount": 0.2, "inputRingSize": 0.15,
                "inputSoftness": values[1] / 100
            ])
        },
        coreImage("Zoom Blur", category: "Blurs", [.init("Amount", 0...100, 10),
                                                 .init("Center X", 0...100, 50), .init("Center Y", 0...100, 50)]) { image, values in
            let point = CIVector(x: image.extent.width * values[1] / 100, y: image.extent.height * (1 - values[2] / 100))
            return image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: point, "inputAmount": values[0]
            ])
        },
        coreImage("Ink Sketch", category: "Artistic", [.init("Ink Outline", 0...100, 50),
                                                     .init("Coloring", 0...100, 50)]) { image, values in
            image.clampedToExtent().applyingFilter("CIComicEffect")
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 0.75 + values[0] / 200, kCIInputSaturationKey: values[1] / 50
                ])
        },
        coreImage("Pointillism", category: "Artistic", [.init("Dot Size", 1...100, 15)]) { image, values in
            image.clampedToExtent().applyingFilter("CIPointillize", parameters: [
                kCIInputRadiusKey: values[0], kCIInputCenterKey: center(of: image)
            ])
        },
        coreImage("Halftone", category: "Stylize", [.init("Dot Size", 1...50, 8),
                                                  .init("Angle", -180...180, 45)]) { image, values in
            image.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: center(of: image), kCIInputAngleKey: values[1] * .pi / 180,
                kCIInputWidthKey: values[0], kCIInputSharpnessKey: 0.75
            ])
        }
    ]

    private static func center(of image: CIImage) -> CIVector {
        CIVector(x: image.extent.midX, y: image.extent.midY)
    }

    private static func radius(in image: CIImage, percent: Double) -> Double {
        max(1, min(image.extent.width, image.extent.height) * percent / 200)
    }
}
