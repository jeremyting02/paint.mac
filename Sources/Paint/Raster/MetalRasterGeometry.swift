import Foundation
import Metal

enum MetalRasterGeometry {
    private final class Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let resizeFirst: MTLComputePipelineState
        let resizeSecond: MTLComputePipelineState
        let resizeNearest: MTLComputePipelineState
        let project: MTLComputePipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let options = MTLCompileOptions()
            if #available(macOS 15, *) {
                options.mathMode = .safe
                options.mathFloatingPointFunctions = .precise
            } else {
                options.fastMathEnabled = false
            }
            guard let library = try? device.makeLibrary(source: metalRasterGeometryShader, options: options) else { return nil }
            func pipeline(_ name: String) -> MTLComputePipelineState? {
                guard let function = library.makeFunction(name: name) else { return nil }
                return try? device.makeComputePipelineState(function: function)
            }
            guard let first = pipeline("resizeFirst"), let second = pipeline("resizeSecond"),
                  let nearest = pipeline("resizeNearest"), let project = pipeline("projectLayer") else { return nil }
            self.device = device
            self.queue = queue
            resizeFirst = first
            resizeSecond = second
            resizeNearest = nearest
            self.project = project
        }

        func buffer<T>(_ data: [T]) -> MTLBuffer? {
            data.withUnsafeBytes { copy($0) }
        }

        func copy(_ bytes: UnsafeRawBufferPointer) -> MTLBuffer? {
            guard let address = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }

        func encode<T>(_ pipeline: MTLComputePipelineState, command: MTLCommandBuffer, buffers: [MTLBuffer],
                       parameters: T, width: Int, height: Int) -> Bool {
            guard let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            withUnsafeBytes(of: parameters) {
                encoder.setBytes($0.baseAddress!, length: $0.count, index: buffers.count)
            }
            let lanes = pipeline.threadExecutionWidth
            let rows = min(4, pipeline.maxTotalThreadsPerThreadgroup / lanes)
            encoder.dispatchThreadgroups(MTLSize(width: (width + lanes - 1) / lanes, height: (height + rows - 1) / rows, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: lanes, height: rows, depth: 1))
            encoder.endEncoding()
            return true
        }
    }

    // All inputs are either copied into a Metal buffer or uploaded with setBytes.
    private struct ResizeParameters {
        let sizes: SIMD4<UInt32>
        let flags: SIMD4<UInt32>
    }

    struct ProjectionParameters {
        let sizeAndModes: SIMD4<UInt32>
        let centerAndPan: SIMD4<Float>
        let project: SIMD4<Float>
        let angles: SIMD4<Float>
    }

    private static let engine = Engine()
    static var deviceName: String? { engine?.device.name }

    private static func packed(_ axis: [[ImageResampler.Tap]]) -> (offsets: [UInt32], taps: [SIMD2<UInt32>]) {
        var offsets: [UInt32] = [0]
        var taps: [SIMD2<UInt32>] = []
        for line in axis {
            taps.append(contentsOf: line.map { SIMD2(UInt32($0.index), $0.weight.bitPattern) })
            offsets.append(UInt32(taps.count))
        }
        return (offsets, taps)
    }

    static func resize(_ pixels: Data, sourceWidth: Int, sourceHeight: Int, width: Int, height: Int,
                       horizontal: [[ImageResampler.Tap]], vertical: [[ImageResampler.Tap]], nearest: Bool,
                       transfer: (decoded: [SIMD3<Float>], thresholds: [SIMD3<Float>])?,
                       isCancelled: () -> Bool) -> Data? {
        guard pixels.count == sourceWidth * sourceHeight * 4, !isCancelled(), let engine,
              let command = engine.queue.makeCommandBuffer(),
              let input = pixels.withUnsafeBytes({ engine.copy($0) }),
              let output = engine.device.makeBuffer(length: width * height * 4, options: .storageModeShared)
        else { return nil }

        let horizontalFirst = width * sourceHeight <= sourceWidth * height
        let middleWidth = horizontalFirst ? width : sourceWidth
        let middleHeight = horizontalFirst ? sourceHeight : height
        let parameters = ResizeParameters(sizes: SIMD4(UInt32(sourceWidth), UInt32(width), UInt32(height), UInt32(middleWidth)),
                                          flags: SIMD4(UInt32(middleHeight), horizontalFirst ? 1 : 0, transfer == nil ? 0 : 1, 0))

        if nearest {
            guard let x = engine.buffer(horizontal.map { UInt32($0[0].index) }),
                  let y = engine.buffer(vertical.map { UInt32($0[0].index) }),
                  engine.encode(engine.resizeNearest, command: command, buffers: [input, output, x, y],
                                parameters: parameters, width: width, height: height) else { return nil }
        } else {
            let first = packed(horizontalFirst ? horizontal : vertical)
            let second = packed(horizontalFirst ? vertical : horizontal)
            guard let firstOffsets = engine.buffer(first.offsets), let firstTaps = engine.buffer(first.taps),
                  let secondOffsets = engine.buffer(second.offsets), let secondTaps = engine.buffer(second.taps),
                  let decoded = engine.buffer(transfer?.decoded ?? [SIMD3<Float>.zero]),
                  let thresholds = engine.buffer(transfer?.thresholds ?? [SIMD3<Float>.zero]),
                  let middle = engine.device.makeBuffer(length: middleWidth * middleHeight * 16, options: .storageModePrivate),
                  engine.encode(engine.resizeFirst, command: command, buffers: [input, middle, firstOffsets, firstTaps, decoded],
                                parameters: parameters, width: middleWidth, height: middleHeight),
                  engine.encode(engine.resizeSecond, command: command, buffers: [middle, output, secondOffsets, secondTaps, thresholds],
                                parameters: parameters, width: width, height: height) else { return nil }
        }
        guard !isCancelled() else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        return Data(bytes: output.contents(), count: width * height * 4)
    }

    static func project(_ pixels: Data, parameters: ProjectionParameters, isCancelled: () -> Bool) -> Data? {
        let width = Int(parameters.sizeAndModes.x), height = Int(parameters.sizeAndModes.y)
        guard pixels.count == width * height * 4, !isCancelled(), let engine,
              let command = engine.queue.makeCommandBuffer(),
              let input = pixels.withUnsafeBytes({ engine.copy($0) }),
              let output = engine.device.makeBuffer(length: pixels.count, options: .storageModeShared),
              engine.encode(engine.project, command: command, buffers: [input, output],
                            parameters: parameters, width: width, height: height),
              !isCancelled() else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        return Data(bytes: output.contents(), count: pixels.count)
    }
}
