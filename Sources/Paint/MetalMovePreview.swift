import CoreGraphics
import Foundation
import Metal
import OSLog
import QuartzCore

/// Renders a committed stack or floating move. SelectedPixelsTransform still owns document edits.
final class MetalMovePreview {
    static let log = Logger(subsystem: "local.paintmac.editor", category: "MetalCanvas")

    enum Presentation {
        case submitted
        case noDrawable
        case encodingFailed
    }

    /// A live replacement of the active layer. Edits update this buffer between presents.
    final class ActivePixels {
        fileprivate let buffer: MTLBuffer
        private let width: Int
        private let height: Int

        fileprivate init(buffer: MTLBuffer, width: Int, height: Int) {
            self.buffer = buffer
            self.width = width
            self.height = height
        }

        func update(_ bytes: Data, in region: CGRect) {
            guard CGRect(x: 0, y: 0, width: width, height: height).contains(region), region == region.integral,
                  !region.isEmpty, bytes.count == Int(region.width * region.height) * 4 else { return }
            let rows = Int(region.height), rowBytes = Int(region.width) * 4
            let start = (Int(region.minY) * width + Int(region.minX)) * 4
            bytes.withUnsafeBytes { source in
                for row in 0..<rows {
                    buffer.contents().advanced(by: start + row * width * 4)
                        .copyMemory(from: source.baseAddress!.advanced(by: row * rowBytes), byteCount: rowBytes)
                }
            }
        }
    }

