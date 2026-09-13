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
};

struct SkyVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color0;
    float4 color1;
    float4 color2;
    uint flags [[flat]];
    float turbulence;
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
    float ringScale = (instance.flags & 0x100) != 0 ? 1.5 : 1.0;
    float2 pixelOffset = corner * float2(instance.size * ringScale, instance.size);
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
    return out;
}

fragment float4 skyStarFragment(SkyVertexOut in [[stage_in]]) {
    float radius = length(in.uv - 0.5) * 2.0;
    float core = smoothstep(1.0, 0.05, radius);
    float spike = max(smoothstep(0.08, 0.0, abs(in.uv.x - 0.5)),
                      smoothstep(0.08, 0.0, abs(in.uv.y - 0.5))) * smoothstep(1.0, 0.0, radius);
    return float4(in.color0.rgb * (core + spike * 0.5), in.color0.a * max(core, spike * 0.35));
}

fragment float4 skyGlowFragment(SkyVertexOut in [[stage_in]]) {
    float radius = length(in.uv - 0.5) * 2.0;
    float alpha = pow(max(0.0, 1.0 - radius), 2.4) * in.color0.a;
    return float4(in.color0.rgb * alpha, alpha);
}

fragment float4 skyLineFragment(SkyVertexOut in [[stage_in]]) {
    return in.color0;
}

fragment float4 skyPlanetFragment(SkyVertexOut in [[stage_in]]) {
    float2 centered = in.uv - 0.5;
    float radius = length(centered) * 2.0;
    bool rings = (in.flags & 0x100) != 0;
    float sphere = smoothstep(1.0, 0.94, radius);
    float bands = clamp(in.uv.y * 3.0 + sin(in.uv.x * 18.0) * in.turbulence, 0.0, 2.999);
    float4 color = bands < 1.0 ? in.color0 : (bands < 2.0 ? in.color1 : in.color2);
    float light = 0.52 + 0.48 * max(0.0, dot(normalize(float3(centered, sqrt(max(0.0, 0.25 - dot(centered, centered))))), normalize(float3(-0.5, -0.4, 1.0))));
    float ring = rings ? smoothstep(0.08, 0.0, abs(length(float2(centered.x / 1.42, centered.y / 0.28)) - 0.48)) : 0.0;
    return float4(color.rgb * light * sphere + color.rgb * ring * 0.42, max(sphere, ring * 0.65));
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
