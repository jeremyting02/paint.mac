import CoreGraphics
import Foundation
import Metal

/// Exact brush stamps. Stroke geometry and the canonical history tiles stay in RasterDrawing.
final class MetalBrushStroke {
    private struct Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: metalRasterToolShader + "\n" + metalBrushShader, options: nil),
                  let function = library.makeFunction(name: "stampBrush"),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
        }

        func buffer(_ bytes: Data) -> MTLBuffer? {
            bytes.withUnsafeBytes { raw in
                guard let start = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: start, length: raw.count, options: .storageModeShared)
            }
        }
    }

    private struct Parameters {
        let raster: SIMD4<Int32>
        let rect: SIMD4<Int32>
        let circle: SIMD4<Int32>
        let settings: SIMD4<Int32>
        let primary: SIMD4<UInt32>
        let secondary: SIMD4<UInt32>
    }

    private static let engine = Engine()
    private static let warmup: Void = {
        DispatchQueue.global(qos: .userInitiated).async { _ = engine }
    }()

    static func prepare() { _ = warmup }

    private let engine: Engine
    private let source: MTLBuffer
    private let clone: MTLBuffer
    private let coverage: MTLBuffer
    private let raster: SIMD4<Int32>
    private let settings: SIMD4<Int32>
    private let primary: SIMD4<UInt32>
    private let secondary: SIMD4<UInt32>

    init?(pixels: Data, width: Int, height: Int, operation: RasterDrawing.Operation, options: BrushOptions) {
        guard let engine = Self.engine, let source = engine.buffer(pixels),
              let coverage = engine.device.makeBuffer(length: width * height, options: .storageModeShared),
              let pattern = BrushOptions.Pattern.allCases.firstIndex(of: options.pattern) else { return nil }
        let op: Int32
        var settings = SIMD4<Int32>.zero
        switch options.blend {
        case .layer(let mode): settings.x = Int32(mode.rawValue)
        case .overwrite: settings.x = 14
        }
        func channels(_ color: DrawingColor) -> SIMD4<UInt32> {
            SIMD4(UInt32(color.blue), UInt32(color.green), UInt32(color.red), UInt32(color.alpha))
        }
        var primary = SIMD4<UInt32>.zero, secondary = SIMD4<UInt32>.zero
        var clone = source
        switch operation {
        case .pencil: return nil
        case let .paint(first, second):
            op = 0
            primary = channels(first)
            secondary = channels(second)
        case .erase(let opacity):
            op = 1
            primary.w = UInt32(opacity)
        case let .clone(bytes, offset, opacity):
            guard let x = Int32(exactly: offset.x.rounded(.towardZero)),
                  let y = Int32(exactly: offset.y.rounded(.towardZero)),
                  abs(Int(x)) <= width * 4, abs(Int(y)) <= height * 4,
                  let cloneBuffer = engine.buffer(bytes) else { return nil }
            op = 2
            clone = cloneBuffer
            settings.y = x
            settings.z = y
            primary.w = UInt32(opacity)
        case let .recolor(from, to, tolerance):
            guard (0...100).contains(tolerance) else { return nil }
            op = 3
            primary = channels(from)
            secondary = channels(to)
            settings.w = Int32(255 * tolerance / 100)
        }
        memset(coverage.contents(), 0, width * height)
        self.engine = engine
        self.source = source
        self.clone = clone
        self.coverage = coverage
        raster = SIMD4(Int32(width), Int32(height), op, Int32(pattern))
        self.settings = settings
        self.primary = primary
        self.secondary = secondary
    }

    func stamp(in rect: CGRect, center: CGPoint, radius: CGFloat, coveragePatch: Data?,
               receive: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> Void) -> Bool {
        let width = Int(rect.width), height = Int(rect.height)
        let byteCount = width * height * 4
        guard let amounts = coveragePatch.map(engine.buffer) ?? source,
              let output = engine.device.makeBuffer(length: byteCount, options: .storageModeShared),
              let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return false }
        let parameters = Parameters(raster: raster,
                                    rect: SIMD4(Int32(rect.minX), Int32(rect.minY), Int32(width), Int32(height)),
                                    circle: SIMD4(Int32(center.x * 2), Int32((CGFloat(raster.y) - center.y) * 2),
                                                  Int32(radius * 2), coveragePatch == nil ? 0 : 1),
                                    settings: settings, primary: primary, secondary: secondary)
        encoder.setComputePipelineState(engine.pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(clone, offset: 0, index: 1)
        encoder.setBuffer(coverage, offset: 0, index: 2)
        encoder.setBuffer(output, offset: 0, index: 3)
        withUnsafeBytes(of: parameters) { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 4)
        }
        encoder.setBuffer(amounts, offset: 0, index: 5)
        let lanes = engine.pipeline.threadExecutionWidth
        let rows = min(8, engine.pipeline.maxTotalThreadsPerThreadgroup / lanes)
        encoder.dispatchThreadgroups(MTLSize(width: (width + lanes - 1) / lanes, height: (height + rows - 1) / rows, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: lanes, height: rows, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return false }
        receive(UnsafeRawBufferPointer(start: output.contents(), count: byteCount),
                UnsafeRawBufferPointer(start: coverage.contents(), count: Int(raster.x) * Int(raster.y)))
        return true
    }
}

