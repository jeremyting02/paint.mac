import Foundation

func pixels(width: Int, height: Int) -> Data {
    var result = Data(count: width * height * 4)
    result.withUnsafeMutableBytes { raw in
        for index in 0..<(width * height) {
            let mixed = UInt32(index) &* 2_654_435_761
            raw.storeBytes(of: mixed.littleEndian, toByteOffset: index * 4, as: UInt32.self)
        }
    }
    return result
}

func compare(_ label: String, exact: Bool, cpu: () -> Data?, gpu: () -> Data?) {
    guard let expected = cpu(), let actual = gpu(), expected.count == actual.count else {
        fatalError("Could not render \(label)")
    }
    if exact {
        let firstDifference = zip(expected, actual).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        precondition(firstDifference == nil, "\(label) changed CPU output at byte \(String(describing: firstDifference))")
    }
    func measure(_ render: () -> Data?) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let output = autoreleasepool { render() }
        let millis = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        precondition(output?.count == expected.count)
        return millis
    }
    var cpuTimes: [Double] = [], gpuTimes: [Double] = []
    for _ in 0..<7 {
        cpuTimes.append(measure(cpu))
        gpuTimes.append(measure(gpu))
    }
    let cpuMedian = cpuTimes.sorted()[cpuTimes.count / 2]
    let gpuMedian = gpuTimes.sorted()[gpuTimes.count / 2]
    print(String(format: "%@: CPU %.2f ms, Metal %.2f ms, %.2fx speedup", label, cpuMedian, gpuMedian,
                 cpuMedian / gpuMedian))
}

guard let device = MetalRasterGeometry.deviceName else {
    fatalError("Metal geometry is unavailable")
}
print("Metal device: \(device)")
let width = 2048, height = 1536
let source = pixels(width: width, height: height)
for (mode, linear) in [(ImageResampler.Mode.nearest, false), (.lanczos, false), (.lanczos, true)] {
    let destination = (width: 1536, height: 1152)
    let resampler = ImageResampler(sourceWidth: width, sourceHeight: height, width: destination.width,
                                   height: destination.height, mode: mode, linearLight: linear)
    compare("Resize 2048x1536 to 1536x1152 / \(mode.rawValue) / \(linear ? "linear" : "encoded")", exact: true,
            cpu: { resampler.resample(source, useMetal: false) },
            gpu: { resampler.resampleOnMetal(source) })
}
for (label, settings) in [
    ("bilinear tilt, 3x3 samples", [17.3, 28.5, 26.0, 3.25, -4.25, 108.5, 3, 2, 0]),
    ("nearest, 1 sample", [17.3, 0, 0, 3.25, -4.25, 108.5, 1, 1, 1])
] {
    compare("Rotate / Zoom preview 2048x1536 / \(label)", exact: false,
            cpu: { LayerRotateZoom.render(source, width, height, settings, { false }) },
            gpu: { LayerRotateZoom.renderOnMetal(source, width, height, settings, { false }) })
}

guard MetalPaletteQuantizer.deviceName != nil else { fatalError("Metal quantization is unavailable") }
for dither in [0.0, 0.63] {
    compare("Quantize / Dither 2048x1536 / 64 colors / \(Int(dither * 100))% dither", exact: true,
            cpu: { PaletteQuantizer.apply(source, width: width, height: height, count: 64, dither: dither,
                                          useMetal: false, isCancelled: { false }) },
            gpu: { PaletteQuantizer.apply(source, width: width, height: height, count: 64, dither: dither,
                                          isCancelled: { false }) })
}
