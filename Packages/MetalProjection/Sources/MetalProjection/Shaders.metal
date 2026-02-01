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

[[kernel]]
void packORM(texture2d<half, access::sample> aoTex [[texture(0)]],
             texture2d<half, access::sample> roughTex [[texture(1)]],
             texture2d<half, access::sample> metalTex [[texture(2)]],
             texture2d<half, access::write> outTex [[texture(3)]],
             constant uint32_t *flags [[buffer(0)]],
             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float2 uv = float2(gid) / float2(outTex.get_width(), outTex.get_height());

    auto roughnessGamma = half(1.0 / 2.2); // from generic gray gamma 2.2?

    auto out = half4(0);
    out.r = flags[0] * aoTex.sample(linearSampler, uv).r;
    out.g = flags[1] * pow(roughTex.sample(linearSampler, uv).r, roughnessGamma);
    out.b = flags[2] * metalTex.sample(linearSampler, uv).r;
    outTex.write(out, gid);
}
