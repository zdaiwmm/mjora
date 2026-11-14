#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// gallery's spatial_scene.frag. each pixel marches from the nearest depth back
// and takes the first surface its ray meets, so the subject covers the
// background as the view moves.
[[ stitchable ]] half4 spatialScene(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float2 offset,
    float focus,
    float zoom,
    texture2d<half> depth
) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    const int steps = 40;
    float step = 1.0 / float(steps);
    float2 base = (position / size - 0.5) / zoom + 0.5;
    float2 previous = base - offset * (1.0 - focus);
    float previousGap = float(depth.sample(linear, clamp(previous, 0.0, 1.0)).r) - 1.0;
    float2 uv = previous;
    for (int i = 1; i <= steps; i++) {
        float z = 1.0 - float(i) * step;
        uv = base - offset * (z - focus);
        float gap = float(depth.sample(linear, clamp(uv, 0.0, 1.0)).r) - z;
        if (gap >= 0.0) {
            uv = mix(previous, uv, previousGap / (previousGap - gap));
            break;
        }
        previous = uv;
        previousGap = gap;
    }
    return layer.sample(clamp(uv * size, float2(0.5), size - 0.5));
}
