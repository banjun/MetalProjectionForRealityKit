#import <simd/simd.h>

struct Uniforms {
    simd_float4x4 cameraTransform;
    simd_float4x4 projection0;
    simd_float4x4 projection1;
};
