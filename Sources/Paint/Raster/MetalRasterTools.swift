import CoreGraphics
import Foundation
import Metal

enum MetalRasterTools {
    private struct Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let flood: MTLComputePipelineState
        let edit: MTLComputePipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: metalRasterToolShader, options: nil),
                  let flood = library.makeFunction(name: "matchFloodColors"),
                  let edit = library.makeFunction(name: "editRasterPixels"),
                  let floodPipeline = try? device.makeComputePipelineState(function: flood),
                  let editPipeline = try? device.makeComputePipelineState(function: edit) else { return nil }
            self.device = device
            self.queue = queue
            self.flood = floodPipeline
            self.edit = editPipeline
        }

        func buffer(_ bytes: Data) -> MTLBuffer? {
            bytes.withUnsafeBytes { raw in
                guard let start = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: start, length: raw.count, options: .storageModeShared)
            }
        }

        func run<T>(_ pipeline: MTLComputePipelineState, count: Int, outputLength: Int,
                    input: Data, auxiliary: Data?, parameters: T) -> Data? {
            guard let inputBuffer = buffer(input),
                  let auxiliaryBuffer = auxiliary.map(buffer) ?? inputBuffer,
                  let output = device.makeBuffer(length: outputLength, options: .storageModeShared),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(auxiliaryBuffer, offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            withUnsafeBytes(of: parameters) { bytes in
                encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 3)
            }
            let group = pipeline.threadExecutionWidth * 8
            let threads = min(group, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreadgroups(MTLSize(width: (count + threads - 1) / threads, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            return Data(bytesNoCopy: output.contents(), count: outputLength, deallocator: .custom { _, _ in
                withExtendedLifetime(output) {}
            })
        }
    }

    private struct EditParameters {
        let canvas: SIMD4<UInt32> // Width, pixel count, operation, has mask.
        let region: SIMD4<UInt32>
        let colorOrMode: SIMD4<UInt32>
    }

    private static let engine = Engine()
    private static let minimumPixels = 128 * 1024

    static func floodMask(pixels: Data, seedIndex: Int, limit: Int, within mask: Data?) -> Data? {
        let count = pixels.count / 4
        guard count >= minimumPixels, (0..<count).contains(seedIndex), limit >= 0,
              mask == nil || mask?.count == count, let engine else { return nil }
        let parameters = SIMD4(UInt32(count), UInt32(seedIndex), UInt32(truncatingIfNeeded: limit),
                               UInt32(limit >> 32) | (mask == nil ? 0 : 1 << 31))
        return engine.run(engine.flood, count: count, outputLength: count,
                          input: pixels, auxiliary: mask, parameters: parameters)
    }

    static func fill(_ pixels: Data, width: Int, rect: CGRect, mask: Data?, color: SIMD4<UInt8>) -> Data? {
        guard color.w > 0 else { return nil }
        return edit(pixels, width: width, rect: rect, auxiliary: mask, operation: 0,
                    colorOrMode: SIMD4<UInt32>(truncatingIfNeeded: color))
    }

    static func clear(_ pixels: Data, width: Int, rect: CGRect, mask: Data) -> Data? {
        edit(pixels, width: width, rect: rect, auxiliary: mask, operation: 1, colorOrMode: .zero)
    }

    static func composite(_ foreground: Data, on pixels: Data, width: Int, rect: CGRect,
                          mode: LayerBlendMode) -> Data? {
        edit(pixels, width: width, rect: rect, auxiliary: foreground, operation: 2,
             colorOrMode: SIMD4(UInt32(mode.rawValue), 0, 0, 0))
    }

    private static func edit(_ pixels: Data, width: Int, rect: CGRect, auxiliary: Data?, operation: UInt32,
                             colorOrMode: SIMD4<UInt32>) -> Data? {
        let count = pixels.count / 4
        guard width > 0, count.isMultiple(of: width), rect == rect.integral,
              CGRect(x: 0, y: 0, width: width, height: count / width).contains(rect),
              rect.width * rect.height >= CGFloat(minimumPixels), let engine else { return nil }
        let auxiliaryLength = Int(rect.width) * Int(rect.height) * (operation == 2 ? 4 : 1)
        guard auxiliary == nil || auxiliary?.count == auxiliaryLength else { return nil }
        let region = SIMD4(UInt32(rect.minX), UInt32(rect.minY), UInt32(rect.width), UInt32(rect.height))
        let parameters = EditParameters(canvas: SIMD4(UInt32(width), UInt32(count), operation, auxiliary == nil ? 0 : 1),
                                        region: region, colorOrMode: colorOrMode)
        return engine.run(engine.edit, count: count, outputLength: pixels.count,
                          input: pixels, auxiliary: auxiliary, parameters: parameters)
    }
}

let metalRasterToolShader = """
#include <metal_stdlib>
using namespace metal;

int4 premultipliedBytes(uchar4 bytes) {
    return int4(int3(bytes.xyz), 255) * bytes.w;
}

kernel void matchFloodColors(device const uchar4 *pixels [[buffer(0)]],
                             device const uchar *mask [[buffer(1)]],
                             device uchar *result [[buffer(2)]],
                             constant uint4 &p [[buffer(3)]],
                             uint i [[thread_position_in_grid]]) {
    if (i >= p.x) return;
    if ((p.w >> 31) && !mask[i]) { result[i] = 0; return; }
    uint4 delta = uint4(abs(premultipliedBytes(pixels[i]) - premultipliedBytes(pixels[p.y])));
    uint4 q = delta * delta;
    // Each square fits in 32 bits. Keep the carries so all four can be compared exactly.
    uint a = q.x + q.y, b = q.z + q.w, lo = a + b;
    uint hi = uint(a < q.x) + uint(b < q.z) + uint(lo < a);
    uint limitHi = p.w & 0x7fffffffu;
    result[i] = hi < limitHi || (hi == limitHi && lo <= p.z);
}

uint3 blendRaster(uint3 a, uint3 b, uint mode) {
    switch (mode) {
        case 1: return (a * b + 127u) / 255u;
        case 2: return min(255u, a + b);
        case 3: return select(uint3(max(0, 255 - int3((255u - a) * 255u / max(1u, b)))), uint3(0), b == 0);
        case 4: return min(255u, a * 255u / max(1u, 255u - b)) | select(uint3(0), uint3(255), b == 255);
        case 5: return min(255u, a * a / max(1u, 255u - b)) | select(uint3(0), uint3(255), b == 255);
        case 6: return min(255u, b * b / max(1u, 255u - a)) | select(uint3(0), uint3(255), a == 255);
        case 7: return select(255u - (2u * (255u - a) * (255u - b) + 127u) / 255u,
                              (2u * a * b + 127u) / 255u, a < 128);
        case 8: return uint3(abs(int3(a) - int3(b)));
        case 9: return 255u - uint3(abs(255 - int3(a) - int3(b)));
        case 10: return max(a, b);
        case 11: return min(a, b);
        case 12: return a + b - (a * b + 127u) / 255u;
        case 13: return a ^ b;
        default: return b;
    }
}

uchar4 compositeRaster(uchar4 source, uchar4 target, uint opacity, uint mode) {
    uint alpha = uint(source.w) * opacity;
    if (alpha == 0) return target;
    if (target.w == 0 || (alpha == 65025u && mode == 0)) {
        return uchar4(source.xyz, uchar((alpha + 127u) / 255u));
    }
    uint backdrop = uint(target.w) * (65025u - alpha);
    uint foreground = (255u - uint(target.w)) * alpha;
    uint overlap = uint(target.w) * alpha;
    uint total = backdrop + foreground + overlap;
    uint3 a = uint3(target.xyz), b = uint3(source.xyz);
    return uchar4(uchar3((backdrop * a + foreground * b + overlap * blendRaster(a, b, mode) + total / 2u) / total),
                  uchar((total + 32512u) / 65025u));
}

struct EditParameters {
    uint4 canvas;
    uint4 region;
    uint4 colorOrMode;
};

kernel void editRasterPixels(device const uchar4 *pixels [[buffer(0)]],
                             device const uchar *aux [[buffer(1)]],
                             device uchar4 *result [[buffer(2)]],
                             constant EditParameters &p [[buffer(3)]],
                             uint i [[thread_position_in_grid]]) {
    if (i >= p.canvas.y) return;
    uchar4 value = pixels[i];
    uint2 point = uint2(i % p.canvas.x, i / p.canvas.x) - p.region.xy;
    if (all(point < p.region.zw)) {
        uint index = point.y * p.region.z + point.x;
        if (p.canvas.z == 2) {
            device const uchar4 *foreground = reinterpret_cast<device const uchar4 *>(aux);
            value = compositeRaster(foreground[index], value, 255, p.colorOrMode.x);
        } else if (!p.canvas.w || aux[index]) {
            if (p.canvas.z == 1) { value = uchar4(0); }
            else {
                uint source = p.colorOrMode.w * 255u;
                uint backdrop = uint(value.w) * (255u - p.colorOrMode.w);
                uint total = source + backdrop;
                value = uchar4(uchar3((p.colorOrMode.xyz * source + uint3(value.xyz) * backdrop + total / 2u) / total),
                               uchar((total + 127u) / 255u));
            }
        }
    }
    result[i] = value;
}
"""
