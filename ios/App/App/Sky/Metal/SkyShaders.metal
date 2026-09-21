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
    float4 surface;
    float4 orientation;
    float4 atmosphere;
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
    uint family [[flat]];
    float4 surface;
    float4 orientation;
    float4 atmosphere;
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
    float ringScale = (instance.flags & 2) != 0 ? instance.surface.w : 1.0;
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
    if (planet) radius = instance.size * ringScale; // CPU-shared projection and culling bounds
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
    out.family = instance.tailPadding;
    out.surface = instance.surface;
    out.orientation = instance.orientation;
    out.orientation.z += uniforms.time * instance.orientation.y;
    out.atmosphere = instance.atmosphere;
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
    out.family = 0;
    out.surface = float4(0);
    out.orientation = float4(0);
    out.atmosphere = float4(0);
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

// Material lighting is linear, with exactly one display transfer at the end.
// Existing scene exposure/backdrop and source-alpha composition are preserved.
float3 planetLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > 0.04045);
}
float3 planetDisplay(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c > 0.0031308);
}
float2 planetRotate(float2 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

fragment float4 skyPlanetFragment(SkyVertexOut in [[stage_in]]) {
    float2 p = (in.uv * 2.0 - 1.0) * in.surface.w;
    float r = length(p), edge = max(fwidth(r), 0.002);
    float body = 1.0 - smoothstep(1.0 - edge, 1.0 + edge, r);
    float3 n = float3(p.x, -p.y, sqrt(max(0.0, 1.0 - dot(p, p))));
    float3 light = normalize(float3(-0.65, 0.45, 0.65));
    float lambert = dot(n, light);
    float daylight = smoothstep(-0.09, 0.19, lambert);
    float3 local = float3(planetRotate(n.xy, in.orientation.x), n.z);
    local.xz = planetRotate(local.xz, in.orientation.z);
    float3 sample = local * 3.2 + in.turbulence;
    // Domain-warped strata: broad sculpted folds, secondary eddies, then fine ridges.
    // Work is bounded and detail fades before it aliases at discovery distance.
    float large = skyNoise(sample);
    float3 warp = float3(large, skyNoise(sample + 19.7), skyNoise(sample - 8.3));
    float3 folded = sample + (warp - 0.5) * 2.8;
    float medium = skyNoise(folded * 2.7);
    float lod = 1.0 - smoothstep(0.012, 0.065, fwidth(p.x));
    float fine = lod > 0.01 ? skyNoise(folded * 11.0 + medium) : 0.5;
    float strataPhase = folded.y * 9.0 + medium * 10.0 + fine * 0.65 * lod;
    float strata = 0.5 + 0.5 * sin(strataPhase);
    float ridge = pow(strata, 9.0);
    float3 dark = planetLinear(in.color0.rgb);
    float3 middle = planetLinear(in.color1.rgb);
    float3 pale = planetLinear(in.color2.rgb);
    float3 albedo = dark;
    float emission = 0, specularMask = 0;
    float cloud = 0;
    if (in.family == 0) { // Ocean, opalescent cloud shelves and controlled water glints.
        // Nacre: deep turquoise basins between opalescent, raised shell-like folds.
        float basin = smoothstep(0.28, 0.72, medium + large * 0.22);
        float pearl = smoothstep(0.42, 0.87, strata) * (0.3 + 0.7 * basin);
        float iridescence = 0.5 + 0.5 * sin(strataPhase * 0.38 + local.x * 4.0);
        float3 shell = mix(pale, planetLinear(float3(0.78, 0.52, 0.68)), iridescence * 0.42);
        albedo = mix(dark * 0.5, middle * 1.25, smoothstep(0.2, 0.8, medium));
        albedo = mix(albedo, shell, pearl * 0.92);
        albedo *= 0.64 + 0.50 * strata; // crevice occlusion, without global exposure changes
        albedo += middle * ridge * 0.45;
        cloud = smoothstep(0.68, 0.87, skyNoise(sample * 1.4 + float3(in.orientation.z * 0.2, 1, 0))) * 0.22;
        albedo = mix(albedo, pale, cloud);
        specularMask = 0.18 + 0.7 * (1.0 - pearl);
        emission = ridge * (1.0 - daylight) * 0.12;
    } else if (in.family == 1) { // Copper giant: sheared bands and a single oval storm.
        float latitude = local.y + (large - 0.5) * 0.24 + (medium - 0.5) * 0.055;
        float band = 0.5 + 0.5 * sin(latitude * 31.0 + medium * 2.4);
        float2 stormPoint = (local.xy - float2(0.30, -0.24)) * float2(3.8, 8.0);
        float stormRadius = length(stormPoint);
        float storm = (1.0 - smoothstep(0.55, 1.3, stormRadius)) * smoothstep(0.05, 0.28, local.z);
        float swirl = 0.5 + 0.5 * sin(stormRadius * 16.0 + atan2(stormPoint.y, stormPoint.x) * 2.0);
        albedo = mix(dark, middle, 0.12 + band * 0.88) * (0.78 + strata * 0.32);
        albedo = mix(albedo, pale, smoothstep(0.70, 0.96, band) * 0.6);
        albedo = mix(albedo, mix(dark, pale, swirl * 0.45), storm * 0.86);
    } else if (in.family == 2) { // Fractured ice plates, glassy ridges and sparse blue seams.
        float ridge = abs(sin((folded.x + folded.y * 0.7) * 8.0 + medium * 3.0));
        float fractures = (1.0 - smoothstep(0.025, 0.09, ridge)) * (0.4 + 0.6 * medium);
        albedo = mix(middle, pale, smoothstep(0.28, 0.7, large));
        albedo = mix(albedo, dark, fractures * 0.9);
        albedo *= 0.76 + 0.30 * smoothstep(0.12, 0.5, ridge);
        specularMask = smoothstep(0.5, 0.8, medium) * 0.35;
    } else if (in.family == 3) { // Rough charcoal plates and sparse connected hot fissures.
        float seam = abs(large - 0.52 + (medium - 0.5) * 0.16);
        float fissure = (1.0 - smoothstep(0.005, 0.025, seam)) * smoothstep(0.42, 0.65, medium);
        albedo = mix(dark, middle, medium * 0.7) * (0.75 + fine * 0.45 * lod);
        emission = fissure * in.surface.z;
    } else if (in.family == 4) { // Subdued satin body lets the inclined ring silhouette lead.
        float latitude = sin(local.y * 15.0 + large * 2.5) * 0.5 + 0.5;
        albedo = mix(dark, middle, 0.3 + latitude * 0.5);
        specularMask = 0.1;
    } else { // Structured twilight continents, luminous polar curtains only.
        albedo = mix(dark, middle, smoothstep(0.42, 0.68, large + medium * 0.12));
        cloud = smoothstep(0.62, 0.82, medium) * in.surface.x;
        albedo = mix(albedo, middle * 1.3, cloud);
        albedo *= 0.7 + 0.5 * strata;
        float polar = exp(-pow((abs(local.y) - 0.72) * 15.0, 2.0));
        float curtain = pow(0.5 + 0.5 * sin(atan2(local.z, local.x) * 23.0 + medium * 5.0), 3.0);
        emission = polar * curtain * in.surface.z * (0.35 + 0.65 * (1.0 - daylight));
    }
    float relief = 1.0 + (fine - 0.5) * 0.18 * lod * in.surface.y;
    // Screen derivatives give the folds real relief under the common light, not a tinted noise decal.
    float reliefHeight = in.family == 0 ? strata * 0.09 : (in.family == 2 ? strata * 0.035 : medium * 0.025);
    float3 reliefNormal = normalize(n + float3(-dfdx(reliefHeight) / max(fwidth(p.x), 0.002),
                                               dfdy(reliefHeight) / max(fwidth(p.y), 0.002), 0) * lod * 0.3);
    float reliefLight = max(0.0, dot(reliefNormal, light));
    float3 surface = albedo * (0.11 + reliefLight * 1.12 * daylight) * relief;
    float highlight = pow(max(0.0, dot(reliefNormal, normalize(light + float3(0, 0, 1)))),
                          mix(100.0, 12.0, in.surface.y));
    surface += float3(0.8, 0.9, 1.0) * highlight * specularMask * 0.42 * daylight;
    surface += pale * emission;
    float limb = pow(1.0 - max(0.0, n.z), 3.5);
    float3 air = planetLinear(in.atmosphere.rgb);
    surface += air * limb * in.atmosphere.w * (0.65 + 1.3 * daylight);
    float atmosphere = exp(-max(0.0, r - 1.0) * 52.0) * (1.0 - body) * in.atmosphere.w;
    atmosphere *= (1.0 - smoothstep(1.05, 1.08, r)) * (0.35 + 0.65 * daylight);
    float alpha = max(body, atmosphere);
    float3 premultiplied = surface * body + air * atmosphere;
    if (in.family == 4) {
        float2 q = planetRotate(p, in.orientation.x - 0.30);
        float inclination = in.orientation.w;
        float ringRadius = length(float2(q.x, q.y / inclination));
        float aa = max(fwidth(ringRadius), 0.004);
        float ring = smoothstep(1.12, 1.12 + aa, ringRadius) * (1.0 - smoothstep(1.59 - aa, 1.59, ringRadius));
        float ringZ = -q.y * sqrt(1.0 - inclination * inclination) / inclination;
        bool front = ringZ > n.z || r >= 1.0;
        float3 ringPoint = float3(p.x, -p.y, ringZ);
        float alongLight = dot(-ringPoint, light);
        float closest = length(ringPoint + light * max(0.0, alongLight));
        float shadow = alongLight > 0 ? smoothstep(0.88, 1.06, closest) : 1.0;
        float grooves = 0.78 + 0.15 * sin(ringRadius * 110.0) * lod;
        float gap = 1.0 - 0.7 * exp(-pow((ringRadius - 1.38) * 95.0, 2.0));
        float opacity = ring * grooves * gap * 0.80;
        float3 ringColor = mix(pale, middle, 0.3) * (0.18 + shadow * 0.82);
        if (front) {
            premultiplied = ringColor * opacity + premultiplied * (1.0 - opacity);
            alpha = opacity + alpha * (1.0 - opacity);
        }
    }
    float3 color = premultiplied / max(alpha, 0.0001);
    return float4(planetDisplay(color), alpha * in.color0.a);
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
