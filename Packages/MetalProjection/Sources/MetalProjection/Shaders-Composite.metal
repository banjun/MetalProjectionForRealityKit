#include "Shaders.h"

[[fragment]]
half4 composite_fragment(FullscreenIn in [[stage_in]],
                         texture2d_array<half> scene [[texture(0)]],
                         texture2d_array<half> emissive [[texture(1)]],
                         texture2d_array<half> bloom [[texture(2)]],
                         texture2d_array<half> volumeLight [[texture(3)]],
                         texture2d_array<half> surfaceLight [[texture(4)]],
                         constant float *texIntensities [[buffer(0)]]) {
    texture2d_array<half> textures[] = {scene, emissive, bloom, volumeLight, surfaceLight};
    auto out = half4(0);
    for(int i = 0; i < 5; ++ i) {
        auto v = textures[i].sample(linearSampler, in.uv, in.vid);
        out += v * texIntensities[i];
    }
    return out;
}
