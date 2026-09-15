#include <metal_stdlib>
using namespace metal;

// Aeon's sky.
//
// Three things draw here and they are deliberately different from one another:
// the field (nebula and dust, a fullscreen pass beneath everything), the stars
// (albums, drawn with real optics so they never read as dust), and the planets
// (eras, shaded as bodies rather than stamped as discs).
//
// The ground is black and stays black. Dust sits near the threshold of
// visibility on purpose — on an OLED panel almost every pixel of an empty sky
// is switched off, and that is what makes one album star look like light.

struct SkyInstance {
    float2 position;
    float2 positionPadding;
    float4 color0;
    float4 color1;
    float4 color2;
    float size;
    uint flags;
    float turbulence;
    float seed;
};

struct SkyLine {
    float2 position;
    float2 positionPadding;
    float4 color;
};

struct SkyUniforms {
    float2 center;
    float2 viewport;
    float scale;
    float time;
    float4 spectrum;
};

struct SkyVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color0;
    float4 color1;
    float4 color2;
    uint flags [[flat]];
    float turbulence;
    float seed;
    float spectrumLow;
    float spectrumHigh;
};

struct SkyFieldOut {
    float4 position [[position]];
};

// MARK: - noise

static inline float hash21(float2 p) {
    p = fract(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

static inline float hash31(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

static inline float valueNoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash31(i), hash31(i + float3(1, 0, 0)), f.x),
                  mix(hash31(i + float3(0, 1, 0)), hash31(i + float3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(hash31(i + float3(0, 0, 1)), hash31(i + float3(1, 0, 1)), f.x),
                  mix(hash31(i + float3(0, 1, 1)), hash31(i + float3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

static inline float fbm(float3 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * valueNoise(p);
        p *= 2.07;
        amplitude *= 0.5;
    }
    return sum;
}

float2 worldToNDC(float2 world, constant SkyUniforms &uniforms) {
    float2 screen = uniforms.viewport * 0.5 + (world - uniforms.center) * uniforms.scale;
    return float2(screen.x / (uniforms.viewport.x * 0.5) - 1.0,
                  1.0 - screen.y / (uniforms.viewport.y * 0.5));
}

// MARK: - the field

vertex SkyFieldOut skyFieldVertex(uint vertexID [[vertex_id]]) {
    const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SkyFieldOut out;
    out.position = float4(corners[vertexID], 0, 1);
    return out;
}

/// Three depth layers of dust, each parallaxed by a different fraction of the
/// camera, so panning the sky reads as distance rather than as a moving
/// wallpaper. Cells are sized in pixels, which keeps the field equally deep at
/// every zoom.
static inline float dustField(float2 pixel, constant SkyUniforms &uniforms) {
    const float cellSize[3] = { 52.0, 34.0, 25.0 };
    const float parallax[3] = { 0.06, 0.15, 0.30 };
    const float threshold[3] = { 0.955, 0.966, 0.974 };
    const float weight[3] = { 0.85, 0.62, 0.45 };
    float total = 0.0;
    for (int i = 0; i < 3; i++) {
        float2 p = (pixel + uniforms.center * uniforms.scale * parallax[i]) / cellSize[i];
        float2 cell = floor(p);
        float h = hash21(cell + float(i) * 37.0);
        if (h <= threshold[i]) continue;
        float2 offset = float2(hash21(cell + 11.3), hash21(cell + 27.7));
        float d = length(fract(p) - offset);
        float point = smoothstep(0.16, 0.0, d) * (h - threshold[i]) / (1.0 - threshold[i]);
        float twinkle = 0.78 + 0.22 * sin(uniforms.time * 0.9 + h * 61.0);
        total += point * twinkle * weight[i];
    }
    return total;
}

fragment float4 skyFieldFragment(
    SkyFieldOut in [[stage_in]],
    constant SkyUniforms &uniforms [[buffer(0)]]) {
    float2 pixel = in.position.xy;
    float2 ndc = (pixel / uniforms.viewport) * 2.0 - 1.0;

    // Nebula lives in world space, so it stays put when the camera moves.
    float2 world = (pixel - uniforms.viewport * 0.5) / max(uniforms.scale, 0.0001) + uniforms.center;
    float3 q = float3(world * 0.00042, uniforms.time * 0.004);
    float n = fbm(q, 4);
    float m = fbm(float3(world * 0.00019, 7.0), 3);
    float mask = smoothstep(0.46, 1.04, n * 0.78 + m * 0.58);
    float3 violet = float3(0.20, 0.15, 0.42);
    float3 teal = float3(0.04, 0.17, 0.26);
    float3 cloud = mix(teal, violet, smoothstep(0.25, 0.80, m));
    // Lows breathe the nebula; the response is slow and region-wide.
    float breath = 0.30 + 0.22 * uniforms.spectrum.x;
    float3 color = cloud * mask * breath;

    color += float3(0.86, 0.91, 1.0) * dustField(pixel, uniforms) * 0.16;

    float vignette = smoothstep(1.45, 0.20, length(ndc * float2(0.92, 1.0)));
    color *= 0.62 + 0.38 * vignette;
    // Shoulder rather than clip, then let the black stay black.
    color = color / (color + 0.9) * 1.34;
    color += (hash31(float3(pixel, floor(uniforms.time * 24.0))) - 0.5) * 0.011;
    return float4(max(color, 0.0), 1.0);
}

// MARK: - instances

vertex SkyVertexOut skyInstanceVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant SkyInstance *instances [[buffer(0)]],
    constant SkyUniforms &uniforms [[buffer(1)]]) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    SkyInstance instance = instances[instanceID];
    float2 corner = corners[vertexID];
    float ringScale = (instance.flags & 0x100) != 0 ? 2.4 : 1.0;
    float audioScale = 1.0;
    if ((instance.flags & 1) != 0) audioScale += uniforms.spectrum.x * 0.18;
    if ((instance.flags & 0x200) != 0) audioScale += uniforms.spectrum.y * 0.62;
    float2 pixelOffset = corner * float2(instance.size * ringScale, instance.size) * audioScale;
    float2 ndcOffset = float2(pixelOffset.x / (uniforms.viewport.x * 0.5),
                              -pixelOffset.y / (uniforms.viewport.y * 0.5));
    SkyVertexOut out;
    out.position = float4(worldToNDC(instance.position, uniforms) + ndcOffset, 0, 1);
    out.uv = corner * 0.5 + 0.5;
    out.color0 = instance.color0;
    out.color1 = instance.color1;
    out.color2 = instance.color2;
    out.flags = instance.flags;
    out.turbulence = instance.turbulence;
    out.seed = instance.seed;
    out.spectrumLow = uniforms.spectrum.x;
    out.spectrumHigh = (instance.flags & 0x400) != 0 ? uniforms.spectrum.z : 0.0;
    return out;
}

vertex SkyVertexOut skyLineVertex(
    uint vertexID [[vertex_id]],
    constant SkyLine *lines [[buffer(0)]],
    constant SkyUniforms &uniforms [[buffer(1)]]) {
    SkyVertexOut out;
    out.position = float4(worldToNDC(lines[vertexID].position, uniforms), 0, 1);
    out.uv = float2(0.5);
    out.color0 = lines[vertexID].color;
    out.color1 = lines[vertexID].color;
    out.color2 = lines[vertexID].color;
    out.flags = 0;
    out.turbulence = 0;
    out.seed = 0;
    out.spectrumLow = 0;
    out.spectrumHigh = 0;
    return out;
}

/// An album star: a hard core, a wide soft halo, and four diffraction spikes.
/// Dust has none of these, which is how the two stay legible as different kinds
/// of thing without a label anywhere near them.
fragment float4 skyStarFragment(SkyVertexOut in [[stage_in]]) {
    float2 d = (in.uv - 0.5) * 2.0;
    float r = length(d);
    float core = exp(-(r * r) / 0.052);
    float halo = exp(-r * 3.4) * 0.22;
    float spikeLength = 1.0 + in.spectrumHigh * 0.45;
    float sx = max(0.0, 1.0 - abs(d.x) / spikeLength) * exp(-abs(d.y) * 12.0);
    float sy = max(0.0, 1.0 - abs(d.y) / spikeLength) * exp(-abs(d.x) * 12.0);
    float spikes = (sx * sx + sy * sy) * (0.34 + in.spectrumHigh * 0.5);
    float mark = core + halo + spikes;
    return float4(in.color0.rgb * mark * in.color0.a, mark * in.color0.a);
}

fragment float4 skyGlowFragment(SkyVertexOut in [[stage_in]]) {
    float radius = length(in.uv - 0.5) * 2.0;
    float alpha = pow(max(0.0, 1.0 - radius), 3.0) * in.color0.a * (1.0 + in.spectrumLow * 0.16);
    return float4(in.color0.rgb * alpha, alpha);
}

fragment float4 skyLineFragment(SkyVertexOut in [[stage_in]]) {
    return in.color0;
}

// MARK: - planets

/// A planet is shaded as a body: bands from its own contents, a soft
/// terminator, a rim where the light wraps the limb, an atmosphere just outside
/// it, and — when the era was genre-pure — a ring that passes behind the
/// sphere and casts the planet's shadow on itself.
static inline float4 shadePlanet(SkyVertexOut in, float ringScale) {
    // The quad is widened for the ring; put the sphere back in the middle of it.
    float2 centered = float2((in.uv.x - 0.5) * 2.0 * ringScale, (in.uv.y - 0.5) * 2.0);
    float r = length(centered);
    float seed = in.seed;
    bool hasRings = (in.flags & 0x100) != 0;
    const float3 light = normalize(float3(-0.34, 0.46, 0.82));

    float3 color = float3(0.0);
    float alpha = 0.0;

    // Ring behind the sphere.
    float2 ringSpace = float2(centered.x, (centered.y - 0.06) / mix(0.20, 0.34, fract(seed * 0.37)));
    float ringRadius = length(ringSpace);
    float ringBand = smoothstep(1.28, 1.36, ringRadius) * (1.0 - smoothstep(2.00, 2.20, ringRadius));
    float ringGrain = 0.45 + 0.55 * fbm(float3(ringRadius * 7.0, seed, 0.0), 3);
    float3 ringColor = mix(in.color1.rgb, float3(0.86, 0.89, 0.96), 0.55) * ringGrain;
    // The planet's own shadow falls across the ring on the side away from the light.
    float ringShadow = (dot(normalize(centered + 1e-5), light.xy) < 0.0 && abs(centered.y) < 0.62 && ringRadius < 1.9)
        ? 0.30 : 1.0;
    float ringAlpha = hasRings ? ringBand * ringGrain * 0.62 * ringShadow : 0.0;
    bool ringIsBehind = centered.y > 0.06;
    if (ringAlpha > 0.0 && ringIsBehind) {
        color = ringColor;
        alpha = ringAlpha;
    }

    // The body.
    if (r < 1.0) {
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 n = normalize(float3(centered, z));
        float bands = fbm(float3(n.x * 1.5, n.y * 6.5 + seed * 3.1, n.z * 1.5) + seed, 4);
        float swirl = fbm(n * 3.2 + seed * 2.0, 3) * in.turbulence * 3.0;
        float mixed = clamp(bands * 0.8 + swirl * 0.4 + n.y * 0.22 + 0.2, 0.0, 1.0);
        float3 base = mixed < 0.45
            ? mix(in.color0.rgb, in.color1.rgb, smoothstep(0.0, 0.45, mixed))
            : mix(in.color1.rgb, in.color2.rgb, smoothstep(0.45, 1.0, mixed));
        float lambert = max(dot(n, light), 0.0);
        float terminator = smoothstep(0.0, 0.34, lambert);
        float rim = pow(1.0 - z, 3.0);
        float3 body = base * (0.06 + 1.28 * lambert * terminator)
            + float3(0.64, 0.76, 1.0) * rim * 0.42 * (0.28 + lambert);
        float edge = smoothstep(1.0, 0.985, r);
        color = mix(color, body, edge);
        alpha = max(alpha, edge);
    } else {
        // Atmosphere: a thin lit halo just outside the limb.
        float limb = smoothstep(1.26, 1.0, r) * 0.30;
        color = mix(color, float3(0.42, 0.58, 0.95), limb);
        alpha = max(alpha, limb);
    }

    // Ring in front of the sphere.
    if (ringAlpha > 0.0 && !ringIsBehind) {
        color = mix(color, ringColor, ringAlpha);
        alpha = max(alpha, ringAlpha);
    }

    return float4(color, alpha);
}

fragment float4 skyPlanetFragment(SkyVertexOut in [[stage_in]]) {
    return shadePlanet(in, (in.flags & 0x100) != 0 ? 2.4 : 1.0);
}

fragment float4 skyPlanetTextureFragment(
    SkyVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]]) {
    constexpr sampler samplerState(coord::normalized, address::clamp_to_zero, filter::linear);
    float ringScale = (in.flags & 0x100) != 0 ? 2.4 : 1.0;
    float4 shaded = shadePlanet(in, ringScale);
    // The generated texture carries the era's own surface; the shading above
    // gives it light. Sample it across the sphere only.
    float2 sphereUV = float2((in.uv.x - 0.5) * ringScale + 0.5, in.uv.y);
    if (sphereUV.x >= 0.0 && sphereUV.x <= 1.0) {
        float4 surface = texture.sample(samplerState, sphereUV);
        float2 centered = float2((sphereUV.x - 0.5) * 2.0, (in.uv.y - 0.5) * 2.0);
        float inside = smoothstep(1.0, 0.985, length(centered));
        shaded.rgb = mix(shaded.rgb, mix(shaded.rgb, surface.rgb * 1.15, 0.55), inside * surface.a);
    }
    return shaded;
}
