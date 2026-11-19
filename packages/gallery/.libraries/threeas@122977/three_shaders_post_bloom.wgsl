// Post-processing shader (three/addons/postprocessing), ShaderMaterial
// contract: frame block at group 0, object block at group 1 (both touched so
// they stay in the layout), uniforms at group 2. Fullscreen-quad vertices
// pass through; uv (0, 0) is the bottom left, so textures rendered by the
// renderer (top row first) are read at (u, 1 - v).

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

// UnrealBloomPass's three stages, as three.js: a luminosity high pass, a
// separable gaussian blur (one direction per draw), and the composite of
// the blurred mips. Entry points: fs_high_pass, fs_blur, fs_composite.
// Uniforms (one block for all, in this order): threshold, smoothWidth,
// direction (vec2, texels), kernelRadius, strength, radius, then the
// textures tDiffuse and blur1..blur5.
struct Uniforms {
    threshold: f32,
    smoothWidth: f32,
    direction: vec2<f32>,
    kernelRadius: f32,
    strength: f32,
    radius: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var blur1: texture_2d<f32>;
@group(2) @binding(3) var blur2: texture_2d<f32>;
@group(2) @binding(4) var blur3: texture_2d<f32>;
@group(2) @binding(5) var blur4: texture_2d<f32>;
@group(2) @binding(6) var blur5: texture_2d<f32>;
@group(2) @binding(7) var s_tex: sampler;

@fragment
fn fs_high_pass(in: QuadOut) -> @location(0) vec4<f32> {
    let texel = textureSample(tDiffuse, s_tex, in.uv);
    let luma = dot(texel.rgb, vec3<f32>(0.299, 0.587, 0.114));
    let alpha = smoothstep(u.threshold, u.threshold + u.smoothWidth, luma);
    return mix(vec4<f32>(0.0), texel, alpha);
}

fn gaussian(x: f32, sigma: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / (sigma * sigma)) / sigma;
}

@fragment
fn fs_blur(in: QuadOut) -> @location(0) vec4<f32> {
    let size = vec2<f32>(textureDimensions(tDiffuse));
    let step = u.direction / size;
    let radius = i32(u.kernelRadius);
    let sigma = max(u.kernelRadius, 1.0);
    var sum = textureSample(tDiffuse, s_tex, in.uv) * gaussian(0.0, sigma);
    var weight = gaussian(0.0, sigma);
    for (var i = 1; i <= 11; i++) {
        if (i > radius) { break; }
        let w = gaussian(f32(i), sigma);
        sum += textureSampleLevel(tDiffuse, s_tex, in.uv + step * f32(i), 0.0) * w;
        sum += textureSampleLevel(tDiffuse, s_tex, in.uv - step * f32(i), 0.0) * w;
        weight += 2.0 * w;
    }
    return sum / weight;
}

fn factor(f: f32) -> f32 {
    return mix(f, 1.2 - f, u.radius);
}

@fragment
fn fs_composite(in: QuadOut) -> @location(0) vec4<f32> {
    let b = factor(1.0) * textureSample(blur1, s_tex, in.uv)
        + factor(0.8) * textureSample(blur2, s_tex, in.uv)
        + factor(0.6) * textureSample(blur3, s_tex, in.uv)
        + factor(0.4) * textureSample(blur4, s_tex, in.uv)
        + factor(0.2) * textureSample(blur5, s_tex, in.uv);
    let keep = textureSample(tDiffuse, s_tex, in.uv) * 0.0;
    return u.strength * b + keep;
}
