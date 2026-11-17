import Foundation

guard let device = MetalRasterEffects.deviceName else {
    fputs("Metal effect kernels are unavailable\n", stderr)
    exit(1)
}
setbuf(stdout, nil)
print("Metal device: \(device)")

let width = 2048, height = 1024
var pixels = Data(count: width * height * 4)
pixels.withUnsafeMutableBytes { bytes in
    let words = bytes.bindMemory(to: UInt32.self)
    for i in words.indices {
        words[i] = UInt32(truncatingIfNeeded: i &* 2_654_435_761 &+ (i >> 3) &* 9_732_697)
    }
}
let mask = Data((0..<(width * height)).map { $0 % 7 == 0 ? UInt8(0) : 255 })
let image = BGRA8.image(from: pixels, width: width, height: height)!
let input = RasterFilter.Input(layer: PaintLayer(name: "Benchmark", image: image, pdnPixels: pixels),
                               selection: nil)!

func median<T>(metal: Bool, _ operation: () -> T) -> (Double, T) {
    MetalRasterEffects.$enabled.withValue(metal) {
        let warm = operation()
        let durations = (0..<5).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            autoreleasepool { _ = operation() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        return (durations.sorted()[durations.count / 2], warm)
    }
}

func report(_ title: String, cpu: Double, metal: Double) {
    print(String(format: "%@ / %dx%d / CPU %.3f ms / Metal %.3f ms / %.2fx",
                 title, width, height, cpu, metal, cpu / metal))
}

let (histogramCPU, cpuBins) = median(metal: false) { ChannelHistogram(pixels: pixels, mask: mask).bins }
let (histogramMetal, metalBins) = median(metal: true) { ChannelHistogram(pixels: pixels, mask: mask).bins }
precondition(cpuBins == metalBins)
report("Masked RGB Histogram", cpu: histogramCPU, metal: histogramMetal)

var levels = LevelSettings()
levels.set(.gamma, to: 1.37, channels: Set(RGBChannel.allCases))
var curves = CurveSettings()
curves.luminosity.setPoint(.init(input: 110, output: 143))
var rgbCurves = curves
rgbCurves.mode = .rgb
rgbCurves.rgb[1].setPoint(.init(input: 117, output: 139))
let rasterFilters: [(String, RasterFilter, [Double], Bool)] = [
    ("Levels", levels.filter(), [], true), ("Luminosity Curves", curves.filter(), [], true),
    ("RGB Curves", rgbCurves.filter(), [], true), ("Auto-Level", RasterFilter.autoLevel, [], true),
    ("Posterize", RasterFilter.adjustments.first { $0.title == "Posterize" }!, [24, 15, 32, 128], true),
    ("Ordered Dither", RasterFilter.renderEffects.first { $0.title == "Ordered Dither" }!, [8], true),
    ("Square Blur", SquareBlurEffect.filter, [16, 0.32], false),
    ("Pixelate (Multisample Bilinear / Nearest)", PixelateEffect.filter, [4, 2, 2], false),
    ("Outline", RasterFilter.distortionEffects.first { $0.title == "Outline" }!, [3, 50, 8], true)
] + ["Black and White", "Brightness / Contrast", "Invert Alpha", "Invert Colors"].map { title in
    (title, RasterFilter.adjustments.first { $0.title == title }!, title == "Brightness / Contrast" ? [23, 19] : [], true)
} + (RasterFilter.renderEffects.filter { $0.title != "Ordered Dither" } +
     RasterFilter.distortionEffects.filter { $0.title != "Outline" } + RasterFilter.blurEffects).map {
    ($0.title, $0, $0.controls.map(\.initial), false)
}

for (title, filter, values, exact) in rasterFilters {
    let (cpuTime, cpu) = median(metal: false) { input.render(filter, values: values)!.straightPixels! }
    let (metalTime, accelerated) = median(metal: true) {
        input.render(filter, values: values, preview: !exact)!.straightPixels!
    }
    if exact { precondition(cpu == accelerated, "\(title) failed byte parity") }
    report(title, cpu: cpuTime, metal: metalTime)
}
