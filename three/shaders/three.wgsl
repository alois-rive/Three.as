// ThreeAS mesh shader (three/renderers/GPURenderer.as). One pipeline family
// for every M1 material; the material kind is a uniform branch.
//
// Group 0: per-frame block (camera, lights).
// Group 1: per-draw block, the material's map and its sampler.
// Layouts are mirrored by hand in renderers/gpu/layout.as.
//
// Lighting follows three.js's physically based model: light intensities
// are irradiance (no PI scaling), diffuse is BRDF_Lambert = albedo / PI,
// specular is three's BRDF_GGX, point lights fall off as
// 1 / distance^decay with the smooth cut off at `distance`.

const PI: f32 = 3.141592653589793;
const RECIPROCAL_PI: f32 = 0.3183098861837907;
const MAX_LIGHTS: u32 = 8u;

const KIND_BASIC: u32 = 0u;
const KIND_NORMAL: u32 = 1u;
const KIND_LAMBERT: u32 = 2u;
const KIND_STANDARD: u32 = 3u;

const MAP_ON: u32 = 1u;
const MAP_SRGB: u32 = 2u;
const MAP_FLIP_Y: u32 = 4u;
const MAP_PREMULTIPLIED: u32 = 8u;

const LIGHT_DIRECTIONAL: f32 = 0.0;
const LIGHT_POINT: f32 = 1.0;

struct Light {
    position: vec4<f32>,   // xyz world position, w kind
    direction: vec4<f32>,  // xyz unit direction towards the light (directional)
    color: vec4<f32>,      // rgb colour x intensity (linear), w cut off distance
    params: vec4<f32>,     // x decay
};

struct FrameU {
    view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
    camera_pos: vec4<f32>,  // xyz, w 1 for orthographic
    camera_dir: vec4<f32>,  // xyz forward (world)
    ambient: vec4<f32>,     // rgb summed ambient light, w light count
    lights: array<Light, 8>,
};

struct ObjU {
    model: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
    color: vec4<f32>,       // rgb linear, a opacity
    emissive: vec4<f32>,    // rgb emissive x intensity, w alphaTest
    pbr: vec4<f32>,         // x roughness, y metalness, z flat shading
    uv_xform: vec4<f32>,    // xy offset, zw repeat
    flags: vec4<u32>,       // x kind, y map flags, z unused, w transparent
};

@group(0) @binding(0) var<uniform> F: FrameU;
@group(1) @binding(0) var<uniform> O: ObjU;
@group(1) @binding(1) var t_map: texture_2d<f32>;
@group(1) @binding(2) var s_map: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    var out: VsOut;
    let world = O.model * vec4<f32>(in.position, 1.0);
    out.clip = F.view_proj * world;
    out.world = world.xyz;
    out.normal = (O.normal_matrix * vec4<f32>(in.normal, 0.0)).xyz;
    out.uv = in.uv * O.uv_xform.zw + O.uv_xform.xy;
    return out;
}

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

fn F_Schlick(f0: vec3<f32>, f90: f32, dotVH: f32) -> vec3<f32> {
    let fresnel = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
    return f0 * (1.0 - fresnel) + vec3<f32>(f90 * fresnel);
}

fn V_GGX_SmithCorrelated(alpha: f32, dotNL: f32, dotNV: f32) -> f32 {
    let a2 = alpha * alpha;
    let gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    let gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    return 0.5 / max(gv + gl, 1e-6);
}

fn D_GGX(alpha: f32, dotNH: f32) -> f32 {
    let a2 = alpha * alpha;
    let denom = dotNH * dotNH * (a2 - 1.0) + 1.0;
    return RECIPROCAL_PI * a2 / (denom * denom);
}

fn BRDF_GGX(L: vec3<f32>, V: vec3<f32>, N: vec3<f32>, f0: vec3<f32>, roughness: f32) -> vec3<f32> {
    let alpha = roughness * roughness;
    let H = normalize(L + V);
    let dotNL = saturate(dot(N, L));
    let dotNV = saturate(dot(N, V));
    let dotNH = saturate(dot(N, H));
    let dotVH = saturate(dot(V, H));
    return F_Schlick(f0, 1.0, dotVH) * (V_GGX_SmithCorrelated(alpha, dotNL, dotNV) * D_GGX(alpha, dotNH));
}

