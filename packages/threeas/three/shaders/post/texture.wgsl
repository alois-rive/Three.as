// TexturePass (three.js examples/jsm/postprocessing/TexturePass.js): any
// texture drawn over the composer's linear buffer with `opacity`. three.js
// samples it through CopyShader and lets the texture format decode sRGB;
// here the shader decodes what the texture says it holds: sRGB,
// premultiplied alpha and row order (flipY).

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
    opacity: f32,
    // x: sRGB, y: premultiplied, z: flipY (rows top first)
    flags: vec4<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 0.0773993808;
    let hi = pow(c * 0.9478672986 + vec3<f32>(0.0521327014), vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let uv = select(vec2<f32>(in.uv.x, 1.0 - in.uv.y), in.uv, u.flags.z > 0.5);
    var c = textureSample(tDiffuse, s_tex, uv);
    var rgb = c.rgb;
    if (u.flags.y > 0.5 && c.a > 0.0) {
        rgb = rgb / c.a;
    }
    if (u.flags.x > 0.5) {
        rgb = srgb_to_linear(rgb);
    }
    // Premultiplied out, as the composer's buffers.
    return vec4<f32>(rgb * c.a, c.a) * u.opacity;
}
