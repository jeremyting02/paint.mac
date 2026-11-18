import Foundation
import Metal

/// Retains the source across histogram accumulation and palette mapping.
final class MetalPaletteQuantizer {
    private struct Engine {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let accumulate: MTLComputePipelineState
        let reduce: MTLComputePipelineState
        let nearest: MTLComputePipelineState
        let map: MTLComputePipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: metalPaletteShader, options: nil) else { return nil }
            func pipeline(_ name: String) -> MTLComputePipelineState? {
                guard let function = library.makeFunction(name: name) else { return nil }
                return try? device.makeComputePipelineState(function: function)
            }
            guard let accumulate = pipeline("accumulatePaletteBins"), let reduce = pipeline("reducePaletteBins"),
                  let nearest = pipeline("nearestPaletteBins"), let map = pipeline("mapPalettePixels") else { return nil }
            self.device = device
            self.queue = queue
            self.accumulate = accumulate
            self.reduce = reduce
            self.nearest = nearest
            self.map = map
        }

        func buffer<T>(_ values: [T]) -> MTLBuffer? {
            values.withUnsafeBytes { copy($0) }
        }

        func copy(_ bytes: UnsafeRawBufferPointer) -> MTLBuffer? {
            guard let pointer = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: pointer, length: bytes.count, options: .storageModeShared)
        }

        func encode(_ pipeline: MTLComputePipelineState, in command: MTLCommandBuffer, count: Int,
                    buffers: [MTLBuffer], parameters: SIMD4<UInt32>) -> Bool {
            guard let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            withUnsafeBytes(of: parameters) {
                encoder.setBytes($0.baseAddress!, length: $0.count, index: buffers.count)
            }
            let lanes = min(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth * 4)
            encoder.dispatchThreadgroups(MTLSize(width: (count + lanes - 1) / lanes, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: lanes, height: 1, depth: 1))
            encoder.endEncoding()
            return true
        }
    }

    private static let engine = Engine()
    static var deviceName: String? { engine?.device.name }
    private static let bins = 32 * 32 * 32
    private static let shards = 8
    private let engine: Engine
    private let source: MTLBuffer
    private let width: Int
    private let count: Int

    init?(source: Data, width: Int, height: Int) {
        let count = width * height
        guard count > 0, count <= Int(UInt32.max / 255), source.count == count * 4, let engine = Self.engine,
              let input = source.withUnsafeBytes({ engine.copy($0) }) else { return nil }
        self.engine = engine
        self.source = input
        self.width = width
        self.count = count
    }

    func histogram(isCancelled: () -> Bool) -> [SIMD4<UInt64>]? {
        let size = Self.bins * Self.shards * 7 * 4
        guard !isCancelled(), let command = engine.queue.makeCommandBuffer(),
              let bins = engine.device.makeBuffer(length: size, options: .storageModePrivate),
              let totals = engine.device.makeBuffer(length: Self.bins * 32, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.fill(buffer: bins, range: 0..<size, value: 0)
        blit.endEncoding()
        let parameters = SIMD4(UInt32(count), UInt32(Self.bins), UInt32(Self.shards), 0)
        guard engine.encode(engine.accumulate, in: command, count: count, buffers: [source, bins], parameters: parameters),
              engine.encode(engine.reduce, in: command, count: Self.bins, buffers: [bins, totals], parameters: parameters),
              !isCancelled() else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        let values = totals.contents().bindMemory(to: SIMD4<UInt64>.self, capacity: Self.bins)
        return Array(UnsafeBufferPointer(start: values, count: Self.bins))
    }

    func map(palette: [SIMD4<UInt8>], lookup: [UInt32]?, phases: [UInt8], isCancelled: () -> Bool) -> Data? {
        guard !isCancelled(), let command = engine.queue.makeCommandBuffer(),
              let paletteBuffer = engine.buffer(palette), let phases = engine.buffer(phases),
              let output = engine.device.makeBuffer(length: count * 4, options: .storageModeShared) else { return nil }
        let parameters = SIMD4(UInt32(count), UInt32(width), UInt32(palette.count), UInt32(Self.bins))
        let indices: MTLBuffer
        if let lookup {
            guard let buffer = engine.buffer(lookup) else { return nil }
            indices = buffer
        } else {
            guard let buffer = engine.device.makeBuffer(length: Self.bins * 4, options: .storageModePrivate),
                  engine.encode(engine.nearest, in: command, count: Self.bins, buffers: [paletteBuffer, buffer],
                                parameters: parameters) else { return nil }
            indices = buffer
        }
        guard engine.encode(engine.map, in: command, count: count,
                            buffers: [source, output, paletteBuffer, indices, phases], parameters: parameters),
              !isCancelled() else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, !isCancelled() else { return nil }
        return Data(bytes: output.contents(), count: count * 4)
    }
}

