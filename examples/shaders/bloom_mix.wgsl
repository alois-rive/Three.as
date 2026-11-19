// three.js's selective bloom example (webgl_postprocessing_unreal_bloom_selective):
// the scene plus the bloom of its bloom layer, rendered by a second
// composer (examples/effects.as). A ShaderPass shader: the quad places
// itself; render target textures are read at (u, 1 - v).

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

@group(2) @binding(1) var baseTexture: texture_2d<f32>;
@group(2) @binding(2) var bloomTexture: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

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

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    return textureSample(baseTexture, s_tex, in.uv) + vec4<f32>(1.0) * textureSample(bloomTexture, s_tex, in.uv);
}
