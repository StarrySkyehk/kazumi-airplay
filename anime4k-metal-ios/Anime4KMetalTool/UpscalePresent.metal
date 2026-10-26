// Copyright 2024 — helper for offline Anime4K transcoding.
//
// Uses the Anime4K Metal engine (Apache-2.0, https://github.com/imxieyi/Anime4KMetal,
// itself a port of https://github.com/bloc97/Anime4K) to run the real Anime4K GLSL
// shader chains on device GPU, then encodes the result with AVAssetWriter.
//

#include <metal_stdlib>
using namespace metal;

struct PresentVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle; uv v=0 maps to the top row of the source texture.
vertex PresentVertexOut presentVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -3.0),
        float2(-1.0,  1.0),
        float2( 3.0,  1.0)
    };
    float2 position = positions[vertexID];
    PresentVertexOut out;
    out.position = float4(position, 0.0, 1.0);
    out.uv = float2((position.x + 1.0) * 0.5, (1.0 - position.y) * 0.5);
    return out;
}

// The Anime4K chain already produced a texture at the target resolution; this pass
// only converts it (float16 RGBA) into the BGRA8 render target of the encoder.
fragment float4 presentFragment(PresentVertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                sampler linearSampler [[sampler(0)]]) {
    float4 color = source.sample(linearSampler, in.uv);
    return float4(color.rgb, 1.0);
}
