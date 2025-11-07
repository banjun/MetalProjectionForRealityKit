#include <metal_stdlib>
#import "Shaders.h"
using namespace metal;

[[kernel]]
void draw(texture2d<float, access::write> outTexture [[texture(0)]],
          const device Uniforms &uniforms [[buffer(0)]],
          const device Vertex *vertices [[buffer(1)]],
          const device uint32_t *indices [[buffer(2)]],
          constant int &indicesCount [[buffer(3)]],
          uint2 pixelCoord [[thread_position_in_grid]]) {
    auto size = uint2(outTexture.get_width(), outTexture.get_height());
    if (any(pixelCoord >= size)) { return; }

    auto cameraTransform = uniforms.cameraTransform;
    auto cameraPosition = cameraTransform[3].xyz;

    auto uv = (float2(pixelCoord) + 0.5) / float2(size);
    // screen space [-1, +1]
    auto ndc = uv * 2 - 1;
    ndc.y *= -1;
    // normalized deviced coordinate, homogeneous 2->4
    auto ndc4 = float4(ndc.x, ndc.y, 1, 1);
    // view space
    auto pixelCoordInView = (uniforms.projection0Inverse * ndc4);
    auto viewDirectionInView = normalize(pixelCoordInView.xyz / pixelCoordInView.w);
    // world space
    auto viewDirection = (cameraTransform * float4(viewDirectionInView, 0)).xyz;

    auto minDistance = float(INFINITY);
    auto minDiff = float3(INFINITY);
    for (int i = 0; i < indicesCount / 3; ++i) {
        auto a = vertices[i * 3 + 0].position;
        auto b = vertices[i * 3 + 1].position;
        auto c = vertices[i * 3 + 2].position;
        auto n = cross(b - a, c - a);

        auto denom = dot(n, viewDirection);
        if (denom >= 0) { continue; }
        // if (abs(denom) < 0.00001) { continue; }
        auto t = dot(n, a - cameraPosition) / denom;
        if (t < 0) { continue; }
        auto intersection = cameraPosition + t * viewDirection;

        if (dot(cross(b - a, intersection - a), n) > 0 &&
            dot(cross(c - b, intersection - b), n) > 0 &&
            dot(cross(a - c, intersection - c), n) > 0) {
            auto distance = length(intersection - cameraPosition);
            if (distance < minDistance) {
                minDistance = distance;
//                minDiff = intersection - (a + b + c) / 3;
                minDiff = (n + 1) / 2;
            }
        }
    }
    if (minDistance < 10) {
        outTexture.write(float4(minDiff, 1), pixelCoord);
        return;
    }

    auto out = float4(0, 0, 0, 0.5);
    outTexture.write(out, pixelCoord);
}
