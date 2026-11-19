// three.js examples/jsm/postprocessing/LUTPass.js's LUTShader, as a post
// shader (see copy.wgsl): the colour looked up in a 3D LUT (a
// Data3DTexture, texture_3d), mixed in by intensity.

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

// LUTShader's uniforms: values in insertion order (lutSize, intensity),
// then the textures (lut, tDiffuse) and lut's sampler (linear, clamped).
struct Uniforms {
    lutSize: f32,
    intensity: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var lut: texture_3d<f32>;
@group(2) @binding(2) var tDiffuse: texture_2d<f32>;
@group(2) @binding(3) var s_lut: sampler;

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let val = textureSampleLevel(tDiffuse, s_lut, in.uv, 0.0);
    // Pull the sample in by half a texel so it starts at the centre of the
    // edge texels.
    let pixel_width = 1.0 / u.lutSize;
    let half_pixel_width = 0.5 / u.lutSize;
    let uvw = vec3<f32>(half_pixel_width) + val.rgb * (1.0 - pixel_width);
    let lut_val = vec4<f32>(textureSampleLevel(lut, s_lut, uvw, 0.0).rgb, val.a);
    return mix(val, lut_val, u.intensity);
}
