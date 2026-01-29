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
#ifdef __METAL_VERSION__
#define NS_OPTIONS(_type, _name) enum _name : _type
#define ArgID(arg_id) [[id(arg_id)]]
#define Texture2DHalf(name) metal::texture2d<half> name
#else
#import <Foundation/Foundation.h>
#define ArgID(arg_id)
#define Texture2DHalf(name) int name
#endif
NS_OPTIONS(uint32_t, FragmentArgumentFlags) {
    HasBaseColorTexture = 1 << 0,
    HasEmissiveColorTexture = 1 << 1,
    EmitsLight = 1 << 2,
    ReceivesLight = 1 << 3,
};
/// MetalMap->(fragment buffer)->fragment shader
struct FragmentUniforms {
    enum FragmentArgumentFlags flags    ArgID(0);
    simd_half3 baseColor                ArgID(1);
    Texture2DHalf(baseColorTexture)     ArgID(2);
    simd_half3 emissiveColor            ArgID(3);
    Texture2DHalf(emissiveColorTexture) ArgID(4);
};

struct Vertex {
    simd_float3 position;
    simd_float2 uv; // optional?
    simd_float3 normal; // optional?
    simd_float3 tangent; // optional?
    simd_float3 bitangent; // optional?
};
struct Material {
    simd_float3 baseColor;
    simd_float3 emissiveColor;
    float emissiveIntensity;
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
    int lightCount;
    simd_float4x4 cameraFromProjectionTransform;
    simd_float4x4 worldFromCameraTransform;
    simd_float4x4 cameraFromWorldTransform;
};