private let metalBrushShader = """
struct StampParameters {
    int4 raster; // width, height, operation, pattern
    int4 rect;
    int4 circle; // doubled center and radius, in top-left coordinates, and whether to use precomputed coverage
    int4 settings; // blend mode, clone x/y offset, recolor tolerance
    uint4 primary;
    uint4 secondary;
};

bool stampPattern(int2 point, int pattern) {
    bool row = point.y % 8 == 0, column = point.x % 8 == 0;
    bool forward = (point.x + point.y) % 8 == 0, backward = (point.x - point.y) % 8 == 0;
    switch (pattern) {
        case 1: return row;
        case 2: return column;
        case 3: return forward;
        case 4: return backward;
        case 5: return row || column;
        case 6: return forward || backward;
        case 7: return (point.x / 4 + point.y / 4) % 2 == 0;
        default: return true;
    }
}

uchar4 applyStampColor(uchar4 source, uchar4 target, uint amount, int mode) {
    if (mode != 14) return compositeRaster(source, target, amount, uint(mode));
    if (amount == 255) return source;
    uint foreground = uint(source.w) * amount;
    uint backdrop = uint(target.w) * (255u - amount);
    uint total = foreground + backdrop;
    uint3 a = uint3(source.xyz), b = uint3(target.xyz);
    uint3 rgb = total == 0 ? (a * amount + b * (255u - amount) + 127u) / 255u
                           : (a * foreground + b * backdrop + total / 2u) / total;
    return uchar4(uchar3(rgb), uchar((total + 127u) / 255u));
}

kernel void stampBrush(device const uchar4 *original [[buffer(0)]],
                       device const uchar4 *clone [[buffer(1)]],
                       device uchar *covered [[buffer(2)]],
                       device uchar4 *result [[buffer(3)]],
                       constant StampParameters &p [[buffer(4)]],
                       device const uchar *coveragePatch [[buffer(5)]],
                       uint2 position [[thread_position_in_grid]]) {
    if (any(position >= uint2(p.rect.zw))) return;
    int2 point = p.rect.xy + int2(position);
    uint target = position.y * uint(p.rect.z) + position.x;
    int index = point.y * p.raster.x + point.x;
    uchar4 value = original[index];
    int2 delta = point * 2 + 1 - p.circle.xy;
    uchar stamp = p.circle.w ? coveragePatch[target] :
        uchar(delta.x * delta.x + delta.y * delta.y <= p.circle.z * p.circle.z ? 255 : 0);
    uint amount = max(stamp, covered[index]);
    covered[index] = uchar(amount);
    if (amount) {
        switch (p.raster.z) {
            case 0: {
                uchar4 color = uchar4(stampPattern(point, p.raster.w) ? p.primary : p.secondary);
                value = applyStampColor(color, value, amount, p.settings.x);
                break;
            }
            case 1:
                if (stampPattern(point, p.raster.w)) {
                    uint erased = p.primary.w * amount;
                    uchar remaining = uchar((uint(value.w) * (65025u - erased) + 32512u) / 65025u);
                    if (remaining == 0 && (value.w != 0 || erased == 65025u)) value = uchar4(0);
                    else value.w = remaining;
                }
                break;
            case 2: {
                int2 source = point + int2(p.settings.y, -p.settings.z);
                if (all(uint2(source) < uint2(p.raster.xy))) {
                    uchar4 color = clone[source.y * p.raster.x + source.x];
                    color.w = uchar((uint(color.w) * p.primary.w + 127u) / 255u);
                    value = applyStampColor(color, value, amount, p.settings.x);
                }
                break;
            }
            case 3: {
                int3 old = int3(value.xyz), from = int3(p.primary.xyz);
                if (value.w != 0 && all(abs(old - from) <= uint(p.settings.w))) {
                    int3 change = (int3(p.secondary.xyz) - from) * int(p.secondary.w * amount) / 65025;
                    value.xyz = uchar3(clamp(old + change, 0, 255));
                }
                break;
            }
        }
    }
    result[target] = value;
}
"""
