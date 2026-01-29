#include <metal_stdlib>
#include "../MetalProjectionBridgingHeader/include/Shaders.h"
using namespace metal;

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
    half2 normal;
    half4 viewPos;
};
struct FragmentOut {
    half4 color [[color(0)]]; // array, indexed by [[render_target_array_index]]
    half2 normal [[color(1)]];
    half4 viewPos [[color(2)]];
    half4 emissive [[color(3)]];
};

constexpr auto linearSampler = sampler(filter::linear,
                                       mip_filter::linear,
                                       address::clamp_to_edge);
constexpr auto nearestSampler = sampler(filter::nearest,
                                        mip_filter::nearest,
                                        address::clamp_to_edge);

[[vertex]]
VertexOut render_vertex(VertexIn in [[stage_in]],
                        const device VertexUniforms *uniforms [[buffer(1)]],
                        const uint vid [[instance_id]]) {
    auto uniform = uniforms[vid];
    auto pModel4 = float4(in.position, 1); // assuming in.position is in model pos
    auto pWorld4 = uniform.worldFromModelTransform * pModel4;
    auto pView4 = uniform.cameraFromWorldTransform * pWorld4;
    auto pClip4 = uniform.projectionFromCameraTransform * pView4;

    return VertexOut {
        .position = pClip4,
        .uv = in.uv,
        .normal = half2(normalize((uniform.cameraFromModelTransform * float4(in.normal, 0)).xyz).xy), // TODO: use NormalMatrix as normal is inverse-transpos
        .viewPos = half4(pView4),
        .vid = vid,
        //    out.v.position = in.position;
        //    out.v.uv = in.uv;
        //    out.v.normal = in.normal;
        //    out.v.tangent = in.tangent;
        //    out.v.bitangent = in.bitangent;
    };
}

[[fragment]]
FragmentOut render_fragment(VertexOut in [[stage_in]],
                            constant FragmentUniforms &uniforms [[buffer(0)]]) {
    FragmentOut out;
    auto uv = in.uv;
    uv.y = 1 - uv.y;

    if (uniforms.flags & HasBaseColorTexture) {
        out.color = uniforms.baseColorTexture.sample(linearSampler, uv);
    } else {
        out.color = half4(uniforms.baseColor, 1);
    }

    if (uniforms.flags & HasEmissiveColorTexture) {
        out.emissive = uniforms.emissiveColorTexture.sample(linearSampler, uv);
    } else {
        out.emissive = half4(uniforms.emissiveColor, 1);
    }

    // TODO
    out.normal = in.normal;
    out.viewPos = in.viewPos;
    return out;
}

struct FullscreenIn {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
    uint iid;
    float2 uv;
};

[[vertex]]
FullscreenIn fullscreen_vertex(const uint vertex_id [[vertex_id]],
                               const uint instance_id [[instance_id]],
                               const device uint &viewCount [[buffer(1)]]) {
    float2 pos[3] = {
        float2(-1, -1),
        float2( 3, -1),
        float2(-1,  3),
    };
    float2 uv[3] = {
        float2(0, 1 - 0),
        float2(2, 1 - 0),
        float2(0, 1 - 2),
    };
    FullscreenIn o;
    o.position = float4(pos[vertex_id], 0, 1);
    o.uv = uv[vertex_id];
    o.vid = instance_id % viewCount;
    o.iid = instance_id;
    return o;
}

[[fragment]]
float4 bright_fragment(FullscreenIn in [[stage_in]],
                       texture2d_array<float> scene [[texture(0)]]) {
    auto threshold = 0.1;
    auto boost = 4.0;
    auto c = scene.sample(linearSampler, in.uv, in.vid).rgb;
    auto luminance = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float4(luminance > threshold ? c * boost : 0.0, 1.0);
}

[[fragment]]
float4 bloom_fragment(FullscreenIn in [[stage_in]],
                      texture2d_array<float> bright [[texture(0)]],
                      const device float2 &kawase_offset [[buffer(0)]]) {
    float2 o = kawase_offset;
    float2 offsets[8] = {
        float2( o.x,  0.0),
        float2(-o.x,  0.0),
        float2( 0.0,  o.y),
        float2( 0.0, -o.y),
        float2( o.x,  o.y),
        float2(-o.x,  o.y),
        float2( o.x, -o.y),
        float2(-o.x, -o.y),
    };
    // kawase blur with pow
    float p = 1.05;
    float3 c = 0.0;
    for (int i = 0; i < 8; ++i) {
        c += pow(bright.sample(linearSampler, in.uv + offsets[i], in.iid).rgb, p);
    }
    // add center focus
    auto centerColor = bright.sample(linearSampler, in.uv, in.iid).rgb;
    c += pow(centerColor * 0.1, p);
    // restore pow value
    c *= pow(1.0 / (8.0 + 1.5), 1 / p);
    return float4(c, 1);
}

