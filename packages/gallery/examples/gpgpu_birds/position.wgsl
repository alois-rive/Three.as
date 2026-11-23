// The birds' positions (three.js webgl_gpgpu_birds' fragmentShaderPosition),
// a GPUComputationRenderer compute shader: xyz the position, w the wing
// phase. Vertex stage and bindings as three/shaders/misc/gpu_computation.wgsl.

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> @builtin(position) vec4<f32> {
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    return vec4<f32>(position.xy, 0.5 + keep, 1.0);
}

// Uniforms in insertion order: resolution (GPUComputationRenderer), time,
// delta; then the dependencies' textures (texturePosition,
// textureVelocity) and their sampler.
struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    delta: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var texturePosition: texture_2d<f32>;
@group(2) @binding(2) var textureVelocity: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

// GLSL's mod (x - y * floor(x / y)).
fn glsl_mod(x: f32, y: f32) -> f32 {
    return x - y * floor(x / y);
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    _ = s_tex;   // bound by the contract, unused (textureLoad)
    let p = vec2<i32>(frag.xy);
    let tmpPos = textureLoad(texturePosition, p, 0);
    let position = tmpPos.xyz;
    let velocity = textureLoad(textureVelocity, p, 0).xyz;
    var phase = tmpPos.w;
    phase = glsl_mod(phase + u.delta + length(velocity.xz) * u.delta * 3.0 + max(velocity.y, 0.0) * u.delta * 6.0,
        62.83);
    return vec4<f32>(position + velocity * u.delta * 15.0, phase);
}
