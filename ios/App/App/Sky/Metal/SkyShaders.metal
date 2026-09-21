#include <metal_stdlib>
using namespace metal;

struct SkyInstance {
    float2 position;
    float2 positionPadding;
    float4 color0;
    float4 color1;
    float4 color2;
    float size;
    uint flags;
    float turbulence;
    uint tailPadding;
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
    float spectrumLow;
    float spectrumHigh;
};

float2 worldToNDC(float2 world, constant SkyUniforms &uniforms) {
    float2 screen = uniforms.viewport * 0.5 + (world - uniforms.center) * uniforms.scale;
    return float2(screen.x / (uniforms.viewport.x * 0.5) - 1.0,
                  1.0 - screen.y / (uniforms.viewport.y * 0.5));
}

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
    float ringScale = (instance.flags & 0x100) != 0 ? 1.65 : 1.08;
    float audioScale = 1.0;
    if ((instance.flags & 1) != 0) audioScale += uniforms.spectrum.x * 0.04;
    if ((instance.flags & 0x200) != 0) audioScale += uniforms.spectrum.y * 0.06;
    if ((instance.flags & 0x1000) != 0) audioScale += (sin(uniforms.time * 1.15) + 1.0) * 0.035;
    bool backdrop = (instance.flags & 0x800) != 0;
    bool planet = (instance.flags & 2) != 0;
    float pixelsPerPoint = max(1.0, uniforms.spectrum.w);
    float cameraScale = uniforms.scale / pixelsPerPoint;
    float near = smoothstep(0.5, 2.6, cameraScale);
    float focus = smoothstep(1.5, 5.0, cameraScale);
    bool selected = (instance.flags & 0x4000) != 0;
    bool glow = (instance.flags & 1) != 0;
    // Catalogue cores have a point-space semantic minimum, independent of world zoom.
    // 0x8000 is an album core/halo; backdrop particles never inherit this treatment.
    bool album = (instance.flags & 0x8000) != 0;
    float radius = album ? mix(3.6, 5.4, near) : instance.size;
    if ((instance.flags & 0x200) != 0) radius *= 1.12;
    if (selected) radius = mix(3.3, 9.0, focus);
    if (glow) radius = selected ? mix(12.0, 56.0, focus) : mix(9.0, 17.0, near);
    if (backdrop) radius = instance.size;
    if (planet) radius = clamp(instance.size * cameraScale, 10.0, min(uniforms.viewport.x, uniforms.viewport.y) / pixelsPerPoint * 0.34) * ringScale;
    float2 pixelOffset = corner * radius * pixelsPerPoint * audioScale;
    float2 ndcOffset = float2(pixelOffset.x / (uniforms.viewport.x * 0.5),
                              -pixelOffset.y / (uniforms.viewport.y * 0.5));
    SkyVertexOut out;
    float2 backdropOffset = float2(fract(-uniforms.center.x * instance.turbulence * 0.00009), fract(uniforms.center.y * instance.turbulence * 0.00009));
    float2 backdropPosition = fract(instance.position + backdropOffset) * 2.0 - 1.0;
    out.position = float4((backdrop ? backdropPosition : worldToNDC(instance.position, uniforms)) + ndcOffset, 0, 1);
    out.uv = corner * 0.5 + 0.5;
    out.color0 = instance.color0;

    out.color1 = instance.color1;
    out.color2 = instance.color2;
    out.flags = instance.flags;
    out.turbulence = instance.turbulence;
    if (planet) out.color2.a = ringScale;
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
    float cameraScale = uniforms.scale / max(1.0, uniforms.spectrum.w);
    float lengthInPoints = lines[vertexID].positionPadding.x * cameraScale;
    float reveal = lines[vertexID].positionPadding.y > 0 ? 1.0 : smoothstep(0.35, 1.7, cameraScale);
    float local = 1.0 - smoothstep(0.6, 1.1, lengthInPoints / (min(uniforms.viewport.x, uniforms.viewport.y) / max(1.0, uniforms.spectrum.w)));
    out.color0.a *= reveal * local;
    out.color1 = lines[vertexID].color;
    out.color2 = lines[vertexID].color;
    out.flags = 0;
    out.turbulence = 0;
    out.spectrumLow = 0;
    out.spectrumHigh = 0;
    return out;
}

fragment float4 skyStarFragment(SkyVertexOut in [[stage_in]]) {
    float radius = length(in.uv - 0.5) * 2.0;
    if ((in.flags & 0x2000) != 0) {
        float haze = pow(max(0.0, 1.0 - radius), 3.2) * in.color0.a;
        return float4(in.color0.rgb, haze);
    }
    if ((in.flags & 0x8000) != 0) {
        float core = 1.0 - smoothstep(0.25, 0.66, radius);
        float corona = exp(-radius * radius * 5.5) * 0.18;
        float2 axis = abs(in.uv * 2.0 - 1.0);
        float rays = exp(-min(axis.x, axis.y) * 48.0) * pow(max(0.0, 1.0 - radius), 2.0) * 0.18;
        return float4(mix(in.color0.rgb, float3(1.0), core * 0.30),
                      in.color0.a * min(1.0, core + corona + rays));
    }
    float core = smoothstep(1.0, 0.05, radius);
    float spike = max(smoothstep(0.08, 0.0, abs(in.uv.x - 0.5)),
                      smoothstep(0.08, 0.0, abs(in.uv.y - 0.5))) * smoothstep(1.0, 0.0, radius);
    float spikeStrength = 0.5 + in.spectrumHigh * 1.15;
    return float4(in.color0.rgb * (core + spike * spikeStrength), in.color0.a * max(core, spike * (0.35 + in.spectrumHigh * 0.3)));
}