[[fragment]]
float4 copy(FullscreenIn in [[stage_in]],
            texture2d_array<float> tex [[texture(0)]]) {
    return tex.sample(nearestSampler, in.uv, in.vid);
}
[[fragment]]
float4 copyDepthToColor(FullscreenIn in [[stage_in]],
                        depth2d_array<float> depth [[texture(0)]]) {
    auto d = depth.sample(nearestSampler, in.uv, in.vid);
    return float4(float3(d), 1);
}

[[fragment]]
float4 composite_fragment(FullscreenIn in [[stage_in]],
                          texture2d_array<float> scene [[texture(0)]],
                          texture2d_array<float> bloom [[texture(1)]],
                          texture2d_array<float> volumeLight [[texture(2)]],
                          texture2d_array<float> surfaceLight [[texture(3)]],
                          const device float *texIntensities [[buffer(0)]]) {
    texture2d_array<float> textures[] = {scene, bloom, volumeLight, surfaceLight};
    auto out = float4(0);
    for(int i = 0; i < 4; ++ i) {
        auto v = textures[i].sample(linearSampler, in.uv, in.vid);
        out += v * texIntensities[i];
    }
    return out;
    auto s = scene.sample(linearSampler, in.uv, in.vid);
    auto b = bloom.sample(linearSampler, in.uv, in.vid);
    auto vl = volumeLight.sample(linearSampler, in.uv, in.vid);
    auto sl = surfaceLight.sample(linearSampler, in.uv, in.vid);
    auto bloomIntensity = 0.25;
    auto volumeLightIntensity = 1.0;
    auto surfaceLightIntensity = 1.0;
    return float4(float4(sl.rgb * surfaceLightIntensity, s.a) + b * bloomIntensity + vl * volumeLightIntensity);
}


struct VolumeLightVertex {
    simd_float3 position [[attribute(0)]];
};
struct VolumeLightFragment {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
    float4 color;
    float3 posInWorld;
    float3 lightPosInWorld;
    float3 lightDirInWorld;
    float lightAngleCos;
    float3 posInModel; // model = light
    float3 cameraInModel;
    float3 cameraInWorld;
};

[[vertex]]
VolumeLightFragment volume_light_vertex(VolumeLightVertex in [[stage_in]],
                                        const device VertexUniforms *uniforms [[buffer(1)]],
                                        const device VolumeSpotLight *lights [[buffer(2)]],
                                        const device int &lightCount [[buffer(3)]],
                                        const uint iid [[instance_id]]) {
    auto viewCount = uniforms[0].viewCount; // use 0 as same acroll all index
    auto vid = iid % viewCount;
    auto lid = iid / viewCount;
    auto light = lights[lid];

    auto uniform = uniforms[vid];
    auto pModel4 = float4(in.position, 1);
    auto pWorld4 = light.worldFromModelTransform * pModel4;
    auto pView4 = uniform.cameraFromWorldTransform * pWorld4;
    auto pClip4 = uniform.projectionFromCameraTransform * pView4;

    auto lightPosInWorld4 = light.worldFromModelTransform * float4(0, 0, 0, 1);
    auto cameraInWorld4 = uniform.worldFromCameraTransform * float4(0, 0, 0, 1);
    auto cameraInModel4 = light.modelFromWorldTransform * cameraInWorld4;
    VolumeLightFragment out;
    out.position = pClip4;
    out.vid = vid;
    out.color = float4(light.color, light.intensity);
    out.posInWorld = pWorld4.xyz;
    out.lightPosInWorld = lightPosInWorld4.xyz;
    out.lightDirInWorld = light.direction;
    out.lightAngleCos = light.angleCos;
    out.posInModel = in.position;
    out.cameraInWorld = cameraInWorld4.xyz;
    out.cameraInModel = cameraInModel4.xyz;
    return out;
}

