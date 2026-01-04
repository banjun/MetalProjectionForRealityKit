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
    float3 normal;
};
struct FragmentOut {
    float4 color [[color(0)]]; // array, indexed by [[render_target_array_index]]
    float4 normal [[color(1)]];
};

[[vertex]]
VertexOut render_vertex(VertexIn in [[stage_in]],
                        const device VertexUniforms *uniforms [[buffer(1)]],
                        const uint vid [[instance_id]]) {
    auto uniform = uniforms[vid];
    auto pModel4 = float4(in.position, 1); // assuming in.position is in model pos
    auto pWorld4 = uniform.worldFromModelTransform * pModel4;
    auto pView4 = uniform.cameraFromWorldTransform * pWorld4;
    auto pClip4 = uniform.projectionFromCameraTransform * pView4;

    VertexOut out;
    out.position = pClip4;
    out.uv = in.uv;
    out.normal = normalize((uniform.worldFromModelTransform * float4(in.normal, 0)).xyz); // TODO: use NormalMatrix as normal is inverse-transpose
    out.vid = vid;
    //    out.v.position = in.position;
    //    out.v.uv = in.uv;
    //    out.v.normal = in.normal;
    //    out.v.tangent = in.tangent;
    //    out.v.bitangent = in.bitangent;
    return out;
}

constexpr auto linearSampler = sampler(filter::linear,
                                       mip_filter::linear,
                                       address::clamp_to_edge);
constexpr auto nearestSampler = sampler(filter::nearest,
                                        mip_filter::nearest,
                                        address::clamp_to_edge);

