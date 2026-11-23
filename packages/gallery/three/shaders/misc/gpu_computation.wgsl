// A copy of the engine's three/shaders/misc/gpu_computation.wgsl (M19), under
// its asset name, for the GpgpuBirds example: a new engine shader reaches the
// gallery only once the library is republished (AGENTS.md). Delete this copy
// once the gallery imports a library version that has it.

// GPUComputationRenderer's pass-through shader
// (three/addons/misc/GPUComputationRenderer.as): copies `passThruTexture`
// into a variable's render target, texel for texel (renderTexture). The
// ShaderMaterial contract (frame block at group 0 and object block at
// group 1, both touched so they stay in the layout; the material's
// uniforms at group 2): `resolution` (the target's size, three.js's
// define), then the texture, then its sampler.
//
// It is also the template of a compute shader: the vertex stage places the
// fullscreen quad, and the fragment reads its texel of each dependency
// with textureLoad at @builtin(position) (row 0 of every texture is row 0
// of the target, data index (y * sizeX + x) * 4). textureLoad, not
// textureSample: 32-bit float textures are not filterable on WebGPU.

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> @builtin(position) vec4<f32> {
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    return vec4<f32>(position.xy, 0.5 + keep, 1.0);
}

struct Uniforms { resolution: vec2<f32> };
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var passThruTexture: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    // uv = gl_FragCoord.xy / resolution, read at the input's own size.
    _ = s_tex;   // bound by the contract, unused (textureLoad)
    let size = vec2<i32>(textureDimensions(passThruTexture));
    let uv = frag.xy / u.resolution;
    let p = clamp(vec2<i32>(floor(uv * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    return textureLoad(passThruTexture, p, 0);
}
