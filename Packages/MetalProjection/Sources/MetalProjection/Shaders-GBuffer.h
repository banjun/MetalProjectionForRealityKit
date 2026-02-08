#include <metal_stdlib>
#import "Shaders.h"

struct VertexIn {
    float3 position [[attribute(0)]];
    simd_float2 uv [[attribute(1)]];
    simd_float3 normal [[attribute(2)]];
    simd_float3 tangent [[attribute(3)]];
    simd_float3 bitangent [[attribute(4)]];
};
struct VertexOut {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
    float2 uv;
    half3 normal;
    half3 tangent;
    half3 bitangent;
    half4 viewPos;
};
struct FragmentOut {
    half4 color [[color(0)]]; // array, indexed by [[render_target_array_index]]
    half2 normal [[color(1)]];
    half4 viewPos [[color(2)]];
    half4 emissive [[color(3)]];
    half4 orm [[color(4)]]; // AO, Roughness, Metalic, _
};
