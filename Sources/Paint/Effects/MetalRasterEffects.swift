import Foundation
import Metal

enum MetalRasterEffects {
    @TaskLocal static var enabled = true
    private static let minimumPixels = 65_536

    private enum Kernel: String, CaseIterable {
        case rasterTable, rasterLuminosity, rasterHistogram, rasterDither, rasterProcedural
        case rasterSquareBlurVertical, rasterSquareBlurHorizontal
        case rasterDistortion, rasterCustomBlur, rasterPixelate
    }

    private struct Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipelines: [Kernel: MTLComputePipelineState]

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let options = MTLCompileOptions()
            if #available(macOS 15, *) { options.mathMode = .safe }
            else { options.fastMathEnabled = false }
            guard let library = try? device.makeLibrary(source: metalRasterEffectShader, options: options) else { return nil }
            var pipelines: [Kernel: MTLComputePipelineState] = [:]
            for kernel in Kernel.allCases {
                guard let function = library.makeFunction(name: kernel.rawValue),
                      let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
                pipelines[kernel] = pipeline
            }
            self.device = device
            self.queue = queue
            self.pipelines = pipelines
        }

        func buffer(_ bytes: Data) -> MTLBuffer? {
            bytes.withUnsafeBytes { raw in
                guard let address = raw.baseAddress, !raw.isEmpty else { return nil }
                return device.makeBuffer(bytes: address, length: raw.count, options: .storageModeShared)
            }
        }
    }

    private static let engine = Engine()
    static var deviceName: String? { engine?.device.name }

    // For each B/G pair there is at most one integer R in 0...255 for which
    // (2126*R + 7152*G + 722*B) / 10000 lies exactly on a rounding boundary.
    // Solve the congruence using the inverse of 1063 modulo 5000 (127), then
    // use the same Double operations as the CPU to resolve the tie.
    private static let luminosityTies = Data((0..<65_536).map { index in
        let blue = index >> 8, green = index & 255
        let remainder = ((2500 - 3576 * green - 361 * blue) % 5000 + 5000) % 5000
        let red = remainder * 127 % 5000
        guard red <= 255 else { return UInt8(0) }
        return UInt8((0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)).rounded())
    })

    // The Black and White adjustment has different weights and normalizes its input before computing intensity.
    private static let grayscaleTies = Data((0..<65_536).map { index in
        let blue = index >> 8, green = index & 255
        let remainder = ((500 - 587 * green - 114 * blue) % 1000 + 1000) % 1000
        let red = remainder * 699 % 1000 // Inverse of 299 modulo 1000.
        guard red <= 255 else { return UInt8(0) }
        let channels = (SIMD3(Double(red), Double(green), Double(blue)) / 255) * 255
        return UInt8((channels.x * 0.299 + channels.y * 0.587 + channels.z * 0.114).rounded())
    })

    static func tables(_ tables: [[UInt8]], to pixels: Data, skipTransparent: Bool = false,
                       isCancelled: () -> Bool) -> Data? {
        guard enabled, pixels.count / 4 >= minimumPixels, tables.count == 3 || tables.count == 4,
              tables.allSatisfy({ $0.count == 256 }) else { return nil }
        let descriptor = SIMD4(UInt32(pixels.count / 4), skipTransparent ? 1 : 0, UInt32(tables.count), 0)
        return map(.rasterTable, pixels: pixels, auxiliary: Data(tables.joined()), descriptor: descriptor,
                   isCancelled: isCancelled)
    }

    static func grayscale(_ pixels: Data, isCancelled: () -> Bool) -> Data? {
        guard enabled, pixels.count / 4 >= minimumPixels, !isCancelled() else { return nil }
        return map(.rasterLuminosity, pixels: pixels, auxiliary: grayscaleTies,
                   descriptor: SIMD4(UInt32(pixels.count / 4), 1, 0, 0), isCancelled: isCancelled)
    }

    static func luminosity(_ table: [UInt8], to pixels: Data, isCancelled: () -> Bool) -> Data? {
        guard enabled, pixels.count / 4 >= minimumPixels, table.count == 256, !isCancelled() else { return nil }
        var auxiliary = Data(table)
        auxiliary.append(luminosityTies)
        return map(.rasterLuminosity, pixels: pixels, auxiliary: auxiliary, descriptor: SIMD4(UInt32(pixels.count / 4), 0, 0, 0),
                   isCancelled: isCancelled)
    }

    static func orderedDither(_ pixels: Data, width: Int, levels: Int, isCancelled: () -> Bool) -> Data? {
        guard width > 0, (1...15).contains(levels) else { return nil }
        return map(.rasterDither, pixels: pixels, auxiliary: nil,
                   descriptor: SIMD4(UInt32(pixels.count / 4), UInt32(width), UInt32(levels), 0),
                   isCancelled: isCancelled)
    }

    enum Procedural: UInt32 {
        case noise, clouds, turbulence, julia, mandelbrot
    }

    static func procedural(_ effect: Procedural, pixels: Data, width: Int, height: Int, values: [Double],
                           isCancelled: () -> Bool) -> Data? {
        let parameters: SIMD4<Float>
        switch effect {
        case .noise:
            guard values[0] > 0, values[2] > 0 else { return pixels }
            parameters = SIMD4(Float(values[0] * 2.55), Float(values[1] / 100), Float(values[2] / 100), Float(values[3]))
        case .clouds, .turbulence:
            let falloff = values[1] / 100
            let total = (0..<5).reduce(0.0) { $0 + pow(falloff, Double($1)) }
            parameters = SIMD4(Float(values[0]), Float(falloff), Float(values[2]), Float(total))
        case .julia, .mandelbrot:
            let angle = values[2] * .pi / 180
            parameters = SIMD4(Float(3.2 / Double(min(width, height)) / values[0]), Float(sin(angle)),
                               Float(cos(angle)), Float(values[1]))
        }
        var auxiliary = parameters
        return map(.rasterProcedural, pixels: pixels, auxiliary: withUnsafeBytes(of: &auxiliary) { Data($0) },
                   descriptor: SIMD4(UInt32(pixels.count / 4), UInt32(width), UInt32(height), effect.rawValue),
                   isCancelled: isCancelled)
    }

    enum Distortion: UInt32 {
        case dents, frostedGlass, polarInversion, waves, relief
    }

    static func distortion(_ effect: Distortion, pixels: Data, width: Int, height: Int, values: [Double],
                           isCancelled: () -> Bool) -> Data? {
        return map(.rasterDistortion, pixels: pixels, auxiliary: values.map(Float.init).withUnsafeBytes { Data($0) },
                   descriptor: SIMD4(UInt32(pixels.count / 4), UInt32(width), UInt32(height), effect.rawValue),
                   isCancelled: isCancelled)
    }

    enum Blur: UInt32 {
        case fragment, radial, surface, quantile, outline, motion
    }

    static func blur(_ effect: Blur, pixels: Data, width: Int, height: Int, parameters: [SIMD4<Float>],
                     isCancelled: () -> Bool) -> Data? {
        map(.rasterCustomBlur, pixels: pixels, auxiliary: parameters.withUnsafeBytes { Data($0) },
            descriptor: SIMD4(UInt32(pixels.count / 4), UInt32(width), UInt32(height), effect.rawValue),
            isCancelled: isCancelled)
    }

    static func pixelateCells(_ pixels: Data, width: Int, height: Int, cellSize: Int, columns: Int, rows: Int,
                             halo: Int, transfer: LinearEffectTransfer, isCancelled: () -> Bool) -> Data? {
        guard enabled, pixels.count / 4 >= minimumPixels else { return nil }
        let parameters = [SIMD4<Float>(Float(columns), Float(halo), 0, 0)] + transfer.metalTables
        let count = columns * rows
        return map(.rasterPixelate, pixels: pixels, auxiliary: parameters.withUnsafeBytes { Data($0) },
                   descriptor: SIMD4(UInt32(count), UInt32(width), UInt32(height), UInt32(cellSize)),
                   isCancelled: isCancelled)
    }

    private static func map(_ kernel: Kernel, pixels: Data, auxiliary: Data?, descriptor: SIMD4<UInt32>,
                            isCancelled: () -> Bool) -> Data? {
        let outputByteCount = Int(descriptor.x) * 4
        guard enabled, pixels.count / 4 >= minimumPixels, pixels.count.isMultiple(of: 4), outputByteCount > 0,
              !isCancelled(),
              let engine, let pipeline = engine.pipelines[kernel], let source = engine.buffer(pixels),
              let output = engine.device.makeBuffer(length: outputByteCount, options: .storageModeShared),
              let aux = auxiliary.map(engine.buffer) ?? source,
              let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { return nil }
        var descriptor = descriptor
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(aux, offset: 0, index: 2)
        encoder.setBytes(&descriptor, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
        let lanes = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreadgroups(MTLSize(width: (Int(descriptor.x) + lanes - 1) / lanes, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: lanes, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        return Data(bytesNoCopy: output.contents(), count: outputByteCount, deallocator: .custom { _, _ in
            withExtendedLifetime(output) {}
        })
    }

    static func histogram(_ pixels: Data, mask: Data?, isCancelled: () -> Bool) -> [[Int]]? {
        let count = pixels.count / 4
        guard enabled, count >= minimumPixels, mask == nil || mask?.count == count, !isCancelled(),
              let engine, let pipeline = engine.pipelines[.rasterHistogram], let source = engine.buffer(pixels),
              let coverage = mask.map(engine.buffer) ?? source,
              let output = engine.device.makeBuffer(length: 768 * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { return nil }
        output.contents().initializeMemory(as: UInt32.self, repeating: 0, count: 768)
        var descriptor = SIMD4(UInt32(count), mask == nil ? 0 : 1, 0, 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(coverage, offset: 0, index: 2)
        encoder.setBytes(&descriptor, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
        let lanes = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        let batch = lanes * 16
        encoder.dispatchThreadgroups(MTLSize(width: (count + batch - 1) / batch, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: lanes, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        let bins = output.contents().assumingMemoryBound(to: UInt32.self)
        return (0..<3).map { channel in
            (0..<256).map { Int(bins[channel * 256 + $0]) }
        }
    }

    static func squareBlur(_ pixels: Data, width: Int, height: Int, radius: Int, transfer: LinearEffectTransfer,
                           isCancelled: () -> Bool) -> Data? {
        let intermediateSize = pixels.count * 4
        guard enabled, pixels.count / 4 >= minimumPixels, !isCancelled(),
              let engine, intermediateSize <= min(engine.device.maxBufferLength,
                                                  Int(engine.device.recommendedMaxWorkingSetSize / 8)),
              let vertical = engine.pipelines[.rasterSquareBlurVertical],
              let horizontal = engine.pipelines[.rasterSquareBlurHorizontal],
              let source = engine.buffer(pixels),
              let intermediate = engine.device.makeBuffer(length: intermediateSize, options: .storageModePrivate),
              let output = engine.device.makeBuffer(length: pixels.count, options: .storageModeShared),
              let tables = engine.buffer(transfer.metalTables.withUnsafeBytes { Data($0) }),
              let command = engine.queue.makeCommandBuffer() else { return nil }
        // Each invocation slides a strip, reusing the sum between output pixels.
        let strip = 32
        var descriptor = SIMD4(UInt32(width), UInt32(height), UInt32(radius), UInt32(strip))
        for (pipeline, input, target, columns, rows) in [
            (vertical, source, intermediate, width, (height + strip - 1) / strip),
            (horizontal, intermediate, output, (width + strip - 1) / strip, height)
        ] {
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(target, offset: 0, index: 1)
            encoder.setBuffer(tables, offset: 0, index: 2)
            encoder.setBytes(&descriptor, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
            let lanes = pipeline.threadExecutionWidth
            encoder.dispatchThreadgroups(MTLSize(width: (columns + lanes - 1) / lanes, height: rows, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: lanes, height: 1, depth: 1))
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        return Data(bytesNoCopy: output.contents(), count: pixels.count, deallocator: .custom { _, _ in
            withExtendedLifetime(output) {}
        })
    }
}
