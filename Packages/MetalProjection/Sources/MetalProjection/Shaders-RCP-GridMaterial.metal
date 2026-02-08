// MARK: - wrapper
#include "Shaders-GBuffer.h"

// MARK: - GridMaterial.usda -> ChatGPT -> manual edit -> this file
// #include <metal_stdlib>
using namespace metal;

[[fragment]]
FragmentOut gbuffer_RCP_GridMaterial(VertexOut in [[stage_in]]) {
    // shadergraph params
    auto lineCounts = float2(24.0, 12.0);
    auto lineWidth = float2(0.1, 0.1);
    auto backgroundColor = half3(0.89737);
    auto lineColor = half3(0.55946);

    // PBR params
    auto emissive = half3(0);
    auto ao = 1.0h;
    auto roughness = 0.5h;
    auto metalic = 0.15h;

    // logic
    auto gridUV = in.uv * lineCounts;
    auto cell = fract(gridUV);
    auto d = min(cell, 1.0 - cell);
    auto line = max(step(d.x, lineWidth.x),
                     step(d.y, lineWidth.y));
    auto color = mix(backgroundColor, lineColor, line);

    return FragmentOut {
        .color = half4(color, 1.0),
        .normal = in.normal.xy,
        .viewPos = in.viewPos,
        .emissive = half4(emissive, 1),
        .orm = half4(ao, roughness, metalic, 0),
    };
}
