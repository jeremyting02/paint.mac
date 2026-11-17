import AppKit
import Metal

setbuf(stdout, nil)

let width = 4096, height = 2048
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
let rect = bounds.insetBy(dx: 160, dy: 120)
var pixels = Data(count: width * height * 4)
pixels.withUnsafeMutableBytes { bytes in
    let values = bytes.bindMemory(to: UInt32.self)
    for y in 0..<height {
        for x in 0..<width {
            values[y * width + x] = x > width * 3 / 4 ? 0xff00_ff00 : 0x9e90_5020 | UInt32((x + y) % 31)
        }
    }
}
let layer = PaintLayer(name: "Benchmark", image: BGRA8.image(from: pixels, width: width, height: height)!,
                       pdnPixels: pixels)
let selection = SelectionOutline(path: CGPath(ellipseIn: rect, transform: nil))!
let selectionMask = selection.mask(in: rect, imageHeight: height)!
let color = SIMD4<UInt8>(14, 95, 173, 193)
let gradient = LinearGradient(start: CGPoint(x: 12, y: 12), end: CGPoint(x: width - 13, y: height - 13))
let primary = CGColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 0.8)
let secondary = CGColor(srgbRed: 0.7, green: 0.1, blue: 0.4, alpha: 0.9)
let vector = VectorDrawing.shape(rect, angle: 0.06)
var style = DrawingStyle()
style.fill = .fill
style.primary = NSColor(cgColor: primary)!
style.blendMode = .overlay
var flood = FloodSettings()
flood.flood = .global
flood.tolerance = 24

guard let device = MTLCreateSystemDefaultDevice(),
      MetalRasterTools.floodMask(pixels: pixels, seedIndex: 0, limit: 0, within: nil) != nil,
      MetalRasterTools.fill(pixels, width: width, rect: rect, mask: selectionMask, color: color) != nil else {
    fputs("Metal raster tool kernels are unavailable\n", stderr)
    exit(1)
}

func measure<T: Equatable>(_ name: String, _ operation: (Bool) -> T?) {
    let before = autoreleasepool { operation(false) }
    let after = autoreleasepool { operation(true) }
    precondition(before != nil && before == after, "\(name) CPU and Metal results differ")
    var samples = [[Double](), [Double]()]
    for index in 0..<9 {
        for mode in [index % 2, 1 - index % 2] {
            let start = DispatchTime.now().uptimeNanoseconds
            autoreleasepool { precondition(operation(mode != 0) != nil) }
            samples[mode].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
    }
    print(String(format: "%@ CPU %.3f ms, Metal %.3f ms", name, samples[0].sorted()[4], samples[1].sorted()[4]))
}

print("\(device.name), \(width) × \(height), median of 9 alternating trials")
measure("Global color select") { flood.select(in: layer, x: 0, y: 0, allowsMetal: $0) }
measure("Masked fill") {
    layer.filling(selection, blue: color.x, green: color.y, red: color.z, alpha: color.w,
                  allowsMetal: $0)?.straightPixels
}
measure("Masked clear") { layer.clearing(rect, mask: selectionMask, from: pixels, allowsMetal: $0) }
measure("Masked linear gradient") {
    gradient.applying(to: layer, primary: primary, secondary: secondary, selection: selection,
                      allowsMetal: $0)?.straightPixels
}
measure("Vector overlay") { vector.applying(to: layer, selection: nil, style: style, allowsMetal: $0)?.straightPixels }

let ink = DrawingColor(NSColor(srgbRed: 0.72, green: 0.95, blue: 0.43, alpha: 0.85))
let base = DrawingColor(NSColor(srgbRed: 0.56, green: 0.31, blue: 0.16, alpha: 0.6))
var options = BrushOptions()
options.smoothed = false
options.pattern = .checkerboard
options.blend = .layer(.overlay)
for antialiased in [false, true] {
    options.antialiased = antialiased
    for operation in [RasterDrawing.Operation.paint(primary: ink, secondary: base), .erase(opacity: 193),
                      .clone(source: pixels, offset: CGPoint(x: 187, y: -93), opacity: 237),
                      .recolor(from: base, to: ink, tolerance: 40)] {
        measure("\(operation.title), 1024 px \(antialiased ? "hard AA" : "aliased") tip") { metal in
            let drawing = RasterDrawing(layer: layer, operation: operation, diameter: 1024, selection: nil,
                                        options: options, allowsMetal: metal)!
            for step in 0..<5 {
                drawing.append(CGPoint(x: CGFloat(1200 + step * 290) + 0.25, y: CGFloat(550 + step * 185) + 0.75))
            }
            drawing.finish()
            precondition(!metal || drawing.metalStamps > 0, "\(operation.title) did not run on Metal")
            return drawing.pixels(in: bounds)
        }
    }
}
