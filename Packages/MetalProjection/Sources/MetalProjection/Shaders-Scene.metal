#include "Shaders.h"

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
    float2 uv;
    half2 normal;
    half4 viewPos;
};
struct FragmentOut {
    half4 color [[color(0)]]; // array, indexed by [[render_target_array_index]]
    half2 normal [[color(1)]];
    half4 viewPos [[color(2)]];
    half4 emissive [[color(3)]];
};

[[vertex]]
VertexOut gbuffer_vertex(VertexIn in [[stage_in]],
                         const device VertexUniforms *uniforms [[buffer(1)]],
                         const uint vid [[instance_id]]) {
    auto uniform = uniforms[vid];
    auto pModel4 = float4(in.position, 1); // assuming in.position is in model pos
    auto pWorld4 = uniform.worldFromModelTransform * pModel4;
    auto pView4 = uniform.cameraFromWorldTransform * pWorld4;
    auto pClip4 = uniform.projectionFromCameraTransform * pView4;

    return VertexOut {
        .position = pClip4,
        .uv = in.uv,
        .normal = half2(normalize((uniform.cameraFromModelTransform * float4(in.normal, 0)).xyz).xy), // TODO: use NormalMatrix as normal is inverse-transpos
        .viewPos = half4(pView4),
        .vid = vid,
    };
}

[[fragment]]
FragmentOut gbuffer_fragment(VertexOut in [[stage_in]],
                             constant FragmentUniforms &uniforms [[buffer(0)]]) {
    FragmentOut out;
    auto uv = in.uv;
    uv.y = 1 - uv.y;

    if (uniforms.flags & HasBaseColorTexture) {
        out.color = uniforms.baseColorTexture.sample(linearSampler, uv);
    } else {
        out.color = half4(uniforms.baseColor, 1);
    }

    if (uniforms.flags & HasEmissiveColorTexture) {
        out.emissive = uniforms.emissiveColorTexture.sample(linearSampler, uv);
    } else {
        out.emissive = half4(uniforms.emissiveColor, 1);
    }

    // TODO
    out.normal = in.normal;
    out.viewPos = in.viewPos;
    return out;
}
