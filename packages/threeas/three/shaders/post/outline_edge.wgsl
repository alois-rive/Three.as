// OutlinePass's edge detection (three.js OutlinePass.js
// getEdgeDetectionMaterial): the mask's gradient, coloured visible or
// hidden. Post shader (see copy.wgsl).

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

// Uniforms in insertion order: texSize, visibleEdgeColor, hiddenEdgeColor
// (then maskTexture).
struct Uniforms {
    texSize: vec2<f32>,
    visibleEdgeColor: vec3<f32>,
    hiddenEdgeColor: vec3<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var maskTexture: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let inv_size = 1.0 / u.texSize;
    let uv_offset = vec4<f32>(1.0, 0.0, 0.0, 1.0) * vec4<f32>(inv_size, inv_size);
    // y offsets are in three.js's bottom-up uv: flipped for top-first rows.
    let c1 = textureSample(maskTexture, s_tex, in.uv + uv_offset.xy);
    let c2 = textureSample(maskTexture, s_tex, in.uv - uv_offset.xy);
    let c3 = textureSample(maskTexture, s_tex, in.uv - uv_offset.yw);
    let c4 = textureSample(maskTexture, s_tex, in.uv + uv_offset.yw);
    let diff1 = (c1.r - c2.r) * 0.5;
    let diff2 = (c3.r - c4.r) * 0.5;
    let d = length(vec2<f32>(diff1, diff2));
    let a1 = min(c1.g, c2.g);
    let a2 = min(c3.g, c4.g);
    let visibility_factor = min(a1, a2);
    let edge_color = select(u.hiddenEdgeColor, u.visibleEdgeColor, 1.0 - visibility_factor > 0.001);
    return vec4<f32>(edge_color, 1.0) * vec4<f32>(d);
}
