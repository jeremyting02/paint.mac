// Keep this shader available to both the app bundle and the standalone canvas benchmark.
let metalMoveShader = """
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    uint4 canvas;     // width, layer count, active layer index, cleared-layer offset or UINT_MAX
    uint4 region;     // x, y, width, height (top-left origin)
    uint4 foreground; // offset, stride, width, height
    uint4 flags;      // copy, antialiased nearest, axis aligned, unused
    float4 inverse;
    float4 offsetAndTransition;
};

float4 texel(device const uchar4 *pixels, uint4 source, int2 point) {
    uint2 p = uint2(clamp(point, int2(0), int2(source.zw) - 1));
    float4 color = float4(pixels[source.x + p.y * source.y + p.x]) / 255.0f;
    return float4(color.xyz * color.w, color.w);
}

float cubicWeight(float x) {
    if (x < 1) return ((1.5f * x - 2.5f) * x) * x + 1;
    if (x < 2) return ((-0.5f * x + 2.5f) * x - 4) * x + 2;
    return 0;
}

float4 sampleSelection(device const uchar4 *pixels, constant Parameters &p, float2 point) {
    float2 base = floor(point);
    int2 origin = int2(base);
    float2 f = point - base;
    if (p.flags.y) {
        float2 w = clamp((f - 0.5f) / p.offsetAndTransition.zw + 0.5f, 0.0f, 1.0f);
        float4 a = mix(texel(pixels, p.foreground, origin), texel(pixels, p.foreground, origin + int2(1, 0)), w.x);
        float4 b = mix(texel(pixels, p.foreground, origin + int2(0, 1)),
                       texel(pixels, p.foreground, origin + int2(1, 1)), w.x);
        return mix(a, b, w.y);
    }
    float4 weights;
    for (int tap = -1; tap <= 2; ++tap) weights[tap + 1] = cubicWeight(abs(float(tap) - f.x));
    float4 result = 0;
    for (int row = -1; row <= 2; ++row) {
        float4 line = 0;
        for (int col = -1; col <= 2; ++col) {
            line += texel(pixels, p.foreground, origin + int2(col, row)) * weights[col + 1];
        }
        result += line * cubicWeight(abs(float(row) - f.y));
    }
    return result;
}

float selectionCoverage(float2 center, float2 dx, float2 dy, float2 size, bool aligned) {
    float2 radius = (abs(dx) + abs(dy)) * 0.5f;
    float2 lo = center - radius, hi = center + radius;
    if (any(hi <= 0) || any(lo >= size)) return 0;
    if (all(lo >= 0) && all(hi <= size)) return 1;
    if (aligned) {
        float2 area = max(float2(0), min(hi, size) - max(lo, float2(0))) / (2 * radius);
        return area.x * area.y;
    }
    // The transform maps each output pixel to a parallelogram. Supersample only its clipped edges.
    uint covered = 0;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float2 sample = center + (float(x) - 1.5f) * 0.25f * dx + (float(y) - 1.5f) * 0.25f * dy;
            covered += all(sample >= 0) && all(sample < size);
        }
    }
    return float(covered) / 16.0f;
}

uchar4 toBytes(float4 value) {
    return uchar4(rint(clamp(value, 0.0f, 1.0f) * 255.0f));
}

uchar4 sourceOver(uchar4 source, uchar4 destination) {
    if (source.w == 0) return destination;
    if (source.w == 255 || destination.w == 0) return source;
    uint alpha = uint(source.w) * 255;
    uint bottom = uint(destination.w) * (65025 - alpha);
    uint top = 255 * alpha;
    uint total = bottom + top;
    return uchar4(uchar3((uint3(destination.xyz) * bottom + uint3(source.xyz) * top + total / 2) / total),
                  uchar((total + 32512) / 65025));
}

// Match LayerBlendMode's raw values and premultiplied FP32 layer composition.
float3 blend(uint mode, float3 a, float3 b) {
    switch (mode) {
        case 1: return a * b;
        case 2: return min(1.0f, a + b);
        case 3: return select(max(0.0f, 1 - (1 - a) / b), float3(0), b == 0);
        case 4: return select(min(1.0f, a / (1 - b)), float3(1), b == 1);
        case 5: return select(min(1.0f, a * a / (1 - b)), float3(1), b == 1);
        case 6: return select(min(1.0f, b * b / (1 - a)), float3(1), a == 1);
        case 7: return select(1 - 2 * (1 - a) * (1 - b), 2 * a * b, a < 0.5f);
        case 8: return abs(a - b);
        case 9: return 1 - abs(1 - a - b);
        case 10: return max(a, b);
        case 11: return min(a, b);
        case 12: return a + b - a * b;
        case 13: return float3(uint3(rint(a * 255)) ^ uint3(rint(b * 255))) / 255.0f;
        default: return b;
    }
}

kernel void renderMovePreview(device const uchar4 *pixels [[buffer(0)]],
                              device const uint4 *layers [[buffer(1)]],
                              device uchar4 *output [[buffer(2)]],
                              constant Parameters &p [[buffer(3)]],
                              uint2 id [[thread_position_in_grid]]) {
    if (any(id >= p.region.zw)) return;
    uint2 location = p.region.xy + id;
    uint pixel = location.y * p.canvas.x + location.x;
    uint activeOffset = p.flags.x ? layers[p.canvas.z].x : p.canvas.w;
    uchar4 active = activeOffset == 0xffffffffu ? uchar4(0) : pixels[activeOffset + pixel];
    float2 center = float2(location) + 0.5f;
    float2 dx = p.inverse.xy, dy = p.inverse.zw;
    float2 mapped = center.x * dx + center.y * dy + p.offsetAndTransition.xy;
    float coverage = selectionCoverage(mapped, dx, dy, float2(p.foreground.zw), p.flags.z != 0);
    if (coverage > 0) {
        float4 sample = sampleSelection(pixels, p, mapped - 0.5f);
        if (sample.w > 0) {
            uchar4 moved = toBytes(float4(sample.xyz / sample.w, sample.w * coverage));
            active = sourceOver(moved, active);
        }
    }

    uint target = id.y * p.region.z + id.x;
    if (p.canvas.y == 1 && layers[0].y == 255) {
        output[target] = active;
        return;
    }
    float4 backdrop = 0;
    uchar4 bottom = 0;
    for (uint index = 0; index < p.canvas.y; ++index) {
        uint4 layer = layers[index];
        uchar4 bytes = index == p.canvas.z ? active : pixels[layer.x + pixel];
        if (index == 0) bottom = bytes;
        float4 color = float4(bytes) / 255.0f;
        float alpha = color.w * (float(layer.y) / 255.0f);
        if (alpha == 0) continue;
        float4 foreground = float4(color.xyz, 1) * alpha;
        if (layer.z == 0 || backdrop.w == 0) {
            backdrop = foreground + backdrop * (1 - alpha);
        } else {
            float3 overlap = blend(layer.z, backdrop.xyz / backdrop.w, color.xyz);
            backdrop = backdrop * (1 - alpha) + foreground * (1 - backdrop.w) +
                       float4(overlap, 1) * (backdrop.w * alpha);
        }
    }
    output[target] = backdrop.w > 0 ? toBytes(float4(backdrop.xyz / backdrop.w, backdrop.w)) : bottom;
}
"""
