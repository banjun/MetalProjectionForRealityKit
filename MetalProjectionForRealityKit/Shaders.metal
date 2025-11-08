#include <metal_stdlib>
#import "Shaders.h"
using namespace metal;

struct IntersectionResult {
    bool hit;
    float3 point;
    float3 n;
    bool onFront;
};

static IntersectionResult intersectTriangle(float3 a,
                                            float3 b,
                                            float3 c,
                                            float3 rayOrigin,
                                            float3 rayDirection) {
    IntersectionResult r = {false, float3(0), float3(0), false};
    auto n = normalize(cross(b - a, c - a));
    r.n = n;

    auto denom = dot(n, rayDirection);
    r.onFront = denom < 0;
    // if (abs(denom) < 0.00001) { continue; }
    auto t = dot(n, a - rayOrigin) / denom;
    if (t < 0.00001) {
        r.hit = false;
        return r;
    }

    auto intersection = rayOrigin + t * rayDirection;
    r.point = intersection;
    r.hit = (dot(cross(b - a, intersection - a), n) > 0 &&
             dot(cross(c - b, intersection - b), n) > 0 &&
             dot(cross(a - c, intersection - c), n) > 0);
    return r;
}

static float4 colorHit(float3 cameraPosition,
                       float3 viewDirection,
                       const device Vertex *vertices,
                       const device uint32_t *indices,
                       const device int &indicesCount) {
    auto minDistance = float(INFINITY);
    auto minDiff = float3(INFINITY);
    for (int i = 0; i < indicesCount / 3; ++i) {
        auto intersection = intersectTriangle(vertices[indices[i * 3 + 0]].position,
                                              vertices[indices[i * 3 + 1]].position,
                                              vertices[indices[i * 3 + 2]].position,
                                              cameraPosition,
                                              viewDirection);
        if (intersection.hit && intersection.onFront) {
            auto distance = length(intersection.point - cameraPosition);
            if (distance < minDistance) {
                minDistance = distance;
                //                minDiff = intersection - (a + b + c) / 3;
                minDiff = (intersection.n + 1) / 2;
            }
        }
    }
    if (minDistance < 10) {
        return float4(minDiff, 1);
    } else {
        return float4(0, 0, 0, 0.5);
    }
}

static float fresnelSchlick(float cosTheta, float F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

static float4 uvRefractionAndReflection(float3 rayOrigin,
                                        float3 rayDirection,
                                        const device Vertex *vertices,
                                        const device uint32_t *indices,
                                        const device int &indicesCount) {
    int sinkMask = 1;
    float eta = 1 / 1.49;
    float F0 = 0.04;
    float attenuation = 1;
    // search sink surface.
    // assuming cube-ish shape.
    // bounce on front -> bounce on back * 0-2 times -> bounce on sink surface
    for (int bounce = 0; bounce < 10; ++bounce) {
        auto minDistance = float(INFINITY);
        auto minDiff = float3(INFINITY);
        int3 minMask = int3(0);
        IntersectionResult minIntersection = {false, float3(0), float3(0), false};
        for (int i = 0; i < indicesCount / 3; ++i) {
            auto a = vertices[indices[i * 3 + 0]];
            auto b = vertices[indices[i * 3 + 1]];
            auto c = vertices[indices[i * 3 + 2]];
            auto intersection = intersectTriangle(a.position,
                                                  b.position,
                                                  c.position,
                                                  rayOrigin,
                                                  rayDirection);
            if (intersection.hit) {
                auto distance = length(intersection.point - rayOrigin);
                if (distance < minDistance) {
                    minDistance = distance;
                    minIntersection = intersection;
                    //                minDiff = intersection - (a + b + c) / 3;
                    minDiff = (intersection.n + 1) / 2;
                    minMask = int3(a.mask, b.mask, c.mask);
                }
            }
        }
        if (minDistance < 10) {
            if (all(minMask == sinkMask)) {
                // nearest hit is sink. conclude on the sink surface
                return float4((minIntersection.point.x - 0.5) * 4 + 0.5,
                              (minIntersection.point.y - 1.25) * 4 + 0.5, 0,
                              attenuation); // TODO: use baricentric uv
            }
            if (bounce == 0 && minIntersection.onFront) {
                // refract into inside
                attenuation *= 1 - fresnelSchlick(abs(dot(minIntersection.n, rayDirection)), F0);
                rayDirection = normalize(refract(rayDirection, minIntersection.n, eta));
                rayOrigin = minIntersection.point;
            } else if (bounce > 0 && !minIntersection.onFront) {
                // reflect in inside
                attenuation *= fresnelSchlick(abs(dot(minIntersection.n, rayDirection)), F0);
                rayDirection = normalize(reflect(rayDirection, -minIntersection.n));
                rayOrigin = minIntersection.point;
            }
        } else {
            // no collision in scene
            return float4(0, 0, 0, 0);
        }
    }
    // no collision in scene, due to insufficient bounce count
    return float4(0, 0, 0, 0);
}


[[kernel]]
void draw(texture2d<float, access::write> outTexture0 [[texture(0)]],
          texture2d<float, access::write> outTexture1 [[texture(1)]],
          const device Uniforms &uniforms [[buffer(0)]],
          const device Vertex *vertices [[buffer(1)]],
          const device uint32_t *indices [[buffer(2)]],
          const device int &indicesCount [[buffer(3)]],
          uint2 pixelCoord [[thread_position_in_grid]]) {
    auto size = uint2(outTexture0.get_width(), outTexture0.get_height());
    if (any(size != uint2(outTexture1.get_width(), outTexture1.get_height()))) { return; }
    if (any(pixelCoord >= size)) { return; }

    auto cameraTransform = uniforms.cameraTransform;
    auto cameraPosition = cameraTransform[3].xyz;
//    auto cameraRight = normalize(cameraTransform[0].xyz);
//    auto ipd = 0 * 0.064; // TODO: remove hard code
//    float3 cameraPositions[2] = {
//        cameraPosition + cameraRight * ipd / 2,
//        cameraPosition - cameraRight * ipd / 2
//    };
    float4x4 projectionInverses[2] = {
        uniforms.projection0Inverse,
        uniforms.projection1Inverse
    };

    auto uv = (float2(pixelCoord) + 0.5) / float2(size);
    // screen space [-1, +1]
    auto ndc = uv * 2 - 1;
    ndc.y *= -1;
    // normalized device coordinate, homogeneous 2->4
    auto ndc4 = float4(ndc.x, ndc.y, 1, 1);
    // view space
    float4 pixelCoordInViews[] = {
        projectionInverses[0] * ndc4,
        projectionInverses[1] * ndc4,
    };
    texture2d<float, access::write> outTextures[] = {outTexture0, outTexture1};

    for (int vid = 0; vid < 2; ++vid) {
        auto pixelCoordInView = pixelCoordInViews[vid];
        auto outTexture = outTextures[vid];
        auto viewDirectionInView = normalize(pixelCoordInView.xyz / pixelCoordInView.w);
        // world space
//        auto cameraPosition = cameraPositions[vid];
        auto viewDirection = (cameraTransform * float4(viewDirectionInView, 0)).xyz;

//        outTexture.write(colorHit(cameraPosition, viewDirection, vertices, indices, indicesCount), pixelCoord);
        outTexture.write(uvRefractionAndReflection(cameraPosition, viewDirection, vertices, indices, indicesCount), pixelCoord);
    }
}
