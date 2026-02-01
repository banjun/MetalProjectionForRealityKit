#include "Shaders.h"

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
                                        constant VertexUniforms *uniforms [[buffer(1)]],
                                        constant VolumeSpotLight *lights [[buffer(2)]],
                                        constant int &lightCount [[buffer(3)]],
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
half4 volume_light_fragment(VolumeLightFragment in [[stage_in]],
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

    return half4(half3(in.color.xyz * in.color.w * max(0.0, attenuation)), 1);
}

[[fragment]]
half4 surface_light_fragment(FullscreenIn in [[stage_in]],
                             texture2d_array<half> gAlbedoTex [[texture(0)]],
                             texture2d_array<half> gViewPosTex [[texture(1)]],
                             texture2d_array<half> gNormalTex [[texture(2)]],
                             texturecube<half> iblTex [[texture(3)]],
                             constant SurfaceLightUniforms *uniforms [[buffer(0)]],
                             constant VolumeSpotLight *lights [[buffer(1)]]) {
    auto vid = in.vid;
    // G-Buffer read
    auto posInView = float3(gViewPosTex.sample(linearSampler, in.uv, vid).xyz);
    if (any(isnan(posInView))) {return half4(0);}
    auto nView = half3(gNormalTex.sample(linearSampler, in.uv, vid).rg, 0);
    if (all(nView.xy == 0)) {return half4(0);}
    // normal decode
    auto nViewZZ = max(half(0), 1 - nView.r * nView.r - nView.g * nView.g);
    nView.z = sqrt(nViewZZ); // restore z from rg16Snorm

    auto albedo = gAlbedoTex.sample(linearSampler, in.uv, vid).xyz;
    auto nWorld = normalize(uniforms[vid].worldFromCameraTransform * float4(float3(nView), 0)).xyz; // incorrect for normal transform?
    auto iblMipLevels = half(iblTex.get_num_mip_levels() - 1);
    half roughness = 0.0;
    float specLOD = roughness * iblMipLevels;
    float3 vdWorld = normalize((uniforms[vid].worldFromCameraTransform * float4(normalize(posInView), 0)).xyz);
    float3 rWorld = reflect(-vdWorld, nWorld);
    half3 specColor = iblTex.sample(linearSampler, rWorld, level(specLOD)).rgb;
    float diffuseLOD = iblMipLevels;
    half3 diffColor = iblTex.sample(linearSampler, float3(nWorld), level(diffuseLOD)).rgb;

    float reflectance = 0.5;
    half3 outRGB = diffColor * albedo + specColor * reflectance;
    // NOTE: loop is faster than instancing for this shader. KPI is overdraw & texture cache miss
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
    return half4(outRGB, 1);
}
