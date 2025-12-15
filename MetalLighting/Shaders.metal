#include <metal_stdlib>
#import "Shaders.h"
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
                                       address::repeat);

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

