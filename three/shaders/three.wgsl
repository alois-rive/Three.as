// ThreeAS shaders (three/renderers/GPURenderer.as). Every mesh material is
// one pipeline family; the shading model is a uniform branch on O.flags.x.
//
// Group 0: the frame block (camera, lights, fog, tone mapping, background).
// Group 1: the per-draw block.
// Group 2: the material's textures (slots 0..6) and their sampler.
// Group 3: the background texture and sampler (background pass only).
// Layouts are mirrored by hand in renderers/gpu/Layout.as.
//
// Lighting follows three.js: physical light intensities, BRDF_Lambert,
// BRDF_GGX, BRDF_BlinnPhong, Charlie sheen, clearcoat, its distance and spot
// attenuation, its tone mappers. Output is linear -> tone mapped -> fog ->
// sRGB, premultiplied.

const PI: f32 = 3.141592653589793;
const RECIPROCAL_PI: f32 = 0.3183098861837907;
const MAX_LIGHTS: u32 = 8u;

const KIND_BASIC: u32 = 0u;
const KIND_NORMAL: u32 = 1u;
const KIND_LAMBERT: u32 = 2u;
const KIND_STANDARD: u32 = 3u;
const KIND_PHONG: u32 = 4u;
const KIND_TOON: u32 = 5u;
const KIND_MATCAP: u32 = 6u;
const KIND_DEPTH: u32 = 7u;
const KIND_PHYSICAL: u32 = 8u;
const KIND_LINE_DASHED: u32 = 9u;

const SLOT_MAP: u32 = 0u;
const SLOT_NORMAL: u32 = 1u;
const SLOT_AUX: u32 = 2u;
const SLOT_METALNESS: u32 = 3u;
const SLOT_AO: u32 = 4u;
const SLOT_EMISSIVE: u32 = 5u;
const SLOT_ALPHA: u32 = 6u;

const FLAG_VERTEX_COLORS: u32 = 1u;
const FLAG_FOG: u32 = 2u;
const FLAG_TRANSPARENT: u32 = 4u;
const FLAG_TONE_MAPPED: u32 = 8u;
const FLAG_RECEIVE_SHADOW: u32 = 16u;

const LIGHT_DIRECTIONAL: f32 = 0.0;
const LIGHT_POINT: f32 = 1.0;
const LIGHT_SPOT: f32 = 2.0;

const FOG_LINEAR: f32 = 1.0;
const FOG_EXP2: f32 = 2.0;

const TONE_LINEAR: u32 = 1u;
const TONE_REINHARD: u32 = 2u;
const TONE_CINEON: u32 = 3u;
const TONE_ACES: u32 = 4u;
const TONE_AGX: u32 = 6u;
const TONE_NEUTRAL: u32 = 7u;

const MAPPING_EQUIRECT: u32 = 303u;

struct Light {
    position: vec4<f32>,   // xyz world position, w kind
    direction: vec4<f32>,  // xyz unit direction towards the light, w cos(cone)
    color: vec4<f32>,      // rgb colour x intensity (linear), w cut off distance
    params: vec4<f32>,     // x decay, y cos(penumbra edge)
    shadow: vec4<f32>,     // x first shadow layer (-1: none), y bias, z normalBias, w radius
    shadow2: vec4<f32>,    // x intensity, y 1 for a point light (six layers)
};

const MAX_SHADOW_TILES: u32 = 12u;

struct ShadowTile {
    matrix: mat4x4<f32>,   // world -> the light camera's clip space
    params: vec4<f32>,
};

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
    lights: array<Light, 8>,
    shadow_tiles: array<ShadowTile, 12>,
};

struct ObjU {
    model: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
    color: vec4<f32>,        // rgb linear, a opacity
    emissive: vec4<f32>,     // rgb emissive x intensity, w alphaTest
    pbr: vec4<f32>,          // roughness, metalness, flat shading, aoMapIntensity
    unused_uv: vec4<f32>,
    specular: vec4<f32>,     // rgb Phong specular, w shininess
    extra: vec4<f32>,        // xy normalScale, z envMapIntensity, w ior
    physical0: vec4<f32>,    // clearcoat, clearcoatRoughness, sheenRoughness, specularIntensity
    physical1: vec4<f32>,    // rgb sheen colour x sheen
    physical2: vec4<f32>,    // rgb specular colour
    tex_flags: vec4<u32>,    // x kind, y present, z sRGB, w flipY (bit per slot)
    flags: vec4<u32>,        // x premultiplied (bit per slot), y FLAG_*
    points: vec4<f32>,       // size, sizeAttenuation, rotation, viewport height / 2
    dash: vec4<f32>,         // dashSize, gapSize, scale
    sprite: vec4<f32>,       // xy sprite center
    bind_matrix: mat4x4<f32>,
    bind_matrix_inverse: mat4x4<f32>,
    // Per texture slot: its uv transform (three.js's texture.matrix rows,
    // xyz) and, in the first row's w, its uv channel.
    uv_matrix: array<vec4<f32>, 14>,
};

