// three.js GTAOBlendShader (examples/jsm/shaders/GTAOShader.js): the
// occlusion mixed towards white by intensity (GTAOPass multiplies it onto
// the scene). See ssao.wgsl for the conventions.

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

struct Uniforms {
    intensity: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texel = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0);
    return vec4<f32>(mix(vec3<f32>(1.0), texel.rgb, u.intensity), texel.a);
}
