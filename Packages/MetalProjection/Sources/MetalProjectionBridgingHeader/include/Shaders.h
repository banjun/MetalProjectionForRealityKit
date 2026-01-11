#import <simd/simd.h>

/// MetalMap->Texture(blit)->RealityKit shader
struct Uniforms {
    simd_float4x4 cameraTransformL;
    simd_float4x4 cameraTransformR;
    simd_float4x4 projection0;
    simd_float4x4 projection1;
    simd_float4x4 projection0Inverse;
    simd_float4x4 projection1Inverse;
};
/// MetalMap->(vertex buffer)->vertex shader, as array, indexed by instance id for left/right eye
struct VertexUniforms {
    int viewCount; // same value across uniforms[i], so that uniforms[0].viewCount should be used
    simd_float4x4 worldFromModelTransform;
    simd_float4x4 worldFromCameraTransform;
    simd_float4x4 cameraFromWorldTransform;
    simd_float4x4 cameraFromModelTransform;
    simd_float4x4 projectionFromCameraTransform;
    simd_float4x4 cameraFromProjectionTransform;
};
/// MetalMap->(fragment buffer)->fragment shader
struct FragmentUniforms {
    simd_int2 textureSize;
};

struct Vertex {
    simd_float3 position;
    simd_float2 uv; // optional?
    simd_float3 normal; // optional?
    simd_float3 tangent; // optional?
    simd_float3 bitangent; // optional?
};

struct VolumeSpotLight {
    simd_float4x4 worldFromModelTransform;
    simd_float4x4 modelFromWorldTransform;
    simd_float3 position;
    simd_float3 positionInView[2];
    simd_float3 direction;
    simd_float3 directionInView[2];
    float angleCos;
    simd_float3 color;
    float intensity;
    // TODO: use DMX texture
};

struct SurfaceLightUniforms {
    int viewCount; // same value across uniforms[i], so that uniforms[0].viewCount should be used
    simd_float4x4 cameraFromProjectionTransform;
    simd_float4x4 worldFromCameraTransform;
    simd_float4x4 cameraFromWorldTransform;
};
