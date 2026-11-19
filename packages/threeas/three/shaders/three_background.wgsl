// ThreeAS background (renderers/GPURenderer.as): scene.background as a
// fullscreen pass, a module of its own so its texture does not count
// against three.wgsl's per-stage texture budget. Its group 0 is the frame
// block (a prefix of three.wgsl's FrameU), the background and a sampler.

const RECIPROCAL_PI: f32 = 0.3183098861837907;
const MAPPING_EQUIRECT: u32 = 303u;

struct FrameU {
    view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    camera_pos: vec4<f32>,   // xyz, w 1 for orthographic
    camera_dir: vec4<f32>,   // xyz forward (world)
    ambient: vec4<f32>,      // rgb summed ambient light, w light count
    hemi_sky: vec4<f32>,     // rgb sky x intensity
    hemi_ground: vec4<f32>,  // rgb ground x intensity
    hemi_dir: vec4<f32>,     // xyz up direction, w 1 when there is one
    fog_color: vec4<f32>,    // rgb, w FOG_*
    fog_params: vec4<f32>,   // near, far, density
    output: vec4<f32>,       // x tone mapping, y exposure, z background intensity, w background max mip
    bg_rotation: mat4x4<f32>,
    bg_flags: vec4<u32>,     // x mapping, y srgb, z flipY, w premultiplied
    proj: mat4x4<f32>,
    viewport: vec4<f32>,     // width, height (pixels), pixel ratio
    env: vec4<f32>,          // x 1 when there is an environment, y intensity, z max mip
    env_rotation: mat4x4<f32>,
    env_flags: vec4<u32>,    // x srgb, y flipY, z premultiplied
    shadow_params: vec4<f32>, // x type (0 basic, 1 PCF, 2 PCF soft), y texel size, z 1: linear HDR output
};

@group(0) @binding(0) var<uniform> F: FrameU;
@group(0) @binding(1) var t_background: texture_2d<f32>;
@group(0) @binding(2) var s_background: sampler;

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 0.0773993808;
    let hi = pow(c * 0.9478672986 + vec3<f32>(0.0521327014), vec3<f32>(2.4));
    return select(hi, lo, c < vec3<f32>(0.04045));
}

fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let x = max(c, vec3<f32>(0.0));
    let lo = x * 12.92;
    let hi = 1.055 * pow(x, vec3<f32>(0.41666)) - vec3<f32>(0.055);
    return select(hi, lo, x < vec3<f32>(0.0031308));
}

fn decode(texel: vec4<f32>, premultiplied: bool, srgb: bool) -> vec4<f32> {
    var t = texel;
    if (premultiplied && t.a > 0.0) {
        t = vec4<f32>(t.rgb / t.a, t.a);
    }
    if (srgb) {
        t = vec4<f32>(srgb_to_linear(t.rgb), t.a);
    }
    return t;
}

struct BgOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) ndc: vec2<f32>,
};

@vertex
fn vs_background(@builtin(vertex_index) vi: u32) -> BgOut {
    var out: BgOut;
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    out.clip = vec4<f32>(x, y, 1.0, 1.0);
    out.ndc = vec2<f32>(x, y);
    return out;
}

@fragment
fn fs_background(in: BgOut) -> @location(0) vec4<f32> {
    var uv: vec2<f32>;
    if (F.bg_flags.x == MAPPING_EQUIRECT) {
        let far = F.inv_view_proj * vec4<f32>(in.ndc, 1.0, 1.0);
        let near = F.inv_view_proj * vec4<f32>(in.ndc, 0.0, 1.0);
        var dir = normalize(far.xyz / far.w - near.xyz / near.w);
        dir = (F.bg_rotation * vec4<f32>(dir, 0.0)).xyz;
        uv = vec2<f32>(atan2(dir.z, dir.x) * 0.5 * RECIPROCAL_PI + 0.5,
                       asin(clamp(dir.y, -1.0, 1.0)) * RECIPROCAL_PI + 0.5);
    } else {
        uv = in.ndc * 0.5 + vec2<f32>(0.5);
    }
    if (F.bg_flags.z != 0u) {
        uv.y = 1.0 - uv.y;
    }
    let texel = textureSampleLevel(t_background, s_background, uv, F.output.w);
    let c = decode(texel, F.bg_flags.w != 0u, F.bg_flags.y != 0u);
    let bg = c.rgb * F.output.z;
    if (F.shadow_params.z > 0.5) {
        return vec4<f32>(bg, 1.0);
    }
    return vec4<f32>(linear_to_srgb(bg), 1.0);
}
