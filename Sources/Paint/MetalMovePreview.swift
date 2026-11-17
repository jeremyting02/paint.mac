import CoreGraphics
import Foundation
import Metal

/// Renders a floating move into a shared buffer for the AppKit canvas. The document
/// continues to use SelectedPixelsTransform for commits, clipboard data and history.
final class MetalMovePreview {
    private struct Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let options = MTLCompileOptions()
            if #available(macOS 15, *) { options.mathMode = .safe }
            else { options.fastMathEnabled = false }
            guard let library = try? device.makeLibrary(source: metalMoveShader, options: options),
                  let function = library.makeFunction(name: "renderMovePreview"),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
        }
    }

    private struct Parameters {
        let canvas: SIMD4<UInt32>
        let region: SIMD4<UInt32>
        let foreground: SIMD4<UInt32>
        let flags: SIMD4<UInt32>
        let inverse: SIMD4<Float>
        let offsetAndTransition: SIMD4<Float>
    }

    private struct Frame: Equatable {
        let region: CGRect
        let transform: CGAffineTransform
        let copy: Bool
        let sampling: MoveResampler.Mode
    }

    private static let engine = Engine()
    private static let warmup: Void = {
        DispatchQueue.global(qos: .userInitiated).async { _ = engine }
    }()

    static func prepare() { _ = warmup }
    static var deviceName: String? { engine?.device.name }

    private let engine: Engine
    private let input: MTLBuffer
    private let layerInfo: MTLBuffer
    private let canvas: SIMD4<UInt32>
    private let foreground: SIMD4<UInt32>
    private let selection: CGRect
    private let bounds: CGRect
    private let colorSpace: CGColorSpace
    private var cached: (Frame, CGImage)?

    init?(stack: LayerStack, pixels: SelectedPixelsTransform) {
        guard let engine = Self.engine else { return nil }
        let source = pixels.previewSource
        let image = stack.activeLayer.image
        let layerBytes = image.width * image.height * 4
        var parts: [Data] = []
        var layers: [SIMD4<UInt32>] = []
        var active: Int?
        var byteCount = 0
        // Bound the preview's additional memory and let the tiled CPU path handle larger stacks.
        let budget = min(engine.device.maxBufferLength, 512 * 1024 * 1024,
                         Int(engine.device.recommendedMaxWorkingSetSize / 4))
        func append(_ bytes: Data) -> UInt32? {
            guard bytes.count <= budget - layerBytes - byteCount else { return nil }
            let offset = UInt32(byteCount / 4)
            byteCount += bytes.count
            parts.append(bytes)
            return offset
        }
        for (index, layer) in stack.layers.enumerated() where layer.isVisible && layer.opacity > 0 {
            let isActive = index == stack.active
            guard let bytes = isActive ? source.original : layer.straightPixels, bytes.count == layerBytes,
                  let offset = append(bytes) else { return nil }
            if isActive { active = layers.count }
            layers.append(SIMD4(offset, UInt32(layer.opacity), UInt32(layer.blendMode.rawValue), 0))
        }
        guard let active else { return nil }
        var clearedOffset = UInt32.max
        if source.isPaste {
            clearedOffset = layers[active].x
        } else if let cleared = source.cleared {
            guard let offset = append(cleared) else { return nil }
            clearedOffset = offset
        }
        let foregroundOffset: UInt32
        let foregroundStride: Int
        if let cropped = source.cropped {
            guard let offset = append(cropped) else { return nil }
            foregroundOffset = offset
            foregroundStride = Int(source.selection.width)
        } else {
            foregroundOffset = layers[active].x + UInt32(Int(source.selection.minY) * image.width + Int(source.selection.minX))
            foregroundStride = image.width
        }
        guard let input = engine.device.makeBuffer(length: byteCount, options: .storageModeShared),
              let layerInfo = layers.withUnsafeBytes({ buffer in
                  engine.device.makeBuffer(bytes: buffer.baseAddress!, length: buffer.count, options: .storageModeShared)
              }) else { return nil }
        var offset = 0
        for bytes in parts {
            bytes.copyBytes(to: input.contents().advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                            count: bytes.count)
            offset += bytes.count
        }
        self.engine = engine
        self.input = input
        self.layerInfo = layerInfo
        canvas = SIMD4(UInt32(image.width), UInt32(layers.count), UInt32(active), clearedOffset)
        foreground = SIMD4(foregroundOffset, UInt32(foregroundStride), UInt32(source.selection.width),
                           UInt32(source.selection.height))
        selection = source.selection
        bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        colorSpace = stack.needsBlendComposite ? stack.workingColorSpace : stack.activeLayer.workingColorSpace
    }

    func render(in visible: CGRect, by transform: CGAffineTransform, copy: Bool,
                sampling: MoveResampler.Mode) -> (region: CGRect, image: CGImage)? {
        let region = visible.integral.insetBy(dx: -2, dy: -2).intersection(bounds)
        guard !region.isEmpty else { return nil }
        let frame = Frame(region: region, transform: transform, copy: copy, sampling: sampling)
        if let cached, cached.0 == frame { return (region, cached.1) }
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let inverse = transform.inverted()
        let height = bounds.height
        let width = Int(region.width), rows = Int(region.height)
        let byteCount = width * rows * 4
        var parameters = Parameters(
            canvas: canvas, region: SIMD4(UInt32(region.minX), UInt32(region.minY), UInt32(width), UInt32(rows)),
            foreground: foreground,
            flags: SIMD4(copy ? 1 : 0, sampling == .antialiasedNearest ? 1 : 0,
                         transform.b == 0 && transform.c == 0 ? 1 : 0, 0),
            inverse: SIMD4(Float(inverse.a), Float(-inverse.b), Float(-inverse.c), Float(inverse.d)),
            offsetAndTransition: SIMD4(Float(inverse.tx + inverse.c * height - selection.minX),
                                       Float(height * (1 - inverse.d) - inverse.ty - selection.minY),
                                       Float(min(1, hypot(inverse.a, inverse.c))),
                                       Float(min(1, hypot(inverse.b, inverse.d))))
        )
        guard let output = engine.device.makeBuffer(length: byteCount, options: .storageModeShared),
              let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(engine.pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(layerInfo, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
        let lanes = engine.pipeline.threadExecutionWidth
        let threads = MTLSize(width: lanes, height: min(4, engine.pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1)
        let groups = MTLSize(width: (width + threads.width - 1) / threads.width,
                             height: (rows + threads.height - 1) / threads.height, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        // Keep the buffer alive for Core Graphics without copying or repacking the output bytes.
        let info = Unmanaged.passRetained(output as AnyObject).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: output.contents(), size: byteCount,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
                                            }) else {
            Unmanaged<AnyObject>.fromOpaque(info).release()
            return nil
        }
        guard let image = BGRA8.image(from: provider, width: width, height: rows, colorSpace: colorSpace) else { return nil }
        cached = (frame, image)
        return (region, image)
    }
}