fn distance_attenuation(d: f32, cutoff: f32, decay: f32) -> f32 {
    var falloff = 1.0 / max(pow(d, decay), 0.01);
    if (cutoff > 0.0) {
        let r = d / cutoff;
        let s = saturate(1.0 - r * r * r * r);
        falloff *= s * s;
    }
    return falloff;
}

@fragment
fn fs_main(in: VsOut, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    let kind = O.flags.x;
    let map_flags = O.flags.y;

    // Sampled and differentiated in uniform control flow; used below.
    var uv = in.uv;
    if ((map_flags & MAP_FLIP_Y) != 0u) {
        uv.y = 1.0 - uv.y;
    }
    var texel = textureSample(t_map, s_map, uv);
    let dx = dpdx(in.world);
    let dy = dpdy(in.world);

    var base = O.color;
    if ((map_flags & MAP_ON) != 0u) {
        if ((map_flags & MAP_PREMULTIPLIED) != 0u && texel.a > 0.0) {
            texel = vec4<f32>(texel.rgb / texel.a, texel.a);
        }
        if ((map_flags & MAP_SRGB) != 0u) {
            texel = vec4<f32>(srgb_to_linear(texel.rgb), texel.a);
        }
        base = base * texel;
    }
    if (base.a < O.emissive.w) {
        discard;
    }
    let alpha = select(1.0, base.a, O.flags.w != 0u);

    // The shading normal: interpolated or flat, facing the viewer.
    let orthographic = F.camera_pos.w > 0.5;
    let V = select(normalize(F.camera_pos.xyz - in.world), -F.camera_dir.xyz, orthographic);
    var N = normalize(in.normal);
    if (O.pbr.z > 0.5) {
        N = normalize(cross(dx, dy));
        if (dot(N, V) < 0.0) {
            N = -N;
        }
    } else if (!front) {
        N = -N;
    }

    if (kind == KIND_NORMAL) {
        let vn = normalize((F.view * vec4<f32>(N, 0.0)).xyz);
        let packed = vn * 0.5 + vec3<f32>(0.5);
        return vec4<f32>(packed * alpha, alpha);
    }

    var rgb = base.rgb;
    if (kind == KIND_LAMBERT || kind == KIND_STANDARD) {
        let metalness = select(0.0, saturate(O.pbr.y), kind == KIND_STANDARD);
        let roughness = clamp(O.pbr.x, 0.0525, 1.0);
        let diffuse_color = base.rgb * (1.0 - metalness);
        let f0 = mix(vec3<f32>(0.04), base.rgb, metalness);

        var irradiance_sum = F.ambient.rgb;
        var specular = vec3<f32>(0.0);
        let count = min(u32(F.ambient.w), MAX_LIGHTS);
        for (var i = 0u; i < count; i++) {
            let light = F.lights[i];
            var L: vec3<f32>;
            var radiance = light.color.rgb;
            if (light.position.w == LIGHT_POINT) {
                let to_light = light.position.xyz - in.world;
                let d = length(to_light);
                L = to_light / max(d, 1e-6);
                radiance *= distance_attenuation(d, light.color.w, light.params.x);
            } else {
                L = light.direction.xyz;
            }
            let dotNL = saturate(dot(N, L));
            let irradiance = dotNL * radiance;
            irradiance_sum += irradiance;
            if (kind == KIND_STANDARD) {
                specular += irradiance * BRDF_GGX(L, V, N, f0, roughness);
            }
        }
        rgb = irradiance_sum * (diffuse_color * RECIPROCAL_PI) + specular + O.emissive.rgb;
    }

    // Linear to sRGB output, premultiplied for the canvas.
    return vec4<f32>(linear_to_srgb(rgb) * alpha, alpha);
}
