// three.js Lensflare's second RawShaderMaterial (examples/jsm/objects/
// Lensflare.js, r170), for three/addons/objects/Lensflare: puts back the
// pixels the occlusion quad covered, from their copy (`map`, a
// FramebufferTexture: rows top first, read at (u, 1 - v)), as they were
// (the framebuffer's own encoding). ShaderMaterial contract (see
// three/materials/ShaderMaterial.as).

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

// Uniforms in insertion order: scale, screenPosition; then map.
struct Uniforms {
    scale: vec2<f32>,
    screenPosition: vec3<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var map: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) vUV: vec2<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(2) uv: vec2<f32>) -> VsOut {
    var out: VsOut;
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    out.vUV = uv;
    out.clip = vec4<f32>(position.xy * u.scale + u.screenPosition.xy, u.screenPosition.z + keep, 1.0);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return textureSample(map, s_tex, vec2<f32>(in.vUV.x, 1.0 - in.vUV.y));
}
