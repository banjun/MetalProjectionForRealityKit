#include "Shaders.h"

constant bool kUseVRS [[function_constant(0)]];

[[fragment]]
half4 composite_fragment(FullscreenIn in [[stage_in]],
                         texture2d_array<half> scene [[texture(0)]],
                         texture2d_array<half> emissive [[texture(1)]],
                         texture2d_array<half> bloom [[texture(2)]],
                         texture2d_array<half> volumeLight [[texture(3)]],
                         texture2d_array<half> surfaceLight [[texture(4)]],
                         constant rasterization_rate_map_data &rrmd [[buffer(10)]],
                         constant float *texIntensities [[buffer(0)]]) {
    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 xy = in.position.xy;
    if (kUseVRS) {
        rasterization_rate_map_decoder map(rrmd);
        xy = map.map_screen_to_physical_coordinates(xy, in.vid);
    }

    texture2d_array<half> textures[] = {scene, emissive, bloom, volumeLight, surfaceLight};
    auto out = half4(0);
    for(int i = 0; i < 5; ++i) {
        auto v = textures[i].sample(s, xy, in.vid);
        out += v * half(texIntensities[i]);
    }
    return out;
}
