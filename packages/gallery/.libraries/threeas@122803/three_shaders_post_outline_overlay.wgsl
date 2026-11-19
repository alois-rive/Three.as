// OutlinePass's overlay (three.js OutlinePass.js getOverlayMaterial): the
// edges (plus glow, plus the pattern texture inside the selection), added
// onto the read buffer. Post shader (see copy.wgsl). three.js blends it with
// non-premultiplied AdditiveBlending (src alpha, one): the output is
// multiplied by its alpha here, for the renderer's (one, one).

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

struct QuadOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(2) uv: vec2<f32>) -> QuadOut {
    var out: QuadOut;
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    out.clip = vec4<f32>(position.xy, 0.5 + keep, 1.0);
    out.uv = vec2<f32>(uv.x, 1.0 - uv.y);
    return out;
}

// Uniforms in insertion order: edgeStrength, edgeGlow, usePatternTexture
// (then maskTexture, edgeTexture1, edgeTexture2, patternTexture).
struct Uniforms {
    edgeStrength: f32,
    edgeGlow: f32,
    usePatternTexture: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var maskTexture: texture_2d<f32>;
@group(2) @binding(2) var edgeTexture1: texture_2d<f32>;
@group(2) @binding(3) var edgeTexture2: texture_2d<f32>;
@group(2) @binding(4) var patternTexture: texture_2d<f32>;
@group(2) @binding(5) var s_tex: sampler;

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let edge_value1 = textureSample(edgeTexture1, s_tex, in.uv);
    let edge_value2 = textureSample(edgeTexture2, s_tex, in.uv);
    let mask_color = textureSample(maskTexture, s_tex, in.uv);
    // The pattern repeats six times (three.js samples it with its own
    // repeat wrapping; the shared sampler clamps, so the uv wraps here).
    let pattern_color = textureSample(patternTexture, s_tex, fract(6.0 * vec2<f32>(in.uv.x, 1.0 - in.uv.y)));
    let visibility_factor = select(0.5, 1.0, 1.0 - mask_color.g > 0.0);
    let edge_value = edge_value1 + edge_value2 * u.edgeGlow;
    var final_color = u.edgeStrength * mask_color.r * edge_value;
    if (u.usePatternTexture > 0.5) {
        final_color += visibility_factor * (1.0 - mask_color.r) * (1.0 - pattern_color.r);
    }
    return vec4<f32>(final_color.rgb * final_color.a, final_color.a * final_color.a);
}