fragment float4 skyGlowFragment(SkyVertexOut in [[stage_in]]) {
    float radius = length(in.uv - 0.5) * 2.0;
    float alpha = pow(max(0.0, 1.0 - radius), 2.4) * in.color0.a * (1.0 + in.spectrumLow * 0.16);
    return float4(in.color0.rgb, alpha);
}

fragment float4 skyLineFragment(SkyVertexOut in [[stage_in]]) {
    return in.color0;
}

float skyNoise(float3 p) {
    float3 cell = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n = dot(cell, float3(1, 57, 113));
    float4 a = fract(sin(n + float4(0, 1, 57, 58)) * 43758.5453);
    float4 b = fract(sin(n + float4(113, 114, 170, 171)) * 43758.5453);
    return mix(mix(mix(a.x, a.y, f.x), mix(a.z, a.w, f.x), f.y),
               mix(mix(b.x, b.y, f.x), mix(b.z, b.w, f.x), f.y), f.z);
}

fragment float4 skyPlanetFragment(SkyVertexOut in [[stage_in]]) {
    float2 p = (in.uv * 2.0 - 1.0) * in.color2.a;
    float r = length(p);
    float edge = max(fwidth(r), 0.002);
    float sphere = 1.0 - smoothstep(1.0 - edge, 1.0, r);
    float3 n = float3(p.x, -p.y, sqrt(max(0.0, 1.0 - dot(p, p))));
    float3 light = normalize(float3(-0.65, 0.45, 0.55));
    float illumination = max(0.0, dot(n, light));
    float3 sample = n * 3.5 + in.turbulence;
    float large = skyNoise(sample);
    float medium = skyNoise(sample * 2.3 + large);
    float detail = 1.0 - smoothstep(0.015, 0.08, fwidth(p.x));
    float fine = detail > 0.01 ? skyNoise(sample * 12.0 + medium * 2.0) : 0.5;
    float noise = large * 0.57 + medium * 0.30 + fine * 0.13;
    float family = fmod(in.turbulence, 4.0);
    float pattern;
    if (family < 1.0) {
        float latitude = p.y + (large - 0.5) * 0.32 + (medium - 0.5) * 0.10;
        float bands = sin(latitude * 25.0 + n.x * 3.5 + large * 4.0);
        float ribbons = sin(latitude * 49.0 + medium * 3.0) * detail;
        float storm = exp(-length((p - float2(0.25, -0.2)) * float2(3.0, 8.0))) * medium;
        pattern = saturate(0.5 + bands * 0.30 + ribbons * 0.12 + storm * 0.3);
    } else if (family < 2.0) {
        pattern = smoothstep(0.33, 0.67, noise);
    } else if (family < 3.0) {
        pattern = smoothstep(0.42, 0.57, large + medium * 0.18);
    } else {
        pattern = saturate(0.4 + abs(n.y) * 0.4 + (medium - 0.5) * 0.5);
    }
    float3 base = mix(in.color0.rgb, in.color1.rgb, pattern);
    base = mix(base, in.color2.rgb, smoothstep(0.63, 0.81, noise) * 0.55);
    float lambert = dot(n, light);
    float terminator = smoothstep(-0.12, 0.18, lambert);
    float relief = mix(1.0, 0.87 + fine * 0.23, detail);
    float3 surface = base * (0.065 + 0.88 * illumination * terminator) * relief;
    float atmosphereStrength = family < 2.0 ? 0.12 : 0.23;
    float3 atmosphereTint = normalize(mix(in.color1.rgb, float3(0.35, 0.50, 0.70), 0.55));
    float rim = pow(1.0 - max(0.0, n.z), 4.5) * (0.12 + illumination * 0.55);
    surface += atmosphereTint * rim * atmosphereStrength;
    float atmosphere = exp(-abs(r - 1.0) * 58.0) * atmosphereStrength;
    float ring = 0;
    if ((in.flags & 0x100) != 0) {
        float ellipse = length(float2(p.x / 1.52, (p.y + p.x * 0.18) / 0.30));
        ring = smoothstep(0.75, 0.82, ellipse) * (1.0 - smoothstep(1.0, 1.05, ellipse));
        if (p.y < 0 && r < 1.0) ring = 0;
    }
    float3 color = surface * sphere + atmosphereTint * atmosphere + mix(in.color1.rgb, float3(0.65), 0.5) * ring * 0.4;
    return float4(color, max(max(sphere, atmosphere), ring * 0.72) * in.color0.a);
}

fragment float4 skyPlanetTextureFragment(
    SkyVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]]) {
    constexpr sampler samplerState(coord::normalized, address::clamp_to_zero, filter::linear);
    float4 color = texture.sample(samplerState, in.uv);
    float ring = (in.flags & 0x100) != 0
        ? smoothstep(0.08, 0.0, abs(length(float2((in.uv.x - 0.5) / 1.42, (in.uv.y - 0.5) / 0.28)) - 0.48))
        : 0.0;
    return float4(color.rgb + in.color0.rgb * ring * 0.42, max(color.a, ring * 0.65));
}