const MAX_BONES: u32 = 256u;

struct BonesU {
    bones: array<mat4x4<f32>, 256>,   // bone.matrixWorld x boneInverse
};

@group(0) @binding(0) var<uniform> F: FrameU;
@group(0) @binding(1) var t_env: texture_2d<f32>;
@group(0) @binding(2) var s_env: sampler;
@group(0) @binding(3) var t_shadow: texture_depth_2d_array;
@group(0) @binding(4) var s_shadow: sampler_comparison;
@group(0) @binding(5) var t_background: texture_2d<f32>;
@group(0) @binding(6) var s_background: sampler;
@group(1) @binding(0) var<uniform> O: ObjU;
@group(1) @binding(1) var<uniform> B: BonesU;
@group(2) @binding(0) var t_map: texture_2d<f32>;
@group(2) @binding(1) var t_normal: texture_2d<f32>;
@group(2) @binding(2) var t_aux: texture_2d<f32>;
@group(2) @binding(3) var t_metalness: texture_2d<f32>;
@group(2) @binding(4) var t_ao: texture_2d<f32>;
@group(2) @binding(5) var t_emissive: texture_2d<f32>;
@group(2) @binding(6) var t_alpha: texture_2d<f32>;
@group(3) @binding(0) var s_map: sampler;
@group(3) @binding(1) var s_normal: sampler;
@group(3) @binding(2) var s_aux: sampler;
@group(3) @binding(3) var s_metalness: sampler;
@group(3) @binding(4) var s_ao: sampler;
@group(3) @binding(5) var s_emissive: sampler;
@group(3) @binding(6) var s_alpha: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
    @location(11) uv1: vec2<f32>,
};

struct InstanceIn {
    @location(4) m0: vec4<f32>,
    @location(5) m1: vec4<f32>,
    @location(6) m2: vec4<f32>,
    @location(7) m3: vec4<f32>,
    @location(8) color: vec4<f32>,
};

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
    @location(4) view_depth: f32,
    @location(5) uv1: vec2<f32>,
};

fn has_flag(bits: u32, slot: u32) -> bool {
    return (bits & (1u << slot)) != 0u;
}

struct SkinIn {
    @location(9) index: vec4<f32>,
    @location(10) weight: vec4<f32>,
};

@vertex
fn vs_main(in: VsIn, inst: InstanceIn) -> VsOut {
    return transform_vertex(in.position, in.normal, in, inst);
}

// Skinned meshes: three.js's skinning (bindMatrixInverse x weighted bone
// matrices x bindMatrix) before the usual transform.
@vertex
fn vs_skinned(in: VsIn, inst: InstanceIn, skin: SkinIn) -> VsOut {
    let w = skin.weight;
    let i = vec4<u32>(min(vec4<u32>(skin.index), vec4<u32>(MAX_BONES - 1u)));
    let bones = B.bones[i.x] * w.x + B.bones[i.y] * w.y + B.bones[i.z] * w.z + B.bones[i.w] * w.w;
    let m = O.bind_matrix_inverse * bones * O.bind_matrix;
    let p = (m * vec4<f32>(in.position, 1.0)).xyz;
    let n = (m * vec4<f32>(in.normal, 0.0)).xyz;
    return transform_vertex(p, n, in, inst);
}

fn transform_vertex(position: vec3<f32>, normal: vec3<f32>, in: VsIn, inst: InstanceIn) -> VsOut {
    var out: VsOut;
    let im = mat4x4<f32>(inst.m0, inst.m1, inst.m2, inst.m3);
    let world = O.model * (im * vec4<f32>(position, 1.0));
    out.clip = F.view_proj * world;
    out.world = world.xyz;
    // three.js's instanced normal: undo the instance scale per axis.
    let im3 = mat3x3<f32>(im[0].xyz, im[1].xyz, im[2].xyz);
    let n = im3 * (normal / vec3<f32>(dot(im3[0], im3[0]), dot(im3[1], im3[1]), dot(im3[2], im3[2])));
    out.normal = (O.normal_matrix * vec4<f32>(n, 0.0)).xyz;
    out.uv = in.uv;
    out.uv1 = in.uv1;
    let vcolor = select(vec4<f32>(1.0), in.color, (O.flags.y & FLAG_VERTEX_COLORS) != 0u);
    out.color = vcolor * inst.color;
    out.view_depth = -(F.view * world).z;
    return out;
}

