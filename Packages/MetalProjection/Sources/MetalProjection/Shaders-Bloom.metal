#include "Shaders.h"

constant bool kUseVRS [[function_constant(0)]];

[[fragment]]
half4 bright_fragment(FullscreenIn in [[stage_in]],
                       texture2d_array<half> scene [[texture(0)]]) {
    auto threshold = 0.1;
    auto boost = 4.0;
    auto c = scene.sample(linearSampler, in.uv, in.vid).rgb;
    auto luminance = dot(c, half3(0.2126, 0.7152, 0.0722));
    return half4(luminance > threshold ? c * boost : 0.0, 1.0);
}

[[fragment]]
half4 bloom_fragment(FullscreenIn in [[stage_in]],
                     texture2d_array<half> bright [[texture(0)]],
                     constant float2 &kawase_offset [[buffer(0)]],
                     constant float &intensity [[buffer(1)]],
                     constant float &spread [[buffer(2)]],
                     constant rasterization_rate_map_data &rrmd [[buffer(10)]]) {
    float2 o = kawase_offset;
    float2 offsets[8] = {
        float2( o.x,  0.0),
        float2(-o.x,  0.0),
        float2( 0.0,  o.y),
        float2( 0.0, -o.y),
        float2( o.x,  o.y),
        float2(-o.x,  o.y),
        float2( o.x, -o.y),
        float2(-o.x, -o.y),
    };
    // kawase blur with pow
    float p = 1.05;
    half3 c = 0.0;
    auto uv = in.uv;
    rasterization_rate_map_decoder rateMap(rrmd);
    if (kUseVRS) {
        uv = rateMap.map_physical_to_screen_coordinates(in.uv, in.iid); // FIXME: maybe use actual screen, not just parent rate map. maybe use pixel coord
        // FIXME: currently rate map distortion is not corrected in this shader with ratemap
    }
    for (int i = 0; i < 8; ++i) {
        auto pos = uv + offsets[i] * spread;
        if (kUseVRS) {
            pos = rateMap.map_screen_to_physical_coordinates(pos, in.iid);
        }
        c += pow(bright.sample(linearSampler, pos, in.iid).rgb, p);
    }
    // add center focus
    auto centerColor = bright.sample(linearSampler, in.uv, in.iid).rgb;
    c += pow(centerColor * intensity, p);
    // restore pow value
    c *= pow(1.0 / (8.0 + 1.5), 1 / p);
    return half4(c, 1);
}
