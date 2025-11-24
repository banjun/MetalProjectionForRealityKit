#import <simd/simd.h>

struct Uniforms {
    simd_float4x4 cameraTransform;
    simd_float4x4 cameraTransformL;
    simd_float4x4 cameraTransformR;
    simd_float4x4 projection0;
    simd_float4x4 projection1;
    simd_float4x4 projection0Inverse;
    simd_float4x4 projection1Inverse;
};

struct Vertex {
    simd_float3 position;
    uint32_t mask;
};