// The corners of a quad drawn as two triangles from vertex_index, -1..1.
fn quad_corner(vi: u32) -> vec2<f32> {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0));
    return corners[vi % 6u];
}

struct PointIn {
    @location(0) position: vec3<f32>,
    @location(3) color: vec4<f32>,
};

// Points: an instanced quad per vertex, `size` pixels (three.js's
// gl_PointSize, attenuated by depth with sizeAttenuation).
@vertex
fn vs_points(p: PointIn, @builtin(vertex_index) vi: u32) -> VsOut {
    var out: VsOut;
    let corner = quad_corner(vi);
    let world = O.model * vec4<f32>(p.position, 1.0);
    let clip = F.view_proj * world;
    let view_z = (F.view * world).z;
    var size = O.points.x * F.viewport.z;
    if (O.points.y > 0.5 && F.camera_pos.w < 0.5) {
        size *= O.points.w / max(-view_z, 1e-6);
    }
    let offset = corner * size / F.viewport.xy;
    out.clip = clip + vec4<f32>(offset * clip.w, 0.0, 0.0);
    out.world = world.xyz;
    out.normal = -F.camera_dir.xyz;
    out.uv = corner * 0.5 + vec2<f32>(0.5);
    out.uv1 = out.uv;
    out.color = select(vec4<f32>(1.0), p.color, (O.flags.y & FLAG_VERTEX_COLORS) != 0u);
    out.view_depth = -view_z;
    return out;
}

// Sprites: a camera-facing quad, as three.js's sprite vertex shader.
@vertex
fn vs_sprite(@builtin(vertex_index) vi: u32) -> VsOut {
    var out: VsOut;
    let corner = quad_corner(vi) * 0.5;
    let origin = O.model * vec4<f32>(0.0, 0.0, 0.0, 1.0);
    var mv = F.view * origin;
    var scale = vec2<f32>(length(O.model[0].xyz), length(O.model[1].xyz));
    if (O.points.y < 0.5 && F.camera_pos.w < 0.5) {
        scale *= -mv.z;
    }
    let aligned = (corner - (O.sprite.xy - vec2<f32>(0.5))) * scale;
    let c = cos(O.points.z);
    let s = sin(O.points.z);
    let rotated = vec2<f32>(c * aligned.x - s * aligned.y, s * aligned.x + c * aligned.y);
    mv = vec4<f32>(mv.xy + rotated, mv.z, 1.0);
    out.clip = F.proj * mv;
    out.world = origin.xyz;
    out.normal = -F.camera_dir.xyz;
    out.uv = corner + vec2<f32>(0.5);
    out.uv1 = out.uv;
    out.color = vec4<f32>(1.0);
    out.view_depth = -mv.z;
    return out;
}

// ---------------------------------------------------------------- colour

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

/// A texel as three.js sees it: straight alpha, linear colour.
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

/// A slot's uv: its channel's uv through its texture.matrix (three.js's
/// vMapUv and friends), before the flipY flip.
fn slot_uv(uv: vec2<f32>, uv1: vec2<f32>, slot: u32) -> vec2<f32> {
    let r0 = O.uv_matrix[slot * 2u];
    let r1 = O.uv_matrix[slot * 2u + 1u];
    let p = vec3<f32>(select(uv, uv1, r0.w > 0.5), 1.0);
    return vec2<f32>(dot(r0.xyz, p), dot(r1.xyz, p));
}

fn flip_uv(uv: vec2<f32>, slot: u32) -> vec2<f32> {
    return select(uv, vec2<f32>(uv.x, 1.0 - uv.y), has_flag(O.tex_flags.w, slot));
}

fn sample_slot(t: texture_2d<f32>, s: sampler, uv: vec2<f32>, slot: u32) -> vec4<f32> {
    let texel = textureSample(t, s, flip_uv(uv, slot));
    return decode(texel, has_flag(O.flags.x, slot), has_flag(O.tex_flags.z, slot));
}

// ---------------------------------------------------------------- tone mapping

