let metalRasterGeometryShader = """
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct ResizeParameters {
    uint4 sizes; // source width, output width/height, intermediate width
    uint4 flags; // intermediate height, horizontal first, transfer table
};

uchar quantize(float value) {
    return uchar(round(clamp(value, 0.0f, 1.0f) * 255.0f));
}

uchar encodeTransfer(float value, uint channel, device const float3 *thresholds) {
    uint low = 0, high = 255;
    while (low < high) {
        uint middle = (low + high) / 2;
        if (value < thresholds[middle][channel]) high = middle;
        else low = middle + 1;
    }
    return uchar(low);
}

kernel void resizeNearest(device const uint *source [[buffer(0)]], device uint *output [[buffer(1)]],
                          device const uint *x [[buffer(2)]], device const uint *y [[buffer(3)]],
                          constant ResizeParameters &p [[buffer(4)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= p.sizes.y || id.y >= p.sizes.z) return;
    output[id.y * p.sizes.y + id.x] = source[y[id.y] * p.sizes.x + x[id.x]];
}

kernel void resizeFirst(device const uchar4 *source [[buffer(0)]], device float4 *middle [[buffer(1)]],
                        device const uint *offsets [[buffer(2)]], device const uint2 *taps [[buffer(3)]],
                        device const float3 *decoded [[buffer(4)]],
                        constant ResizeParameters &p [[buffer(5)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= p.sizes.w || id.y >= p.flags.x) return;
    uint axis = p.flags.y ? id.x : id.y;
    float4 sum = 0;
    for (uint tap = offsets[axis]; tap < offsets[axis + 1]; ++tap) {
        uint2 sample = taps[tap];
        uint offset = p.flags.y ? id.y * p.sizes.x + sample.x : sample.x * p.sizes.x + id.x;
        uchar4 pixel = source[offset];
        float4 normalized = float4(pixel) / 255.0f;
        if (p.flags.z) normalized.xyz = float3(decoded[pixel.x].x, decoded[pixel.y].y, decoded[pixel.z].z);
        sum += float4(normalized.xyz * normalized.w, normalized.w) * as_type<float>(sample.y);
    }
    middle[id.y * p.sizes.w + id.x] = sum;
}

kernel void resizeSecond(device const float4 *middle [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                         device const uint *offsets [[buffer(2)]], device const uint2 *taps [[buffer(3)]],
                         device const float3 *thresholds [[buffer(4)]],
                         constant ResizeParameters &p [[buffer(5)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= p.sizes.y || id.y >= p.sizes.z) return;
    uint axis = p.flags.y ? id.y : id.x;
    float4 sum = 0;
    for (uint tap = offsets[axis]; tap < offsets[axis + 1]; ++tap) {
        uint2 sample = taps[tap];
        uint offset = p.flags.y ? sample.x * p.sizes.w + id.x : id.y * p.sizes.w + sample.x;
        sum += middle[offset] * as_type<float>(sample.y);
    }
    uchar4 pixel = uchar4(0, 0, 0, quantize(sum.w));
    if (pixel.w > 0) {
        float3 color = clamp(sum.xyz / sum.w, 0.0f, 1.0f);
        for (uint channel = 0; channel < 3; ++channel) {
            pixel[channel] = p.flags.z ? encodeTransfer(color[channel], channel, thresholds) : quantize(color[channel]);
        }
    }
    output[id.y * p.sizes.y + id.x] = pixel;
}

struct ProjectionParameters {
    uint4 sizeAndModes; // width, height, sample grid width, tiling * 2 + nearest
    float4 centerAndPan;
    float4 project; // zoom, depth, cosine of tilt, sine of tilt
    float4 angles; // cos/sin of azimuth, cos/sin of roll
};

int tiledIndex(int value, int extent, uint tiling) {
    if (!tiling) return value >= 0 && value < extent ? value : -1;
    int period = tiling == 1 ? extent : 2 * extent;
    int position = value % period;
    if (position < 0) position += period;
    return position < extent ? position : period - position - 1;
}

uchar4 projectPixel(device const uchar4 *input, int2 coordinate, constant ProjectionParameters &p) {
    uint tiling = p.sizeAndModes.w / 2;
    int x = tiledIndex(coordinate.x, p.sizeAndModes.x, tiling);
    int y = tiledIndex(coordinate.y, p.sizeAndModes.y, tiling);
    return x < 0 || y < 0 ? uchar4(0) : input[y * p.sizeAndModes.x + x];
}

float4 premultiply(uchar4 word) {
    float alpha = float(word.w) / 255.0f;
    return float4(float3(word.xyz) * (alpha / 255.0f), alpha);
}

bool inverseProject(float2 position, constant ProjectionParameters &p, thread float2 &pixel) {
    float2 point = (position - p.centerAndPan.xy - p.centerAndPan.zw) / p.project.x;
    float2 azimuth = p.angles.xy;
    float2 perpendicular = float2(-azimuth.y, azimuth.x);
    float u = dot(point, azimuth), v = dot(point, perpendicular);
    float depth = p.project.y, tiltCos = p.project.z, tiltSin = p.project.w;
    float denominator = depth * tiltCos - u * tiltSin;
    if (tiltCos <= 1e-8f || denominator <= 1e-6f) return false;
    float x = u * depth / denominator;
    float y = v * (depth + tiltSin * x) / depth;
    float2 rolled = azimuth * x + perpendicular * y;
    pixel = float2(p.angles.z * rolled.x + p.angles.w * rolled.y,
                   -p.angles.w * rolled.x + p.angles.z * rolled.y) + p.centerAndPan.xy;
    return all(abs(pixel) < 2147483000.0f);
}

float4 bilinear(device const uchar4 *input, float2 pixel, constant ProjectionParameters &p) {
    float2 base = floor(pixel), fraction = pixel - base;
    int2 index = int2(base);
    float4 a = premultiply(projectPixel(input, index, p)) * (1 - fraction.x)
        + premultiply(projectPixel(input, index + int2(1, 0), p)) * fraction.x;
    float4 b = premultiply(projectPixel(input, index + int2(0, 1), p)) * (1 - fraction.x)
        + premultiply(projectPixel(input, index + int2(1, 1), p)) * fraction.x;
    return a * (1 - fraction.y) + b * fraction.y;
}

kernel void projectLayer(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                         constant ProjectionParameters &p [[buffer(2)]], uint2 id [[thread_position_in_grid]]) {
    if (any(id >= p.sizeAndModes.xy)) return;
    uint offset = id.y * p.sizeAndModes.x + id.x;
    uint quality = p.sizeAndModes.z;
    bool nearest = (p.sizeAndModes.w & 1) != 0;
    float2 pixel;
    if (nearest && quality == 1) {
        output[offset] = inverseProject(float2(id), p, pixel) ? projectPixel(input, int2(round(pixel)), p) : uchar4(0);
        return;
    }

    float4 sum = 0;
    for (uint row = 0; row < quality; ++row) {
        for (uint column = 0; column < quality; ++column) {
            float2 position = float2(id) + (float2(column, row) + 0.5f) / float(quality) - 0.5f;
            if (inverseProject(position, p, pixel)) {
                sum += nearest ? premultiply(projectPixel(input, int2(round(pixel)), p)) : bilinear(input, pixel, p);
            }
        }
    }
    float4 average = sum / float(quality * quality);
    uchar4 result = uchar4(0, 0, 0, quantize(average.w));
    if (result.w > 0) {
        for (uint channel = 0; channel < 3; ++channel) result[channel] = quantize(average[channel] / average.w);
    }
    output[offset] = result;
}
"""