[[fragment]]
FragmentOut volume_light_fragment(VolumeLightFragment in [[stage_in]],
                                  bool front_facing [[front_facing]]) {
    // auto lightDirInModel = float3(0, -1, 0);
    // auto cameraToLightCos = dot(lightDirInModel, normalize(in.cameraInModel));
    auto cameraToPos = in.posInModel - in.cameraInModel;
    auto cameraToPosWorld = in.posInWorld - in.cameraInWorld;
    auto viewDirection = normalize(float3(cameraToPos.x, 0, cameraToPos.z));
    auto lightToFragment = in.posInWorld - in.lightPosInWorld;
    auto lightToFragmentDistance = length(lightToFragment);
    auto distanceAttenuation = (exp(-1 * lightToFragmentDistance) + 0.1 * exp(-0.1 * lightToFragmentDistance)) / 1.1;
    // auto spotCos = dot(in.lightDirInWorld, normalize(lightToFragment));
    auto n = normalize(float3(in.posInModel.x, 0, in.posInModel.z));
    auto nWorld = normalize(in.posInWorld);
    auto viewCos = dot(n, -viewDirection);
    // auto discEmission = 1 + 3 * exp(-100000 * pow(-in.posInModel.y - 0.03, 2));
    // auto rootDiscBoost = front_facing ? (-in.posInModel.y < 0.1 ? 0 : 1) : (1 + smoothstep(-0.03, -0.025, in.posInModel.y));
    //    auto viewCos = dot(n, -viewDirection);
    auto vv = dot(float3(in.posInModel.x, 0, in.posInModel.z), normalize(-float3(cameraToPos.x, 0, (front_facing ? 1 : 1) * cameraToPos.z)));

    auto cameraPitch = smoothstep(0, 1.1, abs(dot(float3(0, -1, 0), normalize(in.cameraInModel))));
    auto posLength = smoothstep(0.4, 0.9, exp(-40 * length(in.posInModel.xz)));

    // NOTE: As cameraInModel might be incorrectly normalized, we can just compare xz & y
    auto cameraInModelXZLength = length(in.cameraInModel.xz);
    auto innerCone = smoothstep(-0.01, 0.01, -in.cameraInModel.y - cameraInModelXZLength);
    auto rootCut = smoothstep(0, 0.001, -in.posInModel.y - 0.003);
    auto viewCut = smoothstep(0.4, 0.9, /*max(0.0, 0 * cameraPitch * posLength) +*/ max(0.0, vv));

    auto posInModelXZ = float3(in.posInModel.x, 0, in.posInModel.z);
    auto cameraInModelXZ = float3(in.cameraInModel.x, 0, in.cameraInModel.z);
    auto viewAngleAttenuation = smoothstep(0.4, 0.7, pow(max(0.0, dot(-normalize(posInModelXZ), normalize(posInModelXZ - cameraInModelXZ))), 2));

    auto attenuation = 1
    * smoothstep(0.01, 0.7, distanceAttenuation)
    * max(innerCone, 1
          * rootCut
          * (max(0.0, cameraPitch * posLength) + viewAngleAttenuation)
          )
    ;

//    return FragmentOut {.color = float4(float3(viewAngleAttenuation), 1)};

    return FragmentOut {
        .color = half4(half3(in.color.xyz * in.color.w * max(0.0, attenuation)), 1),
    };
}

[[fragment]]
FragmentOut surface_light_fragment(FullscreenIn in [[stage_in]],
                                   texture2d_array<half> gViewPosTex [[texture(0)]],
                                   texture2d_array<half> gNormalTex [[texture(1)]],
                                   const device SurfaceLightUniforms *uniforms [[buffer(0)]],
                                   const device VolumeSpotLight *lights [[buffer(1)]]) {
    auto vid = in.vid;
    // G-Buffer read
    auto posInView = float3(gViewPosTex.sample(linearSampler, in.uv, vid).xyz);
    if (any(isnan(posInView))) {return FragmentOut();}
    auto nView = half3(gNormalTex.sample(linearSampler, in.uv, vid).rg, 0);
    if (all(nView.xy == 0)) {return FragmentOut();}
    // normal decode
    auto nViewZZ = max(half(0), 1 - nView.r * nView.r - nView.g * nView.g);
    nView.z = sqrt(nViewZZ); // restore z from rg16Snorm

    // NOTE: loop is faster than instancing for this shader. KPI is overdraw & texture cache miss
    half3 outRGB = 0;
    for (int lid = 0; lid < uniforms[vid].lightCount; ++lid) {
        // Light vectors
        auto light = lights[lid];
        auto L = light.positionInView[vid] - posInView;
        auto dist2 = dot(L, L);
        auto invDist = rsqrt(dist2);
        auto Ldir = L * invDist;

        // Spot cut
        auto spotCos = dot(-light.directionInView[vid], Ldir);
        if (spotCos < light.angleCos) { continue; }
        // Lambert cut
        auto NdotL = dot(float3(nView), Ldir);
        if (NdotL <= 0) { continue; }

        // Attenuations
        auto distanceAtt = exp(-0.5 * sqrt(dist2)); // 1.0 / (1.0 + dist2);
        auto spotAtt = smoothstep(light.angleCos, light.angleCos + 0.05, spotCos);

        float3 radiance = light.color * (light.intensity)
        * NdotL
        * distanceAtt
        * spotAtt
        * spotCos
        ;
        outRGB += half3(radiance);
    }
    return FragmentOut {
        .color = half4(outRGB, 1),
    };
}