private let metalPaletteShader = """
#include <metal_stdlib>
using namespace metal;

uint paletteBin(uint3 colors) {
    return colors.x | (colors.y << 5) | (colors.z << 10);
}

void addWeight(device atomic_uint *parts, uint value) {
    uint before = atomic_fetch_add_explicit(parts, value, memory_order_relaxed);
    if (before > 0xffffffffu - value) atomic_fetch_add_explicit(parts + 1, 1, memory_order_relaxed);
}

kernel void accumulatePaletteBins(device const uchar4 *source [[buffer(0)]], device atomic_uint *bins [[buffer(1)]],
                                  constant uint4 &p [[buffer(2)]], uint id [[thread_position_in_grid]],
                                  uint group [[threadgroup_position_in_grid]]) {
    if (id >= p.x) return;
    uint4 pixel = uint4(source[id]);
    if (!pixel.w) return;
    uint key = paletteBin(pixel.xyz >> 3);
    device atomic_uint *bin = bins + ((group % p.z) * p.y + key) * 7;
    atomic_fetch_add_explicit(bin, pixel.w, memory_order_relaxed);
    for (uint channel = 0; channel < 3; ++channel) {
        addWeight(bin + 1 + channel * 2, pixel[channel] * pixel.w);
    }
}

kernel void reducePaletteBins(device const uint *bins [[buffer(0)]], device ulong4 *target [[buffer(1)]],
                              constant uint4 &p [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= p.y) return;
    ulong4 total = 0;
    for (uint shard = 0; shard < p.z; ++shard) {
        device const uint *bin = bins + (shard * p.y + id) * 7;
        total.w += bin[0];
        for (uint channel = 0; channel < 3; ++channel) {
            total[channel] += ulong(bin[1 + 2 * channel]) | (ulong(bin[2 + 2 * channel]) << 32);
        }
    }
    target[id] = total;
}

kernel void nearestPaletteBins(device const uchar4 *palette [[buffer(0)]], device uint *lookup [[buffer(1)]],
                               constant uint4 &p [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= p.w) return;
    int3 color = int3(id & 31, (id >> 5) & 31, id >> 10) * 8 + 4;
    uint nearest = 0;
    int minimum = 0x7fffffff;
    for (uint index = 0; index < p.z; ++index) {
        int3 diff = color - int3(palette[index].xyz);
        int3 squared = diff * diff;
        int distance = squared.x + squared.y + squared.z;
        if (distance < minimum) {
            nearest = index;
            minimum = distance;
        }
    }
    lookup[id] = nearest;
}

kernel void mapPalettePixels(device const uchar4 *source [[buffer(0)]], device uchar4 *target [[buffer(1)]],
                             device const uchar4 *palette [[buffer(2)]], device const uint *lookup [[buffer(3)]],
                             device const uchar *phases [[buffer(4)]], constant uint4 &p [[buffer(5)]],
                             uint id [[thread_position_in_grid]]) {
    if (id >= p.x) return;
    uchar4 pixel = source[id];
    if (pixel.w) {
        uint phase = (((id / p.y) & 3) * 4 + ((id % p.y) & 3)) * 256;
        uint key = paletteBin(uint3(phases[phase + pixel.x], phases[phase + pixel.y], phases[phase + pixel.z]));
        pixel.xyz = palette[lookup[key]].xyz;
    }
    target[id] = pixel;
}
"""
