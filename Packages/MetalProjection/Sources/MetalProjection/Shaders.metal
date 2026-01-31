#include "Shaders.h"

struct FragmentOut {
    half4 color [[color(0)]]; // array, indexed by [[render_target_array_index]]
};

[[vertex]]
FullscreenIn fullscreen_vertex(const uint vertex_id [[vertex_id]],
                               const uint instance_id [[instance_id]],
                               const device uint &viewCount [[buffer(1)]]) {
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
    o.vid = instance_id % viewCount;
    o.iid = instance_id;
    return o;
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
