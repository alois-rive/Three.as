// three.js Lensflare's first RawShaderMaterial (examples/jsm/objects/
// Lensflare.js, r170), for three/addons/objects/Lensflare: a magenta quad
// at the flare's screen position and depth, depth tested, whose copy tells
// how much of the flare is hidden. ShaderMaterial contract (see
// three/materials/ShaderMaterial.as); the frame and object blocks are only
// touched.

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

// Uniforms in insertion order.
struct Uniforms {
    scale: vec2<f32>,
    screenPosition: vec3<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> @builtin(position) vec4<f32> {
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    return vec4<f32>(position.xy * u.scale + u.screenPosition.xy, u.screenPosition.z + keep, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 0.0, 1.0, 1.0);
}
