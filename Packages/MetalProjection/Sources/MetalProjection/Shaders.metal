#include <metal_stdlib>
#include "../MetalProjectionBridgingHeader/include/Shaders.h"
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    simd_float2 uv [[attribute(1)]];
    simd_float3 normal [[attribute(2)]];
    simd_float3 tangent [[attribute(3)]];
    simd_float3 bitangent [[attribute(4)]];
};
struct VertexOut {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
    Vertex v;
};
struct FragmentOut {
    float4 color [[color(0)]]; // array, indexed by [[render_target_array_index]]
};

[[vertex]]
VertexOut render_vertex(VertexIn in [[stage_in]],
                        const device VertexUniforms *uniforms [[buffer(1)]],
                        const uint vid [[instance_id]]) {
    auto uniform = uniforms[vid];
    auto pModel4 = float4(in.position, 1); // assuming in.position is in model pos
    auto pWorld4 = uniform.modelTransform * pModel4;
    auto pView4 = uniform.cameraTransformInverse * pWorld4;
    auto pClip4 = uniform.projection * pView4;

    VertexOut out;
    out.position = pClip4;
    out.vid = vid;
    out.v.position = in.position;
    out.v.uv = in.uv;
    out.v.normal = in.normal;
    out.v.tangent = in.tangent;
    out.v.bitangent = in.bitangent;
    return out;
}

constexpr auto linearSampler = sampler(filter::linear,
                                       mip_filter::linear,
                                       address::clamp_to_edge);
constexpr auto nearestSampler = sampler(filter::nearest,
                                        mip_filter::nearest,
                                        address::clamp_to_edge);

[[fragment]]
FragmentOut render_fragment(VertexOut in [[stage_in]],
                            texture2d<float> baseColorTexture [[texture(0)]],
                            const device FragmentUniforms &uniforms [[buffer(2)]]) {
    // auto textureSize = uniforms.textureSize;
    auto uv = in.v.uv;
    auto baseColor = baseColorTexture.sample(linearSampler, float2(uv.x, 1 - uv.y));
    FragmentOut out;
    // TODO
    out.color = baseColor;
    return out;
}

struct FullscreenIn {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
    float2 uv;
};

[[vertex]]
FullscreenIn fullscreen_vertex(const uint vertex_id [[vertex_id]], const uint instance_id [[instance_id]]) {
    float2 pos[3] = {
        float2(-1, -1),
        float2( 3, -1),
        float2(-1,  3),
    };
    float2 uv[3] = {
        float2(0, 1 - 0),
        float2(2, 1 - 0),
        float2(0, 1 - 2),
    };
    FullscreenIn o;
    o.position = float4(pos[vertex_id], 0, 1);
    o.uv = uv[vertex_id];
    o.vid = instance_id;
    return o;
}

[[fragment]]
float4 bright_fragment(FullscreenIn in [[stage_in]],
                       texture2d_array<float> scene [[texture(0)]]) {
    auto threshold = 0.1;
    auto boost = 4.0;
    auto c = scene.sample(linearSampler, in.uv, in.vid).rgb;
    auto luminance = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float4(luminance > threshold ? c * boost : 0.0, 1.0);
}

[[fragment]]
float4 bloom_fragment(FullscreenIn in [[stage_in]],
                      texture2d_array<float> bright [[texture(0)]],
                      const device float2 &kawase_offset [[buffer(0)]]) {
    auto c = float3(0.0);
    auto weight = 1.0 / 4.0;
    auto offset = kawase_offset;
    c += bright.sample(linearSampler, in.uv + float2(-offset.x, -offset.y), in.vid).rgb * weight;
    c += bright.sample(linearSampler, in.uv + float2(-offset.x, +offset.y), in.vid).rgb * weight;
    c += bright.sample(linearSampler, in.uv + float2(+offset.x, -offset.y), in.vid).rgb * weight;
    c += bright.sample(linearSampler, in.uv + float2(+offset.x, +offset.y), in.vid).rgb * weight;
    return float4(c, 1);
}

[[fragment]]
float4 copy(FullscreenIn in [[stage_in]],
            texture2d_array<float> tex [[texture(0)]]) {
    return tex.sample(nearestSampler, in.uv, in.vid);
}
[[fragment]]
float4 copyDepthToColor(FullscreenIn in [[stage_in]],
                        depth2d_array<float> depth [[texture(0)]]) {
    auto d = depth.sample(nearestSampler, in.uv, in.vid);
    return float4(float3(d), 1);
}

[[fragment]]
float4 volumeLight_fragment(FullscreenIn in [[stage_in]],
                            depth2d_array<float> depth [[texture(0)]],
                            const device Uniforms &uniforms [[buffer(0)]],
                            const device VolumeSpotLight *lights [[buffer(1)]],
                            const device int &lightCount [[buffer(2)]]) {
    simd_float4x4 projections[] = {uniforms.projection0, uniforms.projection1};
    simd_float4x4 projectionInverses[] = {uniforms.projection0Inverse, uniforms.projection1Inverse};
    simd_float4x4 cameraTransforms[] = {uniforms.cameraTransformL, uniforms.cameraTransformR};
    auto projection = projections[in.vid];
    auto projectionInverse = projectionInverses[in.vid];
    auto cameraTransform = cameraTransforms[in.vid];

    auto ndc = in.uv * 2 - 1;
    auto ndc4 = float4(ndc.x, -ndc.y, 1, 1);
    auto pView4 = projectionInverse * ndc4;
    auto viewDirectionInView = pView4.xyz / pView4.w;
    auto viewDirectionInWorld = normalize((cameraTransform * float4(viewDirectionInView, 0)).xyz);

    auto t = 0.0;
    auto cameraPos = cameraTransform.columns[3].xyz;
    auto stepSize = 0.1;
    auto MAX_STEPS = 128.0;
    auto maxDistance = 5.0;
    auto color = float3(0);

    for (int i = 0; i < MAX_STEPS; i++) {
        auto pos = cameraPos + viewDirectionInWorld * maxDistance * i / MAX_STEPS;
        for (int l = 0; l < lightCount; l++) {
            auto light = lights[l];
            auto posFromLight = pos - light.position;
            auto angle = dot(normalize(posFromLight), light.direction);
            if (angle > light.angleCos) {
                auto distanceAttenuation = 1 / length_squared(posFromLight);
                color += light.color * light.intensity * distanceAttenuation / MAX_STEPS;
            }
        }
    }
    return float4(color, 1);
}

[[fragment]]
float4 composite_fragment(FullscreenIn in [[stage_in]],
                          texture2d_array<float> scene [[texture(0)]],
                          texture2d_array<float> bloom [[texture(1)]],
                          texture2d_array<float> light [[texture(2)]]) {
    auto s = scene.sample(linearSampler, in.uv, in.vid);
    auto b = bloom.sample(linearSampler, in.uv, in.vid);
    auto l = light.sample(linearSampler, in.uv, in.vid);
    auto bloomIntensity = 0.25;
    auto lightIntensity = 0.5;
    return float4(s * 0 + b * bloomIntensity + l * lightIntensity);
}
