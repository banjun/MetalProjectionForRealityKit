#include <metal_stdlib>
#import "Shaders.h"
using namespace metal;

[[kernel]]
void draw(texture2d<float, access::write> outTexture [[texture(0)]],
          const device Uniforms &uniforms [[buffer(1)]],
          uint2 pixelCoord [[thread_position_in_grid]]) {
    auto size = uint2(outTexture.get_width(), outTexture.get_height());
    if (any(pixelCoord >= size)) { return; }
    const float2 uv = float2(pixelCoord) / float2(size);

    const float4 out = float4(uv.x, uv.y, 0, 1);
    outTexture.write(out, pixelCoord);
}
