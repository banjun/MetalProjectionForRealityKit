#include "Shaders.h"
#include "Shaders-GBuffer.h"

[[vertex]]
VertexOut gbuffer_vertex(VertexIn in [[stage_in]],
                         const device VertexUniforms *uniforms [[buffer(1)]],
                         const uint vid [[instance_id]]) {
    auto uniform = uniforms[vid];
    auto pModel4 = float4(in.position, 1); // assuming in.position is in model pos
    auto pWorld4 = uniform.worldFromModelTransform * pModel4;
    auto pView4 = uniform.cameraFromWorldTransform * pWorld4;
    auto pClip4 = uniform.projectionFromCameraTransform * pView4;

    // TODO: non-uniform-scale, inverse-transpose
    auto normalMatrix = float3x3(uniform.cameraFromModelTransform[0].xyz,
                                 uniform.cameraFromModelTransform[1].xyz,
                                 uniform.cameraFromModelTransform[2].xyz);

    return VertexOut {
        .position = pClip4,
        .uv = float2(in.uv.x, 1 - in.uv.y),
        .normal = half3(normalize(normalMatrix * in.normal)),
        .tangent = half3(normalize(normalMatrix * in.tangent)),
        .bitangent = half3(normalize(normalMatrix * in.bitangent)),
        .viewPos = half4(pView4),
        .vid = vid,
    };
}

[[fragment]]
FragmentOut gbuffer_fragment(VertexOut in [[stage_in]],
                             constant FragmentUniforms &uniforms [[buffer(0)]]) {
    FragmentOut out;
    auto uv = in.uv;
//    auto s = linearSampler;
    constexpr auto s = sampler(filter::linear,
                               mip_filter::linear,
                               max_anisotropy(4), // anisotropy and lod_bias could improve in removing patchwork artifacts for photogrametry models
                               address::clamp_to_edge);

    if (uniforms.flags & HasBaseColorTexture) {
        out.color = uniforms.baseColorTexture.sample(s, uv, bias(-0.5));
    } else {
        out.color = half4(uniforms.baseColor, 1);
    }

    if (uniforms.flags & HasEmissiveColorTexture) {
        out.emissive = uniforms.emissiveColorTexture.sample(s, uv);
    } else {
        out.emissive = half4(uniforms.emissiveColor, 1);
    }

    if (uniforms.flags & HasNormalTexture) {
        // read normal in tangent space and convert using TBN
        auto N = normalize(in.normal);
        auto T = normalize(in.tangent);
        auto B = normalize(in.bitangent);
        auto TBN = half3x3(T, B, N);
        auto normal = normalize(uniforms.normalTexture.sample(s, uv, bias(-0.5)).xyz * 2.0h - 1.0h);
        out.normal = (TBN * normal).xy;
    } else {
        out.normal = in.normal.xy;
    }

    out.orm = uniforms.ormTexture.sample(s, uv);
    if (uniforms.flags & HasAOTexture) {} else {
        out.orm.x = uniforms.orm.x;
    }
    if (uniforms.flags & HasRoughnessTexture) {} else {
        out.orm.y = uniforms.orm.y;
    }
    if (uniforms.flags & HasMetalicTexture) {} else {
        out.orm.z = uniforms.orm.z;
    }

    out.viewPos = in.viewPos;
    return out;
}
