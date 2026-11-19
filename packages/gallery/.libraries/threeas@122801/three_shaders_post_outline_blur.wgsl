// OutlinePass's separable gaussian blur (three.js OutlinePass.js
// getSeperableBlurMaterial), MAX_RADIUS 4 (both of three.js's instances
// use 4: MAX_EDGE_THICKNESS and MAX_EDGE_GLOW). Post shader (see copy.wgsl).

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

const MAX_RADIUS: i32 = 4;

// Uniforms in insertion order: texSize, direction, kernelRadius (then
// colorTexture).
struct Uniforms {
    texSize: vec2<f32>,
    direction: vec2<f32>,
    kernelRadius: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var colorTexture: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

fn gaussian_pdf(x: f32, sigma: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / (sigma * sigma)) / sigma;
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let inv_size = 1.0 / u.texSize;
    let sigma = u.kernelRadius / 2.0;
    var weight_sum = gaussian_pdf(0.0, sigma);
    var diffuse_sum = textureSampleLevel(colorTexture, s_tex, in.uv, 0.0) * weight_sum;
    let delta = u.direction * inv_size * u.kernelRadius / f32(MAX_RADIUS);
    var uv_offset = delta;
    for (var i = 1; i <= MAX_RADIUS; i++) {
        let x = u.kernelRadius * f32(i) / f32(MAX_RADIUS);
        let w = gaussian_pdf(x, sigma);
        let sample1 = textureSampleLevel(colorTexture, s_tex, in.uv + uv_offset, 0.0);
        let sample2 = textureSampleLevel(colorTexture, s_tex, in.uv - uv_offset, 0.0);
        diffuse_sum += (sample1 + sample2) * w;
        weight_sum += 2.0 * w;
        uv_offset += delta;
    }
    return diffuse_sum / weight_sum;
}
