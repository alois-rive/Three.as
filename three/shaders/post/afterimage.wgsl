// three.js AfterimageShader (examples/jsm/shaders/AfterimageShader.js):
// the new frame over the previous result faded by `damp`. Post shader
// (see copy.wgsl).

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

// Uniforms in insertion order: damp (then tOld, tNew).
struct Uniforms {
    damp: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tOld: texture_2d<f32>;
@group(2) @binding(2) var tNew: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

fn when_gt(x: vec4<f32>, y: f32) -> vec4<f32> {
    return max(sign(x - vec4<f32>(y)), vec4<f32>(0.0));
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    var texel_old = textureSample(tOld, s_tex, in.uv);
    let texel_new = textureSample(tNew, s_tex, in.uv);
    texel_old *= u.damp * when_gt(texel_old, 0.1);
    return max(texel_new, texel_old);
}
