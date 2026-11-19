// three.js DigitalGlitch (examples/jsm/shaders/DigitalGlitch.js): RGB
// shift, displaced bands and snow. Post shader (see copy.wgsl).

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

// Uniforms in insertion order (then tDiffuse, tDisp).
struct Uniforms {
    byp: f32,
    amount: f32,
    angle: f32,
    seed: f32,
    seed_x: f32,
    seed_y: f32,
    distortion_x: f32,
    distortion_y: f32,
    col_s: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var tDisp: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

fn rand(co: vec2<f32>) -> f32 {
    return fract(sin(dot(co, vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

// The rows of render targets are top first: three.js's vUv (bottom up) to
// a texture coordinate.
fn tex_uv(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(p.x, 1.0 - p.y);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    // Uniform control flow: sample before branching.
    let plain = textureSample(tDiffuse, s_tex, in.uv);
    var p = vec2<f32>(in.uv.x, 1.0 - in.uv.y);
    let xs = floor(in.clip.x / 0.5);
    let ys = floor(in.clip.y / 0.5);
    // tDisp is a DataTexture read nearest, clamped (as three.js's defaults).
    let size = vec2<i32>(textureDimensions(tDisp));
    let dp = clamp(vec2<i32>(floor(p * u.seed * u.seed * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    let disp = textureLoad(tDisp, dp, 0).r;
    if (p.y < u.distortion_x + u.col_s && p.y > u.distortion_x - u.col_s * u.seed) {
        if (u.seed_x > 0.0) {
            p.y = 1.0 - (p.y + u.distortion_y);
        } else {
            p.y = u.distortion_y;
        }
    }
    if (p.x < u.distortion_y + u.col_s && p.x > u.distortion_y - u.col_s * u.seed) {
        if (u.seed_y > 0.0) {
            p.x = u.distortion_x;
        } else {
            p.x = 1.0 - (p.x + u.distortion_x);
        }
    }
    p.x += disp * u.seed_x * (u.seed / 5.0);
    p.y += disp * u.seed_y * (u.seed / 5.0);
    let offset = u.amount * vec2<f32>(cos(u.angle), sin(u.angle));
    let cr = textureSampleLevel(tDiffuse, s_tex, tex_uv(p + offset), 0.0);
    let cga = textureSampleLevel(tDiffuse, s_tex, tex_uv(p), 0.0);
    let cb = textureSampleLevel(tDiffuse, s_tex, tex_uv(p - offset), 0.0);
    var color = vec4<f32>(cr.r, cga.g, cb.b, cga.a);
    let snow = 200.0 * u.amount * vec4<f32>(rand(vec2<f32>(xs * u.seed, ys * u.seed * 50.0)) * 0.2);
    color += snow;
    return select(color, plain, u.byp > 0.5);
}
