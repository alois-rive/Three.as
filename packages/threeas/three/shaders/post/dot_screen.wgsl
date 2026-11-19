// three.js DotScreenShader (examples/jsm/shaders/DotScreenShader.js), as a
// post shader (ShaderMaterial contract, see copy.wgsl). Based on glfx.js.

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

// Uniforms in insertion order: tSize, center, angle, scale (then tDiffuse).
struct Uniforms {
    tSize: vec2<f32>,
    center: vec2<f32>,
    angle: f32,
    scale: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

fn pattern(uv: vec2<f32>) -> f32 {
    let s = sin(u.angle);
    let c = cos(u.angle);
    // three.js's vUv runs bottom up.
    let tex = vec2<f32>(uv.x, 1.0 - uv.y) * u.tSize - u.center;
    let point = vec2<f32>(c * tex.x - s * tex.y, s * tex.x + c * tex.y) * u.scale;
    return (sin(point.x) * sin(point.y)) * 4.0;
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let color = textureSample(tDiffuse, s_tex, in.uv);
    let average = (color.r + color.g + color.b) / 3.0;
    return vec4<f32>(vec3<f32>(average * 10.0 - 5.0 + pattern(in.uv)), color.a);
}
