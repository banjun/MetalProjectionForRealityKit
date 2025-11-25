#include <metal_stdlib>
#import "Shaders.h"
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
};
struct VertexOut {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
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
    return out;
}

[[fragment]]
FragmentOut render_fragment(VertexOut in [[stage_in]],
                            const device FragmentUniforms &uniforms [[buffer(2)]]) {
    auto textureSize = uniforms.textureSize;
    FragmentOut out;
    // TODO
    out.color = float4(in.position.xy / float2(textureSize), 0, 1);
    return out;
}

