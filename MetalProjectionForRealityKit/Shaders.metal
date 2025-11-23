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
    float eta = 1;// 1 / 1.49;
    float F0 = 0.04;
    float attenuation = 1;
    // search sink surface.
    // assuming cube-ish shape.
    // bounce on front -> bounce on back * 0-2 times -> bounce on sink surface
    for (int bounce = 0; bounce < 2; ++bounce) {
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
                              1); //attenuation); // TODO: use baricentric uv
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

static float4x4 inverse4x4(float4x4 m) {
    float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2], a03 = m[0][3];
    float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2], a13 = m[1][3];
    float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2], a23 = m[2][3];
    float a30 = m[3][0], a31 = m[3][1], a32 = m[3][2], a33 = m[3][3];

    // 2x2 の小行列式をまとめて計算
    float b00 = a00*a11 - a01*a10;
    float b01 = a00*a12 - a02*a10;
    float b02 = a00*a13 - a03*a10;
    float b03 = a01*a12 - a02*a11;
    float b04 = a01*a13 - a03*a11;
    float b05 = a02*a13 - a03*a12;
    float b06 = a20*a31 - a21*a30;
    float b07 = a20*a32 - a22*a30;
    float b08 = a20*a33 - a23*a30;
    float b09 = a21*a32 - a22*a31;
    float b10 = a21*a33 - a23*a31;
    float b11 = a22*a33 - a23*a32;

    // 行列式
    float det = b00*b11 - b01*b10 + b02*b09 + b03*b08 - b04*b07 + b05*b06;

    // 逆行列の計算（余因子 / det）
    float4x4 inv;
    inv[0][0] = +( a11 * b11 - a12 * b10 + a13 * b09) / det;
    inv[0][1] = -( a01 * b11 - a02 * b10 + a03 * b09) / det;
    inv[0][2] = +( a31 * b05 - a32 * b04 + a33 * b03) / det;
    inv[0][3] = -( a21 * b05 - a22 * b04 + a23 * b03) / det;

    inv[1][0] = -( a10 * b11 - a12 * b08 + a13 * b07) / det;
    inv[1][1] = +( a00 * b11 - a02 * b08 + a03 * b07) / det;
    inv[1][2] = -( a30 * b05 - a32 * b02 + a33 * b01) / det;
    inv[1][3] = +( a20 * b05 - a22 * b02 + a23 * b01) / det;

    inv[2][0] = +( a10 * b10 - a11 * b08 + a13 * b06) / det;
    inv[2][1] = -( a00 * b10 - a01 * b08 + a03 * b06) / det;
    inv[2][2] = +( a30 * b04 - a31 * b02 + a33 * b00) / det;
    inv[2][3] = -( a20 * b04 - a21 * b02 + a23 * b00) / det;

    inv[3][0] = -( a10 * b09 - a11 * b07 + a12 * b06) / det;
    inv[3][1] = +( a00 * b09 - a01 * b07 + a02 * b06) / det;
    inv[3][2] = -( a30 * b03 - a31 * b01 + a32 * b00) / det;
    inv[3][3] = +( a20 * b03 - a21 * b01 + a22 * b00) / det;

    return inv;
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
    auto cameraCenterPosition = cameraTransform[3].xyz;
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

    float4 ndcCenter = float4(0, 0, -1, 1);
    float4 viewOrigins[2] = {
        projectionInverses[0] * ndcCenter,
        projectionInverses[1] * ndcCenter
    };
    viewOrigins[0] /= viewOrigins[0].w;
    viewOrigins[1] /= viewOrigins[1].w;

    float4x4 projections[2] = { uniforms.projection0, uniforms.projection1 };

    float4x4 cameraTransforms[2] = {
        uniforms.cameraTransformL,
        uniforms.cameraTransformR,
    };
    float3 cameraPositions[2] = {
        cameraTransforms[0][3].xyz,
        cameraTransforms[1][3].xyz
    };
    

    for (int vid = 0; vid < 2; ++vid) {
        auto pixelCoordInView = pixelCoordInViews[vid];
        auto outTexture = outTextures[vid];
        auto viewDirectionInView = normalize(pixelCoordInView.xyz / pixelCoordInView.w);
        // world space
//        auto cameraPosition = cameraPositions[vid];
//        auto cameraTransform = cameraTransforms[vid];
        auto viewDirection = (cameraTransforms[vid] * float4(viewDirectionInView, 0)).xyz;
//        auto viewDirection = normalize(cameraTransform[0].xyz * viewDirectionInView.x +
//                                       cameraTransform[1].xyz * viewDirectionInView.y +
//                                       cameraTransform[2].xyz * viewDirectionInView.z);
        auto worldOrigin = (cameraTransforms[vid] * viewOrigins[vid]).xyz;

//        outTexture.write(colorHit(cameraPosition, viewDirection, vertices, indices, indicesCount), pixelCoord);
        auto outProjection = projections[vid] * inverse4x4(cameraTransforms[vid]) * float4(cameraPositions[vid] + viewDirection, 1);
        auto outNDC = outProjection.xy / outProjection.w;
        outNDC.y *= -1;
        auto outUV = (outNDC.xy + 1) / 2;
        auto outPixelCoord = uint2(outUV * float2(size) + 0.5);
        outTexture.write(uvRefractionAndReflection(cameraPositions[vid], viewDirection, vertices, indices, indicesCount), outPixelCoord);
    }
}
