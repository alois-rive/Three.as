// three.js SSAOBlurShader (examples/jsm/shaders/SSAOShader.js): a 5 x 5
// box blur of the occlusion. See ssao.wgsl for the conventions.

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
    resolution: vec2<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texel_size = 1.0 / u.resolution;
    var result = 0.0;
    for (var i = -2; i <= 2; i++) {
        for (var j = -2; j <= 2; j++) {
            let offset = vec2<f32>(f32(i), f32(j)) * texel_size;
            result += textureSampleLevel(tDiffuse, s_tex, in.uv + offset, 0.0).r;
        }
    }
    return vec4<f32>(vec3<f32>(result / (5.0 * 5.0)), 1.0);
}