    private struct Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let translationPipeline: MTLComputePipelineState
        let viewportPipeline: MTLRenderPipelineState?
        let translatedViewportPipeline: MTLRenderPipelineState?

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let options = MTLCompileOptions()
            if #available(macOS 15, *) { options.mathMode = .safe }
            else { options.fastMathEnabled = false }
            guard let library = try? device.makeLibrary(source: metalMoveShader, options: options) else { return nil }
            func function(_ name: String, translating: Bool) -> MTLFunction? {
                let constants = MTLFunctionConstantValues()
                var translating = translating
                constants.setConstantValue(&translating, type: .bool, index: 0)
                return try? library.makeFunction(name: name, constantValues: constants)
            }
            guard let affine = function("renderMovePreview", translating: false),
                  let translation = function("renderMovePreview", translating: true),
                  let pipeline = try? device.makeComputePipelineState(function: affine),
                  let translationPipeline = try? device.makeComputePipelineState(function: translation) else { return nil }
            func viewport(translating: Bool) -> MTLRenderPipelineState? {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "viewportVertex")
                descriptor.fragmentFunction = function("viewportFragment", translating: translating)
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            self.translationPipeline = translationPipeline
            viewportPipeline = viewport(translating: false)
            translatedViewportPipeline = viewport(translating: true)
        }
    }

    private struct Parameters {
        let canvas: SIMD4<UInt32>
        let region: SIMD4<UInt32>
        let foreground: SIMD4<UInt32>
        let flags: SIMD4<UInt32>
        let inverse: SIMD4<Float>
        let offsetAndTransition: SIMD4<Float>
        let destinationOrigin: SIMD2<Int32>
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
    private let hasMove: Bool
    private var previewTexture: MTLTexture?
    private var cached: (Frame, CGImage)?

    init?(reusing committed: MetalMovePreview, stack: LayerStack, pixels: SelectedPixelsTransform) {
        let source = pixels.previewSource
        guard !committed.hasMove, !source.isPaste, source.cropped == nil, source.cleared == nil else { return nil }
        let visible = stack.layers.indices.filter { stack.layers[$0].isVisible && stack.layers[$0].opacity > 0 }
        guard let active = visible.firstIndex(of: stack.active), visible.count == Int(committed.canvas.y) else { return nil }
        let width = Int(committed.bounds.width), height = Int(committed.bounds.height)
        let offset = (active * height + Int(source.selection.minY)) * width + Int(source.selection.minX)
        engine = committed.engine
        input = committed.input
        layerInfo = committed.layerInfo
        canvas = SIMD4(UInt32(width), committed.canvas.y, UInt32(active), .max)
        foreground = SIMD4(UInt32(offset), UInt32(width), UInt32(source.selection.width), UInt32(source.selection.height))
        selection = source.selection
        hasMove = true
        bounds = committed.bounds
        colorSpace = committed.colorSpace
    }

    init?(stack: LayerStack, pixels: SelectedPixelsTransform? = nil) {
        guard let engine = Self.engine else { return nil }
        let source = pixels?.previewSource
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
            guard let bytes = (isActive ? source?.original : nil) ?? layer.straightPixels, bytes.count == layerBytes,
                  let offset = append(bytes) else { return nil }
            if isActive { active = layers.count }
            layers.append(SIMD4(offset, UInt32(layer.opacity), UInt32(layer.blendMode.rawValue), 0))
        }
        guard source == nil || active != nil else { return nil }
        let visibleCount = layers.count
        if layers.isEmpty { layers = [.zero] }
        let layout = source?.selection ?? .zero
        var clearedOffset = UInt32.max
        if source?.isPaste == true, let active {
            clearedOffset = layers[active].x
        } else if let cleared = source?.cleared, source?.cropped != nil {
            guard let offset = append(cleared) else { return nil }
            clearedOffset = offset
        }
        let foregroundOffset: UInt32
        let foregroundStride: Int
        if let cropped = source?.cropped {
            guard let offset = append(cropped) else { return nil }
            foregroundOffset = offset
            foregroundStride = Int(layout.width)
        } else if let active, source != nil {
            foregroundOffset = layers[active].x + UInt32(Int(layout.minY) * image.width + Int(layout.minX))
            foregroundStride = image.width
        } else {
            foregroundOffset = 0
            foregroundStride = image.width
        }
        guard let input = engine.device.makeBuffer(length: max(4, byteCount), options: .storageModeShared),
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
        let activeIndex = active.map(UInt32.init) ?? .max
        canvas = SIMD4(UInt32(image.width), UInt32(visibleCount), activeIndex, clearedOffset)
        foreground = SIMD4(foregroundOffset, UInt32(foregroundStride), UInt32(layout.width), UInt32(layout.height))
        selection = layout
        hasMove = source != nil
        bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        colorSpace = stack.needsBlendComposite ? stack.workingColorSpace : stack.activeLayer.workingColorSpace
    }

    func render(in visible: CGRect, by transform: CGAffineTransform, copy: Bool,
                sampling: MoveResampler.Mode) -> (region: CGRect, image: CGImage)? {
        let region = visible.integral.insetBy(dx: -2, dy: -2).intersection(bounds)
        guard !region.isEmpty else { return nil }
        let frame = Frame(region: region, transform: transform, copy: copy, sampling: sampling)
        if let cached, cached.0 == frame { return (region, cached.1) }
        let width = Int(region.width), rows = Int(region.height)
        let byteCount = width * rows * 4
        guard let (configuration, translates) = parameters(region: region, transform: transform, copy: copy,
                                                            sampling: sampling) else { return nil }
        var parameters = configuration
        guard let output = engine.device.makeBuffer(length: byteCount, options: .storageModeShared),
              let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            return nil
        }
        let pipeline = translates ? engine.translationPipeline : engine.pipeline
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(layerInfo, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
        let lanes = pipeline.threadExecutionWidth
        let threads = MTLSize(width: lanes, height: min(4, pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1)
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

    private func parameters(region: CGRect, transform: CGAffineTransform, copy: Bool,
                            sampling: MoveResampler.Mode) -> (Parameters, Bool)? {
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let inverse = transform.inverted()
        let height = bounds.height
        // The source rectangle uses top-left coordinates, so a positive canvas y shift moves it up.
        let destinationOrigin: SIMD2<Int32>?
        if transform.a == 1, transform.b == 0, transform.c == 0, transform.d == 1,
           let x = Int32(exactly: selection.minX + transform.tx),
           let y = Int32(exactly: selection.minY - transform.ty) {
            destinationOrigin = SIMD2(x, y)
        } else {
            destinationOrigin = nil
        }
        let parameters = Parameters(
            canvas: canvas, region: SIMD4(UInt32(region.minX), UInt32(region.minY), UInt32(region.width), UInt32(region.height)),
            foreground: foreground,
            flags: SIMD4(copy ? 1 : 0, sampling == .antialiasedNearest ? 1 : 0,
                         transform.b == 0 && transform.c == 0 ? 1 : 0, hasMove ? 0 : 1),
            inverse: SIMD4(Float(inverse.a), Float(-inverse.b), Float(-inverse.c), Float(inverse.d)),
            offsetAndTransition: SIMD4(Float(inverse.tx + inverse.c * height - selection.minX),
                                       Float(height * (1 - inverse.d) - inverse.ty - selection.minY),
                                       Float(min(1, hypot(inverse.a, inverse.c))),
                                       Float(min(1, hypot(inverse.b, inverse.d)))),
            destinationOrigin: destinationOrigin ?? .zero
        )
        return (parameters, destinationOrigin != nil)
    }

    func makeActivePixels(from pixels: Data) -> ActivePixels? {
        let width = Int(bounds.width), height = Int(bounds.height)
        guard pixels.count == width * height * 4,
              let buffer = pixels.withUnsafeBytes({ source in
                  engine.device.makeBuffer(bytes: source.baseAddress!, length: source.count, options: .storageModeShared)
              }) else { return nil }
        return ActivePixels(buffer: buffer, width: width, height: height)
    }

    func present(in layer: CAMetalLayer, region: CGRect, size: CGSize, by transform: CGAffineTransform,
                 copy: Bool, sampling: MoveResampler.Mode, activePixels: ActivePixels?, checkerboard: SIMD4<Float>,
                 completed: @escaping @Sendable (Bool) -> Void) -> Presentation {
        if layer.device !== engine.device { layer.device = engine.device }
        if layer.colorspace != colorSpace { layer.colorspace = colorSpace }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return .noDrawable }
        guard let command = encodeViewport(to: drawable.texture, region: region, transform: transform, copy: copy,
                                           sampling: sampling, activePixels: activePixels,
                                           checkerboard: checkerboard) else { return .encodingFailed }
        command.present(drawable)
        command.addCompletedHandler { buffer in
            let success = buffer.status == .completed
            if !success {
                let reason = buffer.error.map { String(describing: $0) } ?? "status \(buffer.status.rawValue)"
                Self.log.error("Canvas command failed: \(reason, privacy: .public)")
            }
            completed(success)
        }
        command.commit()
        return .submitted
    }

    // Draw the same viewport offscreen for bitmaps, tests, and end-to-end comparisons.
    func renderViewport(in region: CGRect, size: CGSize, by transform: CGAffineTransform = .identity,
                        copy: Bool = false, sampling: MoveResampler.Mode = .bicubic,
                        activePixels: ActivePixels? = nil) -> CGImage? {
        guard size.width >= 1, size.height >= 1, size.width <= 8192, size.height <= 8192 else { return nil }
        let width = Int(size.width), height = Int(size.height)
        if previewTexture?.width != width || previewTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                      height: height, mipmapped: false)
            #if arch(x86_64)
            descriptor.storageMode = engine.device.hasUnifiedMemory ? .shared : .managed
            #else
            descriptor.storageMode = .shared
            #endif
            descriptor.usage = .renderTarget
            previewTexture = engine.device.makeTexture(descriptor: descriptor)
        }
        guard let texture = previewTexture,
              let command = encodeViewport(to: texture, region: region, transform: transform, copy: copy,
                                           sampling: sampling, activePixels: activePixels, checkerboard: .zero)
        else { return nil }
        #if arch(x86_64)
        if texture.storageMode == .managed {
            guard let blit = command.makeBlitCommandEncoder() else { return nil }
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        #endif
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { destination in
            texture.getBytes(destination.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let format = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: format, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encodeViewport(to texture: MTLTexture, region: CGRect, transform: CGAffineTransform,
                                copy: Bool, sampling: MoveResampler.Mode, activePixels: ActivePixels?,
                                checkerboard: SIMD4<Float>) -> MTLCommandBuffer? {
        guard !region.isEmpty,
              let (configuration, translates) = parameters(region: bounds, transform: transform, copy: copy,
                                                           sampling: sampling),
              let pipeline = translates ? engine.translatedViewportPipeline : engine.viewportPipeline,
              let command = engine.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var configurationBytes = configuration
        var mapping = SIMD4(Float(region.minX), Float(region.minY), Float(region.width) / Float(texture.width),
                            Float(region.height) / Float(texture.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(input, offset: 0, index: 0)
        encoder.setFragmentBuffer(layerInfo, offset: 0, index: 1)
        encoder.setFragmentBytes(&configurationBytes, length: MemoryLayout<Parameters>.stride, index: 3)
        encoder.setFragmentBytes(&mapping, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
        encoder.setFragmentBuffer(activePixels?.buffer ?? input, offset: 0, index: 5)
        var presentation = checkerboard
        presentation.w = activePixels == nil ? 0 : 1
        encoder.setFragmentBytes(&presentation, length: MemoryLayout<SIMD4<Float>>.stride, index: 6)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return command
    }
}