[[fragment]]
FragmentOut render_fragment(VertexOut in [[stage_in]],
                            texture2d<float> baseColorTexture [[texture(0)]],
                            const device FragmentUniforms &uniforms [[buffer(2)]]) {
    // auto textureSize = uniforms.textureSize;
    auto uv = in.uv;
    auto baseColor = baseColorTexture.sample(linearSampler, float2(uv.x, 1 - uv.y));
    FragmentOut out;
    // TODO
    out.color = baseColor;
    out.normal = float4(in.normal, 1);
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
    auto c = float3(0.0);
    auto weight = 1.0 / 4.0;
    auto offset = kawase_offset;
    c += bright.sample(linearSampler, in.uv + float2(-offset.x, -offset.y), in.iid).rgb * weight;
    c += bright.sample(linearSampler, in.uv + float2(-offset.x, +offset.y), in.iid).rgb * weight;
    c += bright.sample(linearSampler, in.uv + float2(+offset.x, -offset.y), in.iid).rgb * weight;
    c += bright.sample(linearSampler, in.uv + float2(+offset.x, +offset.y), in.iid).rgb * weight;
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
float4 volumeLight_fragment(FullscreenIn in [[stage_in]],
                            depth2d_array<float> depth [[texture(0)]],
                            const device Uniforms &uniforms [[buffer(0)]],
                            const device VolumeSpotLight *lights [[buffer(1)]],
                            const device int &lightCount [[buffer(2)]]) {
    simd_float4x4 projections[] = {uniforms.projection0, uniforms.projection1};
    simd_float4x4 projectionInverses[] = {uniforms.projection0Inverse, uniforms.projection1Inverse};
    simd_float4x4 cameraTransforms[] = {uniforms.cameraTransformL, uniforms.cameraTransformR};
    auto projection = projections[in.vid];
    auto projectionInverse = projectionInverses[in.vid];
    auto cameraTransform = cameraTransforms[in.vid];

    auto ndc = in.uv * 2 - 1;
    auto ndc4 = float4(ndc.x, -ndc.y, 1, 1);
    auto pView4 = projectionInverse * ndc4;
    auto viewDirectionInView = pView4.xyz / pView4.w;
    auto viewDirectionInWorld = normalize((cameraTransform * float4(viewDirectionInView, 0)).xyz);

    auto t = 0.0;
    auto cameraPos = cameraTransform.columns[3].xyz;
    auto stepSize = 0.1;
    auto MAX_STEPS = 128.0;
    auto maxDistance = 5.0;
    auto color = float3(0);

    for (int i = 0; i < MAX_STEPS; i++) {
        auto pos = cameraPos + viewDirectionInWorld * maxDistance * i / MAX_STEPS;
        for (int l = 0; l < lightCount; l++) {
            auto light = lights[l];
            auto posFromLight = pos - light.position;
            auto angle = dot(normalize(posFromLight), light.direction);
            if (angle > light.angleCos) {
                auto distanceAttenuation = 1 / length_squared(posFromLight);
                color += light.color * light.intensity * distanceAttenuation / MAX_STEPS;
            }
        }
    }
    return float4(color, 1);
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
    auto surfaceLightIntensity = 2.0;
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
    auto cameraInModel4 = light.modelFromWorldTransform * uniform.worldFromCameraTransform * float4(0, 0, 0, 1);

    VolumeLightFragment out;
    out.position = pClip4;
    out.vid = vid;
    out.color = float4(light.color, light.intensity);
    out.posInWorld = pWorld4.xyz;
    out.lightPosInWorld = lightPosInWorld4.xyz;
    out.lightDirInWorld = light.direction;
    out.lightAngleCos = light.angleCos;
    out.posInModel = in.position;
    out.cameraInModel = cameraInModel4.xyz;
    return out;
}

[[fragment]]
FragmentOut volume_light_fragment(VolumeLightFragment in [[stage_in]]) {
    auto viewDirection = normalize(in.posInModel - in.cameraInModel);
    auto lightToFragment = in.posInWorld - in.lightPosInWorld;
    auto distanceAttenuation = 1.0 / (1.0 + length_squared(lightToFragment));
    auto spotCos = dot(in.lightDirInWorld, normalize(lightToFragment));
    auto n = normalize(float3(in.posInModel.x, 0, in.posInModel.z));
    auto viewCos = dot(n, -normalize(float3(viewDirection.x, 0, viewDirection.z)));
    auto attenuation = clamp(distanceAttenuation, 0.0, 0.8)
    * smoothstep(in.lightAngleCos, in.lightAngleCos + 0.05, spotCos)
    * smoothstep(0.5, 0.8, viewCos);

    FragmentOut out;
    out.color = float4(in.color.xyz * in.color.w * attenuation, 1);
    return out;
}

[[fragment]]
FragmentOut surface_light_fragment(FullscreenIn in [[stage_in]],
                                   depth2d_array<float> depthTex [[texture(0)]],
                                   texture2d_array<float> gNormalTex [[texture(1)]],
                                   const device SurfaceLightUniforms *uniforms [[buffer(0)]],
                                   const device VolumeSpotLight *lights [[buffer(1)]]) {
    // Instance ID decode
    auto viewCount = uniforms[0].viewCount;
    auto vid = in.vid;
    auto lid = in.iid / viewCount;
    // G-Buffer
    auto nWorld = gNormalTex.sample(linearSampler, in.uv, vid).rgb;
    auto depth = depthTex.sample(linearSampler, in.uv, vid);
    auto ndc = float4(in.uv * 2 - 1, depth, 1);
    auto posInView = uniforms[vid].projectionInverse * ndc;
    if (posInView.w < 1e-6) discard_fragment();
    posInView.xyz /= posInView.w;
    auto posInWorld = (uniforms[vid].worldFromCameraTransform * posInView).xyz;
    // Light vectors
    auto light = lights[lid];
    float3 L = light.position - posInWorld;
    float dist2 = dot(L, L);
    float dist = sqrt(dist2);
    float3 Ldir = L / dist;
    // Attenuations
    float distanceAtt = 1.0 / (1.0 + dist2);
    float spotCos = dot(normalize(-light.direction), Ldir);
    float spotAtt = smoothstep(light.angleCos, light.angleCos + 0.05, spotCos);
    // Lambert
    float NdotL = max(0.0, dot(nWorld, Ldir));

    float3 radiance = light.color * light.intensity
    * NdotL
    * distanceAtt
    * spotAtt
    ;
    FragmentOut out;
    out.color = float4(radiance, 1);
    return out;
}
