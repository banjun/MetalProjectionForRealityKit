#include <metal_stdlib>
#import "Shaders.h"
using namespace metal;

[[kernel]]
void draw(texture2d<float, access::write> outTexture0 [[texture(0)]],
          texture2d<float, access::write> outTexture1 [[texture(1)]],
          const device Uniforms &uniforms [[buffer(0)]],
          const device Vertex *vertices [[buffer(1)]],
          const device uint32_t *indices [[buffer(2)]],
          constant int &indicesCount [[buffer(3)]],
          uint2 pixelCoord [[thread_position_in_grid]]) {
    auto size = uint2(outTexture0.get_width(), outTexture0.get_height());
    if (any(size != uint2(outTexture1.get_width(), outTexture1.get_height()))) { return; }
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
    float4 pixelCoordInViews[] = {
        uniforms.projection0Inverse * ndc4,
        uniforms.projection1Inverse * ndc4,
    };
    texture2d<float, access::write> outTextures[] = {outTexture0, outTexture1};

    for (int vid = 0; vid < 2; ++vid) {
        auto pixelCoordInView = pixelCoordInViews[vid];
        auto outTexture = outTextures[vid];
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
        } else {
            outTexture.write(float4(0, 0, 0, 0.5), pixelCoord);
        }
    }
}
