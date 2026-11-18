let metalRasterEffectShader = """
#include <metal_stdlib>
using namespace metal;

kernel void rasterTable(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                        constant uchar *table [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                        uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    uchar4 value = input[pixel];
    if (!options.y || value.w) {
        value.xyz = uchar3(table[value.x], table[256 + value.y], table[512 + value.z]);
        if (options.z == 4) value.w = table[768 + value.w];
    }
    output[pixel] = value;
}

kernel void rasterLuminosity(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                             constant uchar *table [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                             uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    uchar4 value = input[pixel];
    if (options.y) {
        uint weighted = 299u * uint(value.z) + 587u * uint(value.y) + 114u * uint(value.x);
        uchar gray = weighted % 1000u == 500u
            ? table[256 * uint(value.x) + uint(value.y)] : uchar((weighted + 500u) / 1000u);
        output[pixel] = uchar4(gray, gray, gray, value.w);
        return;
    }
    uint weighted = 2126u * uint(value.z) + 7152u * uint(value.y) + 722u * uint(value.x);
    int intensity = weighted % 10000u == 5000u
        ? table[256 + 256 * uint(value.x) + uint(value.y)] : (weighted + 5000u) / 10000u;
    int difference = int(table[intensity]) - intensity;
    output[pixel] = uchar4(uchar3(clamp(int3(value.xyz) + difference, 0, 255)), value.w);
}

kernel void rasterHistogram(device const uchar4 *input [[buffer(0)]],
                            device atomic_uint *output [[buffer(1)]],
                            device const uchar *mask [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                            uint group [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]],
                            uint size [[threads_per_threadgroup]]) {
    threadgroup atomic_uint bins[768];
    for (uint i = lane; i < 768; i += size) atomic_store_explicit(&bins[i], 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint first = group * size * 16 + lane;
    for (uint sample = 0; sample < 16; ++sample) {
        uint pixel = first + sample * size;
        if (pixel >= options.x || (options.y && !mask[pixel])) continue;
        uchar4 value = input[pixel];
        if (!value.w) continue;
        atomic_fetch_add_explicit(&bins[value.z], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[256 + value.y], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[512 + value.x], 1, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = lane; i < 768; i += size) {
        uint count = atomic_load_explicit(&bins[i], memory_order_relaxed);
        if (count) atomic_fetch_add_explicit(&output[i], count, memory_order_relaxed);
    }
}

constant uint rasterBayer4[] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

kernel void rasterDither(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                         constant uint4 &options [[buffer(3)]], uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    uchar4 value = input[pixel];
    if (value.w) {
        uint threshold = rasterBayer4[(pixel / options.y % 4) * 4 + pixel % options.y % 4];
        uint3 step = (uint3(value.xyz) * (32 * options.z) + (2 * threshold + 1) * 255) / (32 * 255);
        value.xyz = uchar3((2 * step * 255 + options.z) / (2 * options.z));
    }
    output[pixel] = value;
}

float rasterNoise(ulong seed) {
    ulong value = seed + 0x9e3779b97f4a7c15UL;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9UL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebUL;
    return float((value ^ (value >> 31)) >> 11) / 9007199254740992.0f;
}

float rasterInterpolatedNoise(float2 point, ulong seed) {
    ulong2 corner = ulong2(point);
    float2 fraction = point - float2(corner);
    float2 smooth = fraction * fraction * (3.0f - 2.0f * fraction);
    ulong topLeft = seed + corner.x * 0x85ebca6bUL + corner.y * 0xc2b2ae35UL;
    float a = rasterNoise(topLeft), b = rasterNoise(topLeft + 0x85ebca6bUL);
    float c = rasterNoise(topLeft + 0xc2b2ae35UL), d = rasterNoise(topLeft + 0x85ebca6bUL + 0xc2b2ae35UL);
    return mix(mix(a, b, smooth.x), mix(c, d, smooth.x), smooth.y);
}

kernel void rasterProcedural(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                              constant float4 &parameters [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                              uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    if (options.w == 0) {
        uchar4 value = input[pixel];
        ulong hash = ulong(4 * pixel) * 0x9e3779b97f4a7c15UL + ulong(parameters.w);
        if (value.w && rasterNoise(hash) < parameters.z) {
            float gray = rasterNoise(hash + 1) - rasterNoise(hash + 2);
            for (uint channel = 0; channel < 3; ++channel) {
                ulong channelHash = hash + 2 * channel + 3;
                float color = rasterNoise(channelHash) - rasterNoise(channelHash + 1);
                float shift = parameters.x * mix(gray, color, parameters.y);
                value[channel] = uchar(clamp(round(float(value[channel]) + shift), 0.0f, 255.0f));
            }
        }
        output[pixel] = value;
        return;
    }
    float2 point = float2(pixel % options.y, pixel / options.y);
    if (options.w <= 2) {
        float wavelength = parameters.x, amplitude = 1, sum = 0;
        for (uint octave = 0; octave < 5; ++octave) {
            float noise = rasterInterpolatedNoise(point / wavelength, ulong(parameters.z) + octave * 0xce91UL);
            sum += amplitude * (options.w == 2 ? abs(noise * 2 - 1) : noise);
            wavelength *= 0.5f;
            amplitude *= parameters.y;
        }
        uchar gray = uchar(clamp(round(sum / parameters.w * 255), 0.0f, 255.0f));
        output[pixel] = uchar4(gray, gray, gray, 255);
        return;
    }
    float2 centered = (point + 0.5f - float2(options.yz) * 0.5f) * parameters.x;
    float2 rotated = float2(centered.x * parameters.z - centered.y * parameters.y,
                            centered.x * parameters.y + centered.y * parameters.z);
    bool julia = options.w == 3;
    float2 c = julia ? float2(-0.745f, 0.113f) : rotated - float2(0.65f, 0);
    float2 z = julia ? rotated : float2(0);
    uint step = 0, limit = uint(parameters.w);
    while (step < limit && dot(z, z) <= 4) {
        z = float2(z.x * z.x - z.y * z.y, 2 * z.x * z.y) + c;
        ++step;
    }
    float shade = step == limit ? 0 : sqrt(float(step) / float(limit));
    output[pixel] = uchar4(255 * shade, 220 * shade * shade, 190 * shade, 255);
}
uint rasterMirror(int index, uint count) {
    int period = int(count) * 2;
    int wrapped = (index % period + period) % period;
    return uint(wrapped < int(count) ? wrapped : period - 1 - wrapped);
}

float4 rasterLinearPixel(uchar4 value, constant float4 *tables) {
    float alpha = float(value.w) / 255.0f;
    return float4(float3(tables[value.x].x, tables[value.y].y, tables[value.z].z) * alpha, alpha);
}

kernel void rasterSquareBlurVertical(device const uchar4 *input [[buffer(0)]], device float4 *sums [[buffer(1)]],
                                     constant float4 *tables [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                                     uint2 threadID [[thread_position_in_grid]]) {
    uint x = threadID.x, first = threadID.y * options.w;
    if (x >= options.x || first >= options.y) return;
    int radius = int(options.z);
    float4 sum = 0;
    for (int i = -radius; i <= radius; ++i)
        sum += rasterLinearPixel(input[rasterMirror(int(first) + i, options.y) * options.x + x], tables);
    uint last = min(options.y, first + options.w);
    for (uint y = first; y < last; ++y) {
        sums[y * options.x + x] = sum;
        sum -= rasterLinearPixel(input[rasterMirror(int(y) - radius, options.y) * options.x + x], tables);
        sum += rasterLinearPixel(input[rasterMirror(int(y) + radius + 1, options.y) * options.x + x], tables);
    }
}

uint rasterEncode(float value, uint channel, constant float4 *tables) {
    uint low = 0, high = 255;
    while (low < high) {
        uint middle = (low + high) / 2;
        if (value < tables[256 + middle][channel]) high = middle;
        else low = middle + 1;
    }
    return low;
}

kernel void rasterSquareBlurHorizontal(device const float4 *sums [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                                       constant float4 *tables [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                                       uint2 threadID [[thread_position_in_grid]]) {
    uint first = threadID.x * options.w, y = threadID.y;
    if (first >= options.x || y >= options.y) return;
    int radius = int(options.z);
    float diameter = float(2 * radius + 1);
    uint row = y * options.x;
    float4 sum = 0;
    for (int i = -radius; i <= radius; ++i) sum += sums[row + rasterMirror(int(first) + i, options.x)];
    uint last = min(options.x, first + options.w);
    for (uint x = first; x < last; ++x) {
        uchar alpha = uchar(clamp(rint(sum.w * (255.0f / (diameter * diameter))), 0.0f, 255.0f));
        uchar4 color = 0;
        if (alpha) {
            float3 value = sum.xyz / sum.w;
            color = uchar4(rasterEncode(value.x, 0, tables), rasterEncode(value.y, 1, tables),
                           rasterEncode(value.z, 2, tables), alpha);
        }
        output[row + x] = color;
        sum -= sums[row + rasterMirror(int(x) - radius, options.x)];
        sum += sums[row + rasterMirror(int(x) + radius + 1, options.x)];
    }
}
float rasterDistortionRandom(int2 point, ulong seed) {
    ulong value = ulong(long(point.x)) * 0x9e3779b97f4a7c15UL;
    value ^= ulong(long(point.y)) * 0xc2b2ae3d27d4eb4fUL + seed * 0x165667b19e3779f9UL;
    value ^= value >> 30;
    value *= 0xbf58476d1ce4e5b9UL;
    value ^= value >> 27;
    value *= 0x94d049bb133111ebUL;
    value ^= value >> 31;
    return float(value >> 11) / 9007199254740992.0f;
}

float rasterDistortionNoise(float2 point, ulong seed) {
    int2 corner = int2(floor(point));
    float2 fraction = point - float2(corner);
    float2 t = fraction * fraction * (3.0f - 2.0f * fraction);
    float upper = mix(rasterDistortionRandom(corner, seed), rasterDistortionRandom(corner + int2(1, 0), seed), t.x);
    float lower = mix(rasterDistortionRandom(corner + int2(0, 1), seed), rasterDistortionRandom(corner + 1, seed), t.x);
    return mix(upper, lower, t.y) * 2 - 1;
}

float2 rasterDistortionPosition(float2 point, constant float *v, uint4 options) {
    constexpr float pi = 3.14159265358979323846f;
    float2 maxPoint = float2(options.yz - 1);
    float size = float(min(options.y, options.z));
    if (options.w == 0) {
        float2 center = maxPoint * 0.5f;
        float noiseScale = max(1.0f, size * v[0] / 320);
        float amplitude = size * v[1] / 600;
        float angle = v[4] * pi / 180;
        float2 direction = float2(cos(angle), sin(angle)), perpendicular = float2(-direction.y, direction.x);
        float2 relative = point - center;
        float2 position = float2(dot(relative, direction), dot(relative, perpendicular)) / noiseScale;
        ulong seed = ulong(v[6]);
        float offset = mix(rasterDistortionNoise(position, seed), rasterDistortionNoise(position * 3, seed + 1),
                           v[2] / 100) * amplitude;
        float shear = rasterDistortionNoise(float2(position.x + 24, position.y * 2), seed + 2) * amplitude * v[3] / 100;
        return point + direction * offset + perpendicular * shear;
    }
    if (options.w == 1) {
        int2 index = int2(round(point * 4));
        ulong seed = ulong(v[4]);
        float angle = rasterDistortionRandom(index, seed) * 2 * pi;
        float minimum = min(v[0], v[1]);
        float distance = minimum + (v[0] - minimum) * pow(rasterDistortionRandom(index, seed + 1), 1 / v[2]);
        return point + float2(cos(angle), sin(angle)) * distance;
    }
    if (options.w == 2) {
        float2 center = maxPoint * (0.5f + float2(v[1], v[2]) / 200);
        float2 vector = point - center;
        float squared = dot(vector, vector);
        if (squared <= 0.0001f) return point;
        float radius = size * 0.5f;
        return center + vector * (1 - v[0] + v[0] * radius * radius / squared);
    }
    float2 center = maxPoint * (0.5f + float2(v[6], v[7]) / 200);
    float2 relative = point - center;
    float frequency = 2 * pi / v[2], angle = v[3] * pi / 180, phase = v[4] * pi / 180;
    float2 direction = float2(cos(angle), sin(angle));
    uint mode = uint(v[0]);
    if (mode == 1)
        return point + float2(-direction.y, direction.x) * (sin(dot(relative, direction) * frequency + phase) * v[1]);
    float distance = length(relative);
    if (distance == 0) return point;
    float theta = atan2(relative.y, relative.x) - angle;
    float argument = distance * frequency;
    if (mode == 3) argument += theta * 3;
    if (mode == 4) argument = theta * v[5] + argument / 2;
    return point + relative / distance * (sin(argument + phase) * v[1]);
}

int rasterDistortionEdge(int value, int count, uint edge) {
    if (edge == 1) return clamp(value, 0, count - 1);
    if (edge == 3) return ((value % count) + count) % count;
    if (count <= 1) return 0;
    int period = (count - 1) * 2;
    int index = ((value % period) + period) % period;
    return min(index, period - index);
}

uchar4 rasterWarpRead(device const uchar4 *input, int2 point, uint2 size, uint edge) {
    uint x = uint(rasterDistortionEdge(point.x, int(size.x), edge));
    uint y = uint(rasterDistortionEdge(point.y, int(size.y), edge));
    return input[y * size.x + x];
}

float4 rasterPremultiply(uchar4 value) {
    return float4(float3(value.xyz) * (float(value.w) / 255), float(value.w));
}

float4 rasterWarpSample(device const uchar4 *input, float2 point, uint2 size, uint edge) {
    int2 corner = int2(floor(point));
    float2 t = point - float2(corner);
    float4 a = rasterPremultiply(rasterWarpRead(input, corner, size, edge));
    float4 b = rasterPremultiply(rasterWarpRead(input, corner + int2(1, 0), size, edge));
    float4 c = rasterPremultiply(rasterWarpRead(input, corner + int2(0, 1), size, edge));
    float4 d = rasterPremultiply(rasterWarpRead(input, corner + 1, size, edge));
    return mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

kernel void rasterDistortion(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                              constant float *v [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                              uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    float2 point = float2(pixel % options.y, pixel / options.y);
    if (options.w == 4) {
        uchar4 base = input[pixel];
        if (base.w) {
            float angle = v[0] * 3.14159265358979323846f / 180;
            float2 delta = float2(cos(angle), sin(angle));
            float3 leading = rasterWarpSample(input, point - delta, options.yz, 1).xyz;
            float3 trailing = rasterWarpSample(input, point + delta, options.yz, 1).xyz;
            base.xyz = uchar3(clamp(round(float3(base.xyz) + (leading - trailing) * 0.5f), 0.0f, 255.0f));
        }
        output[pixel] = base;
        return;
    }
    uint edge = options.w == 2 ? uint(v[3]) : 1;
    uint quality = uint(v[options.w == 0 ? 5 : options.w == 1 ? 3 : options.w == 2 ? 4 : 8]);
    if (quality == 1) {
        float2 position = rasterDistortionPosition(point, v, options);
        output[pixel] = rasterWarpRead(input, int2(round(position)), options.yz, edge);
        return;
    }
    float4 color = 0;
    if (quality == 2) {
        color = rasterWarpSample(input, rasterDistortionPosition(point, v, options), options.yz, edge);
    } else {
        color = rasterWarpSample(input, rasterDistortionPosition(point - 0.25f, v, options), options.yz, edge);
        color += rasterWarpSample(input, rasterDistortionPosition(point + 0.25f, v, options), options.yz, edge);
        if (quality == 4) {
            color += rasterWarpSample(input, rasterDistortionPosition(point + float2(0.25f, -0.25f), v, options), options.yz, edge);
            color += rasterWarpSample(input, rasterDistortionPosition(point + float2(-0.25f, 0.25f), v, options), options.yz, edge);
        }
        color /= quality == 3 ? 2 : 4;
    }
    uchar alpha = uchar(clamp(round(color.w), 0.0f, 255.0f));
    output[pixel] = alpha ? uchar4(uchar3(clamp(round(color.xyz * (255.0f / color.w)), 0.0f, 255.0f)), alpha) : uchar4(0);
}
ulong rasterQuantileKey(uchar4 value) {
    uint word = as_type<uint>(value);
    uint luma = (54 * uint(value.z) + 183 * uint(value.y) + 19 * uint(value.x)) * uint(value.w);
    return (ulong(luma) << 32) | ulong(word);
}

uint rasterBlurQuantile(device const uchar4 *input, int2 point, uint2 size, constant float4 *table) {
    uint count = uint(table[0].x), rank = uint(table[0].y), sets = uint(table[0].z);
    uint region = uint((point.x / 4) * 19 ^ (point.y / 4) * 23);
    constant float4 *offsets = table + 1 + (region % sets) * count;
    ulong ordered[113];
    for (uint i = 0; i < count; ++i) {
        ordered[i] = rasterQuantileKey(rasterWarpRead(input, point + int2(offsets[i].xy), size, 1));
    }
    int low = 0, high = int(count) - 1;
    while (low < high) {
        ulong pivot = ordered[(low + high) / 2];
        int i = low, j = high;
        while (i <= j) {
            while (i <= high && ordered[i] < pivot) ++i;
            while (j >= low && ordered[j] > pivot) --j;
            if (i <= j) {
                ulong first = ordered[i];
                ordered[i++] = ordered[j];
                ordered[j--] = first;
            }
        }
        if (int(rank) <= j) high = j;
        else if (int(rank) >= i) low = i;
        else break;
    }
    return uint(ordered[rank]);
}

int rasterMotionEdge(int value, int size, uint edge) {
    if (edge == 0 || edge == 3) return clamp(value, 0, size - 1);
    if (edge == 1) return ((value % size) + size) % size;
    int period = 2 * size;
    int index = ((value % period) + period) % period;
    return min(index, period - index - 1);
}

kernel void rasterCustomBlur(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                              constant float4 *table [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                              uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    int2 point = int2(pixel % options.y, pixel / options.y);
    if (options.w == 5) {
        uint count = uint(table[0].x), edge = uint(table[0].y);
        float4 sum = float4(0);
        for (uint i = 1; i <= count; ++i) {
            int2 tap = point + int2(table[i].xy);
            if (edge == 3 && any(uint2(tap) >= options.yz)) continue;
            int x = rasterMotionEdge(tap.x, int(options.y), edge);
            int y = rasterMotionEdge(tap.y, int(options.z), edge);
            sum += rasterPremultiply(input[y * int(options.y) + x]) * table[i].z;
        }
        float3 rgb = sum.w > 0 ? sum.xyz * (255.0f / sum.w) : float3(0);
        output[pixel] = uchar4(uchar3(clamp(round(rgb), 0.0f, 255.0f)), uchar(clamp(round(sum.w), 0.0f, 255.0f)));
        return;
    }
    if (options.w == 3) {
        output[pixel] = as_type<uchar4>(rasterBlurQuantile(input, point, options.yz, table));
        return;
    }
    if (options.w == 4) {
        uchar4 value = input[pixel];
        if (value.w) {
            uint count = uint(table[0].x), shift = uint(table[0].w);
            uchar3 ordered[25];
            for (uint i = 0; i < count; ++i) {
                uchar4 sample = rasterWarpRead(input, point + int2(table[i + 1].xy), options.yz, 1);
                uchar3 color = uchar3((uint3(sample.xyz) * uint(sample.w) / 255) >> shift);
                int j = int(i);
                while (j > 0) {
                    uchar3 previous = ordered[j - 1];
                    ordered[j] = max(previous, color);
                    color = min(previous, color);
                    --j;
                }
                ordered[0] = color;
            }
            value.xyz = uchar3(255u - (uint3(ordered[uint(table[0].z)] - ordered[uint(table[0].y)]) << shift));
        }
        output[pixel] = value;
        return;
    }
    float4 center = rasterPremultiply(input[pixel]);
    float4 sum = options.w == 0 ? center : float4(0);
    uint count = uint(table[0].x);
    float total = options.w == 0 ? float(count + 1) : options.w == 1 ? float(count) : 0;
    for (uint i = 1; i <= count; ++i) {
        if (options.w == 1) {
            float2 delta = float2(point) - table[0].yz;
            float2 rotated = float2(table[i].y * delta.x - table[i].x * delta.y,
                                    table[i].x * delta.x + table[i].y * delta.y);
            sum += rasterWarpSample(input, table[0].yz + rotated, options.yz, 1);
        } else {
            float4 value = rasterPremultiply(rasterWarpRead(input, point + int2(table[i].xy), options.yz, 1));
            if (options.w == 0) {
                sum += value;
            } else {
                float4 difference = abs(value - center) / 255;
                float largest = max(max(difference.x, difference.y), max(difference.z, difference.w));
                if (largest < table[0].y) {
                    float weight = table[i].z * (1 - largest / table[0].y);
                    sum += value * weight;
                    total += weight;
                }
            }
        }
    }
    float3 rgb = sum.w > 0 ? sum.xyz * (255.0f / sum.w) : float3(0);
    output[pixel] = uchar4(uchar3(clamp(round(rgb), 0.0f, 255.0f)),
                           uchar(clamp(round(sum.w / total), 0.0f, 255.0f)));
}
float4 rasterPixelateSample(device const uchar4 *input, float2 point, uint2 size, constant float4 *tables) {
    int2 corner = int2(floor(point));
    float2 fraction = point - float2(corner);
    float4 a = rasterLinearPixel(rasterWarpRead(input, corner, size, 1), tables);
    float4 b = rasterLinearPixel(rasterWarpRead(input, corner + int2(1, 0), size, 1), tables);
    float4 c = rasterLinearPixel(rasterWarpRead(input, corner + int2(0, 1), size, 1), tables);
    float4 d = rasterLinearPixel(rasterWarpRead(input, corner + 1, size, 1), tables);
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

kernel void rasterPixelate(device const uchar4 *input [[buffer(0)]], device uchar4 *output [[buffer(1)]],
                            constant float4 *parameters [[buffer(2)]], constant uint4 &options [[buffer(3)]],
                            uint pixel [[thread_position_in_grid]]) {
    if (pixel >= options.x) return;
    uint columns = uint(parameters[0].x);
    int halo = int(parameters[0].y);
    float2 origin = float2(int2(pixel % columns, pixel / columns) - halo) * float(options.w) - 0.5f;
    float stride = float(options.w) / 8;
    constant float4 *tables = parameters + 1;
    float4 sum = rasterPixelateSample(input, origin + float2(3, 1) * stride, options.yz, tables)
               + rasterPixelateSample(input, origin + float2(7, 3) * stride, options.yz, tables)
               + rasterPixelateSample(input, origin + float2(1, 5) * stride, options.yz, tables)
               + rasterPixelateSample(input, origin + float2(5, 7) * stride, options.yz, tables);
    uchar alpha = uchar(clamp(rint(sum.w * (255.0f / 4)), 0.0f, 255.0f));
    if (!alpha) {
        output[pixel] = uchar4(0);
        return;
    }
    float3 color = sum.xyz / sum.w;
    output[pixel] = uchar4(rasterEncode(color.x, 0, tables), rasterEncode(color.y, 1, tables),
                           rasterEncode(color.z, 2, tables), alpha);
}
"""
