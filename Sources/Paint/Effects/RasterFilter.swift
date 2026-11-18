import AppKit
import CoreImage

struct RasterFilter {
    enum Editor {
        case curves, levels, posterize
    }

    struct Control {
        let title: String
        let range: ClosedRange<Double>
        let initial: Double
        let step: Double
        let choices: [String]?

        init(_ title: String, _ range: ClosedRange<Double>, _ initial: Double, step: Double = 1) {
            self.title = title
            self.range = range
            self.initial = initial
            self.step = step
            choices = nil
        }

        init(_ title: String, choices: [String], initial: Int = 0) {
            precondition(choices.indices.contains(initial))
            self.title = title
            range = 0...Double(choices.count - 1)
            self.initial = Double(initial)
            step = 1
            self.choices = choices
        }

        func snapped(_ value: Double) -> Double {
            guard value.isFinite else { return initial }
            return min(range.upperBound, max(range.lowerBound, (value / step).rounded() * step))
        }
    }

    let title: String
    let category: String?
    let controls: [Control]
    let editor: Editor?
    typealias Renderer = (Data, Int, Int, CGColorSpace, Data?, [Double], () -> Bool) -> Data?
    private let process: Renderer
    private let previewProcess: Renderer?
    var hasPreviewRenderer: Bool { previewProcess != nil }

    init(_ title: String, category: String? = nil, _ controls: [Control] = [],
         process: @escaping (Data, Int, Int, [Double]) -> Data?) {
        self.init(title, category: category, controls, render: { bytes, width, height, values, _ in
            process(bytes, width, height, values)
        })
    }

    init(_ title: String, category: String? = nil, _ controls: [Control] = [], editor: Editor? = nil,
         preview: ((Data, Int, Int, [Double], () -> Bool) -> Data?)? = nil,
         render: @escaping (Data, Int, Int, [Double], () -> Bool) -> Data?) {
        let previewProcess: Renderer? = preview.map { body in
            { pixels, width, height, _, _, values, cancelled in body(pixels, width, height, values, cancelled) }
        }
        self.init(title, category: category, controls, editor: editor, preview: previewProcess) {
            pixels, width, height, _, _, values, isCancelled in
            render(pixels, width, height, values, isCancelled)
        }
    }

    init(_ title: String, category: String? = nil, _ controls: [Control] = [], editor: Editor? = nil,
         renderSelected: @escaping (Data, Int, Int, Data?, [Double], () -> Bool) -> Data?) {
        self.init(title, category: category, controls, editor: editor) { pixels, width, height, _, mask, values, cancelled in
            renderSelected(pixels, width, height, mask, values, cancelled)
        }
    }

    init(_ title: String, category: String?, _ controls: [Control], editor: Editor? = nil,
         preview: Renderer? = nil, renderInColorSpace: @escaping Renderer) {
        self.title = title
        self.category = category
        self.controls = controls
        self.editor = editor
        process = renderInColorSpace
        previewProcess = preview
    }

    struct Input {
        let layer: PaintLayer
        let layerIndex: Int?
        let pixels: Data
        let mask: Data?

        init?(layer: PaintLayer, selection: SelectionOutline?, layerIndex: Int? = nil) {
            guard let pixels = layer.straightPixels else { return nil }
            self.layer = layer
            self.layerIndex = layerIndex
            self.pixels = pixels
            if let selection {
                let bounds = CGRect(x: 0, y: 0, width: layer.image.width, height: layer.image.height)
                guard let mask = selection.mask(in: bounds, imageHeight: layer.image.height) else { return nil }
                self.mask = mask
            } else {
                mask = nil
            }
        }

        func render(_ filter: RasterFilter, values: [Double], preview: Bool = false,
                    isCancelled: () -> Bool = { false }) -> PaintLayer? {
            guard values.count == filter.controls.count, !isCancelled() else { return nil }
            let settings = zip(filter.controls, values).map { $0.snapped($1) }
            let width = layer.image.width, height = layer.image.height, colorSpace = layer.workingColorSpace
            let accelerated = preview ? filter.previewProcess?(pixels, width, height, colorSpace, mask, settings, isCancelled) : nil
            guard !preview || !isCancelled(),
                  var result = accelerated ?? filter.process(pixels, width, height, colorSpace, mask, settings, isCancelled),
                  result.count == pixels.count, !isCancelled() else { return nil }
            // SelectionOutline supplies a binary mask in top-to-bottom pixel order.
            if let mask {
                result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                    pixels.withUnsafeBytes { (original: UnsafeRawBufferPointer) in
                        mask.withUnsafeBytes { (coverage: UnsafeRawBufferPointer) in
                            for pixel in coverage.indices where coverage[pixel] == 0 {
                                let offset = pixel * 4
                                output.storeBytes(of: original.loadUnaligned(fromByteOffset: offset, as: UInt32.self),
                                                  toByteOffset: offset, as: UInt32.self)
                            }
                        }
                    }
                }
            }
            if result == pixels { return layer }
            return layer.withPixels(result)
        }
    }

    typealias Pixel = SIMD4<Double>

    static func point(_ title: String, category: String? = nil, _ controls: [Control] = [],
                      accelerate: ((Data, [Double], () -> Bool) -> Data?)? = nil,
                      _ transform: @escaping (Pixel, [Double]) -> Pixel) -> Self {
        Self(title, category: category, controls) { source, _, _, values, isCancelled in
            if let accelerated = accelerate?(source, values, isCancelled) { return accelerated }
            var result = source
            let completed = result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    if offset & 0xffff == 0, isCancelled() { return false }
                    let pixel = Pixel(Double(bytes[offset + 2]), Double(bytes[offset + 1]),
                                      Double(bytes[offset]), Double(bytes[offset + 3])) / 255
                    let changed = transform(pixel, values)
                    bytes[offset] = byte(changed.z)
                    bytes[offset + 1] = byte(changed.y)
                    bytes[offset + 2] = byte(changed.x)
                    bytes[offset + 3] = byte(changed.w)
                }
                return true
            }
            return completed ? result : nil
        }
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }

    static func channelTable(_ transform: (Double) -> Double) -> [UInt8] {
        (0...255).map { byte(transform(Double($0) / 255)) }
    }

    static func luminance(_ pixel: Pixel) -> Double {
        pixel.x * 0.2126 + pixel.y * 0.7152 + pixel.z * 0.0722
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let softwareContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    static func coreImage(_ title: String, category: String? = nil, _ controls: [Control] = [],
                          _ transform: @escaping (CIImage, [Double]) -> CIImage) -> Self {
        Self(title, category: category, controls) { pixels, width, height, colorSpace, _, values, _ in
            guard let image = BGRA8.image(from: pixels, width: width, height: height, colorSpace: colorSpace)
            else { return nil }
            let input = CIImage(cgImage: image)
            let output = transform(input, values)
            if output === input { return pixels }
            let extent = input.extent
            guard let rendered = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace)
                ?? softwareContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace)
            else { return nil }
            return BGRA8.pixels(from: rendered, in: colorSpace)
        }
    }
}
