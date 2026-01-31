#include <metal_stdlib>
#include "../MetalProjectionBridgingHeader/include/Shaders.h"
using namespace metal;

struct FullscreenIn {
    float4 position [[position]];
    uint vid [[render_target_array_index]];
    uint iid;
    float2 uv;
};

constexpr auto linearSampler = sampler(filter::linear,
                                       mip_filter::linear,
                                       address::clamp_to_edge);
constexpr auto nearestSampler = sampler(filter::nearest,
                                        mip_filter::nearest,
                                        address::clamp_to_edge);
