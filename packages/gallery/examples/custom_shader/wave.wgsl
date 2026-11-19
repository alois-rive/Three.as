// A ShaderMaterial shader (examples/custom_shader/custom_shader.as): a plane rippled by
// sine waves, showing a texture uniform, shaded by its slope with a
// fresnel tint. Bindings follow three/materials/ShaderMaterial.as.

struct Frame {
    view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    camera_pos: vec4<f32>,
};

struct Object {
    model: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
};

// The material's uniforms, in insertion order: time, amplitude, tint.
struct Uniforms {
    time: f32,
    amplitude: f32,
    tint: vec3<f32>,
};

@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var t_map: texture_2d<f32>;
@group(2) @binding(2) var s_map: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

fn height(p: vec2<f32>) -> f32 {
    return sin(p.x * 3.0 + u.time * 2.0) * cos(p.y * 2.5 + u.time * 1.3) * u.amplitude;
}

@vertex
fn vs_main(in: VsIn) -> VsOut {
    var out: VsOut;
    let p = in.position.xy;
    let h = height(p);
    let e = 0.01;
    let dx = (height(p + vec2<f32>(e, 0.0)) - h) / e;
    let dy = (height(p + vec2<f32>(0.0, e)) - h) / e;
    let world = object.model * vec4<f32>(p, h, 1.0);
    out.clip = frame.view_proj * world;
    out.world = world.xyz;
    out.normal = normalize((object.normal_matrix * vec4<f32>(-dx, -dy, 1.0, 0.0)).xyz);
    out.uv = in.uv;
    return out;
}

@fragment
fn fs_main(in: VsOut, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    // Rive images are stored top row first and are sRGB, premultiplied: the
    // same as the canvas output, so the texel goes out as it is.
    let texel = textureSample(t_map, s_map, vec2<f32>(in.uv.x, 1.0 - in.uv.y));
    let n = select(-in.normal, in.normal, front);
    let v = normalize(frame.camera_pos.xyz - in.world);
    let light = normalize(vec3<f32>(0.4, 0.8, 0.6));
    let shade = 0.55 + 0.45 * max(dot(n, light), 0.0);
    let fresnel = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    return vec4<f32>(texel.rgb * shade + u.tint * fresnel * texel.a, texel.a);
}