fn rrt_and_odt_fit(v: vec3<f32>) -> vec3<f32> {
    let a = v * (v + 0.0245786) - 0.000090537;
    let b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

fn agx_contrast(x: vec3<f32>) -> vec3<f32> {
    let x2 = x * x;
    let x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

fn tone_map(color_in: vec3<f32>) -> vec3<f32> {
    let mode = u32(F.output.x);
    let exposure = F.output.y;
    var color = color_in;
    if (mode == TONE_LINEAR) {
        return saturate(exposure * color);
    } else if (mode == TONE_REINHARD) {
        color *= exposure;
        return saturate(color / (vec3<f32>(1.0) + color));
    } else if (mode == TONE_CINEON) {
        color *= exposure;
        color = max(vec3<f32>(0.0), color - 0.004);
        return pow((color * (6.2 * color + 0.5)) / (color * (6.2 * color + 1.7) + 0.06), vec3<f32>(2.2));
    } else if (mode == TONE_ACES) {
        let input = mat3x3<f32>(
            vec3<f32>(0.59719, 0.07600, 0.02840), vec3<f32>(0.35458, 0.90834, 0.13383),
            vec3<f32>(0.04823, 0.01566, 0.83777));
        let output = mat3x3<f32>(
            vec3<f32>(1.60475, -0.10208, -0.00327), vec3<f32>(-0.53108, 1.10813, -0.07276),
            vec3<f32>(-0.07367, -0.00605, 1.07602));
        color *= exposure / 0.6;
        color = output * rrt_and_odt_fit(input * color);
        return saturate(color);
    } else if (mode == TONE_AGX) {
        let to2020 = mat3x3<f32>(
            vec3<f32>(0.6274, 0.0691, 0.0164), vec3<f32>(0.3293, 0.9195, 0.0880), vec3<f32>(0.0433, 0.0113, 0.8956));
        let from2020 = mat3x3<f32>(
            vec3<f32>(1.6605, -0.1246, -0.0182), vec3<f32>(-0.5876, 1.1329, -0.1006), vec3<f32>(-0.0728, -0.0083, 1.1187));
        let inset = mat3x3<f32>(
            vec3<f32>(0.856627153315983, 0.137318972929847, 0.11189821299995),
            vec3<f32>(0.0951212405381588, 0.761241990602591, 0.0767994186031903),
            vec3<f32>(0.0482516061458583, 0.101439036467562, 0.811302368396859));
        let outset = mat3x3<f32>(
            vec3<f32>(1.1271005818144368, -0.1413297634984383, -0.14132976349843826),
            vec3<f32>(-0.11060664309660323, 1.157823702216272, -0.11060664309660294),
            vec3<f32>(-0.016493938717834573, -0.016493938717834257, 1.2519364065950405));
        let min_ev = -12.47393;
        let max_ev = 4.026069;
        color *= exposure;
        color = inset * (to2020 * color);
        color = max(color, vec3<f32>(1e-10));
        color = clamp((log2(color) - min_ev) / (max_ev - min_ev), vec3<f32>(0.0), vec3<f32>(1.0));
        color = outset * agx_contrast(color);
        color = pow(max(vec3<f32>(0.0), color), vec3<f32>(2.2));
        return clamp(from2020 * color, vec3<f32>(0.0), vec3<f32>(1.0));
    } else if (mode == TONE_NEUTRAL) {
        let start = 0.8 - 0.04;
        let desaturation = 0.15;
        color *= exposure;
        let x = min(color.r, min(color.g, color.b));
        let offset = select(0.04, x - 6.25 * x * x, x < 0.08);
        color -= offset;
        let peak = max(color.r, max(color.g, color.b));
        if (peak < start) {
            return color;
        }
        let d = 1.0 - start;
        let new_peak = 1.0 - d * d / (peak + d - start);
        color *= new_peak / peak;
        let g = 1.0 - 1.0 / (desaturation * (peak - new_peak) + 1.0);
        return mix(color, vec3<f32>(new_peak), g);
    }
    return color;
}

// ---------------------------------------------------------------- BRDFs

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

fn BRDF_GGX(L: vec3<f32>, V: vec3<f32>, N: vec3<f32>, f0: vec3<f32>, f90: f32, roughness: f32) -> vec3<f32> {
    let alpha = roughness * roughness;
    let H = normalize(L + V);
    let dotNL = saturate(dot(N, L));
    let dotNV = saturate(dot(N, V));
    let dotNH = saturate(dot(N, H));
    let dotVH = saturate(dot(V, H));
    return F_Schlick(f0, f90, dotVH) * (V_GGX_SmithCorrelated(alpha, dotNL, dotNV) * D_GGX(alpha, dotNH));
}

fn BRDF_BlinnPhong(L: vec3<f32>, V: vec3<f32>, N: vec3<f32>, specular: vec3<f32>, shininess: f32) -> vec3<f32> {
    let H = normalize(L + V);
    let dotNH = saturate(dot(N, H));
    let dotVH = saturate(dot(V, H));
    let D = RECIPROCAL_PI * (shininess * 0.5 + 1.0) * pow(dotNH, shininess);
    return F_Schlick(specular, 1.0, dotVH) * (0.25 * D);
}

fn D_Charlie(roughness: f32, dotNH: f32) -> f32 {
    let alpha = roughness * roughness;
    let inv_alpha = 1.0 / alpha;
    let cos2h = dotNH * dotNH;
    let sin2h = max(1.0 - cos2h, 0.0078125);
    return (2.0 + inv_alpha) * pow(sin2h, inv_alpha * 0.5) / (2.0 * PI);
}

fn V_Neubelt(dotNV: f32, dotNL: f32) -> f32 {
    return saturate(1.0 / (4.0 * (dotNL + dotNV - dotNL * dotNV)));
}

fn BRDF_Sheen(L: vec3<f32>, V: vec3<f32>, N: vec3<f32>, sheen_color: vec3<f32>, roughness: f32) -> vec3<f32> {
    let H = normalize(L + V);
    let dotNL = saturate(dot(N, L));
    let dotNV = saturate(dot(N, V));
    let dotNH = saturate(dot(N, H));
    return sheen_color * (D_Charlie(roughness, dotNH) * V_Neubelt(dotNV, dotNL));
}

// ---------------------------------------------------------------- environment

/// The environment's colour along world direction `dir` (equirectangular),
/// at mip `lod`.
fn env_sample(dir: vec3<f32>, lod: f32) -> vec3<f32> {
    let d = (F.env_rotation * vec4<f32>(dir, 0.0)).xyz;
    var uv = vec2<f32>(atan2(d.z, d.x) * 0.5 * RECIPROCAL_PI + 0.5,
                       asin(clamp(d.y, -1.0, 1.0)) * RECIPROCAL_PI + 0.5);
    if (F.env_flags.y != 0u) {
        uv.y = 1.0 - uv.y;
    }
    let texel = textureSampleLevel(t_env, s_env, uv, lod);
    return decode(texel, F.env_flags.z != 0u, F.env_flags.x != 0u).rgb;
}

/// three.js's DFGApprox.
fn dfg_approx(N: vec3<f32>, V: vec3<f32>, roughness: f32) -> vec2<f32> {
    let dotNV = saturate(dot(N, V));
    let c0 = vec4<f32>(-1.0, -0.0275, -0.572, 0.022);
    let c1 = vec4<f32>(1.0, 0.0425, 1.04, -0.04);
    let r = roughness * c0 + c1;
    let a004 = min(r.x * r.x, exp2(-9.28 * dotNV)) * r.x + r.y;
    return vec2<f32>(-1.04, 1.04) * a004 + r.zw;
}

// ---------------------------------------------------------------- shadows

/// How lit `world` is by `light`, 0 (shadowed) to 1, from its shadow map.
fn shadow_factor(light: Light, world: vec3<f32>, normal: vec3<f32>) -> f32 {
    let first = i32(light.shadow.x);
    if (first < 0) {
        return 1.0;
    }
    var layer = first;
    if (light.shadow2.y > 0.5) {
        // A point light: the cube face the point is in (+x -x +y -y +z -z).
        let d = world - light.position.xyz;
        let a = abs(d);
        if (a.x >= a.y && a.x >= a.z) {
            layer += select(1, 0, d.x > 0.0);
        } else if (a.y >= a.z) {
            layer += select(3, 2, d.y > 0.0);
        } else {
            layer += select(5, 4, d.z > 0.0);
        }
    }
    let p = world + normal * light.shadow.z;
    let clip = F.shadow_tiles[layer].matrix * vec4<f32>(p, 1.0);
    let ndc = clip.xyz / clip.w;
    let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (clip.w <= 0.0 || uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z > 1.0) {
        return 1.0;
    }
    let depth = ndc.z + light.shadow.y;
    let kind = u32(F.shadow_params.x);
    var lit = 0.0;
    if (kind == 0u) {
        lit = textureSampleCompareLevel(t_shadow, s_shadow, uv, layer, depth);
    } else {
        let step = F.shadow_params.y * max(light.shadow.w, 1.0);
        let reach = select(1, 2, kind == 2u);
        var count = 0.0;
        for (var y = -reach; y <= reach; y++) {
            for (var x = -reach; x <= reach; x++) {
                let o = vec2<f32>(f32(x), f32(y)) * step;
                lit += textureSampleCompareLevel(t_shadow, s_shadow, uv + o, layer, depth);
                count += 1.0;
            }
        }
        lit /= count;
    }
    return mix(1.0, lit, light.shadow2.x);
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

// ---------------------------------------------------------------- surface

@fragment
fn fs_main(in: VsOut, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    let kind = O.tex_flags.x;
    let present = O.tex_flags.y;
    let flags = O.flags.y;

    // Derivatives and the view, in uniform control flow.
    let dpx = dpdx(in.world);
    let dpy = dpdy(in.world);
    let uv_normal = slot_uv(in.uv, in.uv1, SLOT_NORMAL);
    let duvx = dpdx(uv_normal);
    let duvy = dpdy(uv_normal);
    let dnx = dpdx(in.normal);
    let dny = dpdy(in.normal);
    let orthographic = F.camera_pos.w > 0.5;
    let V = select(normalize(F.camera_pos.xyz - in.world), -F.camera_dir.xyz, orthographic);
    let face = select(-1.0, 1.0, front);

    // The geometric normal: interpolated or flat, flipped on back faces.
    var N = normalize(in.normal) * face;
    if (O.pbr.z > 0.5) {
        N = normalize(cross(dpx, dpy));
        if (dot(N, V) < 0.0) {
            N = -N;
        }
    }
    let geometry_normal = N;

    // Matcap looks its texture up by the view-space normal.
    let view_n = normalize((F.view * vec4<f32>(N, 0.0)).xyz);
    let view_pos = (F.view * vec4<f32>(in.world, 1.0)).xyz;
    let view_dir = normalize(-view_pos);
    let mx = normalize(vec3<f32>(view_dir.z, 0.0, -view_dir.x));
    let my = cross(view_dir, mx);
    let matcap_uv = vec2<f32>(dot(mx, view_n), dot(my, view_n)) * 0.495 + 0.5;
    let aux_uv = select(slot_uv(in.uv, in.uv1, SLOT_AUX), matcap_uv, kind == KIND_MATCAP);

    let c_map = sample_slot(t_map, s_map, slot_uv(in.uv, in.uv1, SLOT_MAP), SLOT_MAP);
    let c_normal = textureSample(t_normal, s_normal, flip_uv(uv_normal, SLOT_NORMAL));
    let c_aux = sample_slot(t_aux, s_aux, aux_uv, SLOT_AUX);
    let c_metal = sample_slot(t_metalness, s_metalness, slot_uv(in.uv, in.uv1, SLOT_METALNESS), SLOT_METALNESS);
    let c_ao = sample_slot(t_ao, s_ao, slot_uv(in.uv, in.uv1, SLOT_AO), SLOT_AO);
    let c_emissive = sample_slot(t_emissive, s_emissive, slot_uv(in.uv, in.uv1, SLOT_EMISSIVE), SLOT_EMISSIVE);
    let c_alpha = sample_slot(t_alpha, s_alpha, slot_uv(in.uv, in.uv1, SLOT_ALPHA), SLOT_ALPHA);

    // Diffuse colour and alpha.
    var diffuse = O.color * in.color;
    if (has_flag(present, SLOT_MAP)) {
        diffuse *= c_map;
    }
    if (has_flag(present, SLOT_ALPHA)) {
        diffuse.a *= c_alpha.g;
    }
    if (diffuse.a < O.emissive.w) {
        discard;
    }
    if (kind == KIND_LINE_DASHED) {
        let total = O.dash.x + O.dash.y;
        if ((in.uv.x * O.dash.z) % total > O.dash.x) {
            discard;
        }
    }
    let alpha = select(1.0, diffuse.a, (flags & FLAG_TRANSPARENT) != 0u);

    // Normal mapping in a tangent frame built from derivatives (three.js's
    // getTangentFrame), so no tangent attribute is needed.
    if (has_flag(present, SLOT_NORMAL) && kind != KIND_DEPTH) {
        var map_n = c_normal.xyz * 2.0 - 1.0;
        map_n = vec3<f32>(map_n.xy * O.extra.xy, map_n.z);
        let q1perp = cross(dpy, N);
        let q0perp = cross(N, dpx);
        let T = q1perp * duvx.x + q0perp * duvy.x;
        let B = q1perp * duvx.y + q0perp * duvy.y;
        let det = max(dot(T, T), dot(B, B));
        let scale = select(inverseSqrt(det), 0.0, det == 0.0);
        N = normalize(T * (map_n.x * scale) + B * (map_n.y * scale) + N * map_n.z);
    }

    var ao = 1.0;
    if (has_flag(present, SLOT_AO)) {
        ao = (c_ao.r - 1.0) * O.pbr.w + 1.0;
    }
    var emissive = O.emissive.rgb;
    if (has_flag(present, SLOT_EMISSIVE)) {
        emissive *= c_emissive.rgb;
    }

    if (kind == KIND_NORMAL) {
        let vn = normalize((F.view * vec4<f32>(N, 0.0)).xyz);
        return vec4<f32>((vn * 0.5 + vec3<f32>(0.5)) * alpha, alpha);
    }
    if (kind == KIND_DEPTH) {
        let g = 1.0 - in.clip.z;   // the fragment depth, [0, 1]
        return vec4<f32>(vec3<f32>(g) * diffuse.a, diffuse.a);
    }

    var rgb = diffuse.rgb;
    if (kind == KIND_BASIC || kind == KIND_LINE_DASHED) {
        rgb = diffuse.rgb * ao;
    } else if (kind == KIND_MATCAP) {
        rgb = diffuse.rgb * select(vec3<f32>(1.0), c_aux.rgb, has_flag(present, SLOT_AUX));
    } else {
        // Lit materials.
        let physical = kind == KIND_PHYSICAL;
        let pbr = kind == KIND_STANDARD || physical;
        var metalness = 0.0;
        var roughness = 1.0;
        var f0 = vec3<f32>(0.04);
        var f90 = 1.0;
        if (pbr) {
            metalness = saturate(O.pbr.y);
            roughness = O.pbr.x;
            if (has_flag(present, SLOT_AUX)) {
                roughness *= c_aux.g;
            }
            if (has_flag(present, SLOT_METALNESS)) {
                metalness *= c_metal.b;
            }
            // Specular anti-aliasing from the geometry's curvature.
            let dxy = max(abs(dnx), abs(dny));
            let geometry_roughness = max(max(dxy.x, dxy.y), dxy.z);
            roughness = min(max(roughness, 0.0525) + geometry_roughness, 1.0);
            if (physical) {
                let ior = O.extra.w;
                let r = (ior - 1.0) / (ior + 1.0);
                let dielectric = min(vec3<f32>(r * r) * O.physical2.rgb, vec3<f32>(1.0)) * O.physical0.w;
                f0 = mix(dielectric, diffuse.rgb, metalness);
                f90 = mix(O.physical0.w, 1.0, metalness);
            } else {
                f0 = mix(vec3<f32>(0.04), diffuse.rgb, metalness);
            }
        }
        let diffuse_color = diffuse.rgb * (1.0 - metalness);
        var specular_strength = 1.0;
        if (kind == KIND_PHONG && has_flag(present, SLOT_AUX)) {
            specular_strength = c_aux.r;
        }

        // Indirect: ambient and hemisphere light, occluded by the aoMap.
        var indirect = F.ambient.rgb;
        if (F.hemi_dir.w > 0.5) {
            let w = 0.5 * dot(N, F.hemi_dir.xyz) + 0.5;
            indirect += mix(F.hemi_ground.rgb, F.hemi_sky.rgb, w);
        }
        var diffuse_light = indirect * ao;
        var specular = vec3<f32>(0.0);
        var sheen = vec3<f32>(0.0);
        var clearcoat_spec = vec3<f32>(0.0);
        let clearcoat_roughness = clamp(O.physical0.y, 0.0525, 1.0);

        let count = min(u32(F.ambient.w), MAX_LIGHTS);
        for (var i = 0u; i < count; i++) {
            let light = F.lights[i];
            var L: vec3<f32>;
            var radiance = light.color.rgb;
            if (light.position.w == LIGHT_DIRECTIONAL) {
                L = light.direction.xyz;
            } else {
                let to_light = light.position.xyz - in.world;
                let d = length(to_light);
                L = to_light / max(d, 1e-6);
                radiance *= distance_attenuation(d, light.color.w, light.params.x);
                if (light.position.w == LIGHT_SPOT) {
                    let angle_cos = dot(L, light.direction.xyz);
                    radiance *= smoothstep(light.direction.w, light.params.y, angle_cos);
                }
            }
            if ((flags & FLAG_RECEIVE_SHADOW) != 0u) {
                radiance *= shadow_factor(light, in.world, normalize(in.normal) * face);
            }
            let dotNL = saturate(dot(N, L));
            var irradiance = dotNL * radiance;
            if (kind == KIND_TOON) {
                // The gradient map, or a two-tone step at 0.7.
                let coord = dot(N, L) * 0.5 + 0.5;
                var tone: vec3<f32>;
                if (has_flag(present, SLOT_AUX)) {
                    let size = textureDimensions(t_aux);
                    let x = clamp(i32(coord * f32(size.x)), 0, i32(size.x) - 1);
                    tone = decode(textureLoad(t_aux, vec2<i32>(x, 0), 0), has_flag(O.flags.x, SLOT_AUX),
                        has_flag(O.tex_flags.z, SLOT_AUX)).rgb;
                } else {
                    tone = mix(vec3<f32>(0.7), vec3<f32>(1.0), step(0.7, coord));
                }
                irradiance = tone * radiance;
            }
            diffuse_light += irradiance;
            if (kind == KIND_PHONG) {
                specular += irradiance * BRDF_BlinnPhong(L, V, N, O.specular.rgb, O.specular.w) * specular_strength;
            } else if (pbr) {
                specular += irradiance * BRDF_GGX(L, V, N, f0, f90, roughness);
                if (physical) {
                    sheen += irradiance * BRDF_Sheen(L, V, N, O.physical1.rgb, O.physical0.z);
                    let cc_irradiance = saturate(dot(geometry_normal, L)) * radiance;
                    clearcoat_spec += cc_irradiance * BRDF_GGX(L, V, geometry_normal, vec3<f32>(0.04), 1.0, clearcoat_roughness);
                }
            }
        }
        rgb = diffuse_light * (diffuse_color * RECIPROCAL_PI) + specular + emissive;
        if (pbr && F.env.x > 0.5) {
            // Image-based light (three.js's getIBLIrradiance / getIBLRadiance
            // and multiscattering), from the environment's mip chain.
            let intensity = F.env.y * O.extra.z;
            let max_lod = F.env.z;
            // Irradiance from a coarse level that still separates sky and
            // ground (the last levels average them away).
            let irradiance = PI * env_sample(N, max(0.0, max_lod - 1.0)) * intensity;
            let r = normalize(mix(reflect(-V, N), N, roughness * roughness));
            let radiance = env_sample(r, roughness * max_lod) * intensity;
            let fab = dfg_approx(N, V, roughness);
            let fss_ess = f0 * fab.x + vec3<f32>(f90 * fab.y);
            let ess = fab.x + fab.y;
            let ems = 1.0 - ess;
            let f_avg = f0 + (vec3<f32>(1.0) - f0) * 0.047619;
            let fms = fss_ess * f_avg / (vec3<f32>(1.0) - ems * f_avg);
            let multi = fms * ems;
            let total = fss_ess + multi;
            let cosine_irradiance = irradiance * RECIPROCAL_PI;
            let ibl_diffuse = diffuse_color * (1.0 - max(total.r, max(total.g, total.b))) * cosine_irradiance;
            let ibl_specular = radiance * fss_ess + multi * cosine_irradiance;
            rgb += (ibl_diffuse + ibl_specular) * ao;
        }
        if (physical) {
            let sc = O.physical1.rgb;
            rgb = rgb * (1.0 - 0.157 * max(sc.r, max(sc.g, sc.b))) + sheen;
            let fcc = F_Schlick(vec3<f32>(0.04), 1.0, saturate(dot(geometry_normal, V)));
            rgb = rgb * (1.0 - O.physical0.x * fcc) + clearcoat_spec * O.physical0.x;
        }
    }

    let linear_output = F.shadow_params.z > 0.5;
    if ((flags & FLAG_TONE_MAPPED) != 0u && !linear_output) {
        rgb = tone_map(rgb);
    }
    if ((flags & FLAG_FOG) != 0u && F.fog_color.w > 0.5) {
        var fog = 0.0;
        if (F.fog_color.w == FOG_LINEAR) {
            fog = smoothstep(F.fog_params.x, F.fog_params.y, in.view_depth);
        } else {
            let d = F.fog_params.z * in.view_depth;
            fog = 1.0 - exp(-d * d);
        }
        rgb = mix(rgb, F.fog_color.rgb, fog);
    }
    if (linear_output) {
        return vec4<f32>(rgb * alpha, alpha);
    }
    return vec4<f32>(linear_to_srgb(rgb) * alpha, alpha);
}

// ---------------------------------------------------------------- background

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
