// three.js FilmShader (examples/jsm/shaders/FilmShader.js, r170): noise
// grain over the image, optionally grayscale. Post shader (see copy.wgsl).

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

// Uniforms in insertion order: time, intensity, grayscale (0 or 1).
struct Uniforms {
    time: f32,
    intensity: f32,
    grayscale: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

const PI: f32 = 3.141592653589793;

// three.js's common.glsl rand().
fn rand(uv: vec2<f32>) -> f32 {
    let dt = dot(uv, vec2<f32>(12.9898, 78.233));
    let sn = dt - PI * floor(dt / PI);
    return fract(sin(sn) * 43758.5453);
}

fn luminance(rgb: vec3<f32>) -> f32 {
    return dot(rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let base = textureSample(tDiffuse, s_tex, in.uv);
    let noise = rand(fract(vec2<f32>(in.uv.x, 1.0 - in.uv.y) + vec2<f32>(u.time)));
    var color = base.rgb + base.rgb * clamp(0.1 + noise, 0.0, 1.0);
    color = mix(base.rgb, color, u.intensity);
    if (u.grayscale > 0.5) {
        color = vec3<f32>(luminance(color));
    }
    return vec4<f32>(color, base.a);
}
