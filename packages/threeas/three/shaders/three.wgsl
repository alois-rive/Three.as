// ThreeAS shaders (three/renderers/GPURenderer.as). Every mesh material is
// one pipeline family; the shading model is a uniform branch on O.flags.x.
//
// Group 0: the frame block (camera, lights, fog, tone mapping), the
//          environment, the shadow maps and the transmission texture.
// Group 1: the per-draw block (dynamic offset), bones, five extra maps.
// Group 2: the material's eight base textures.
// Group 3: their eight samplers (extra map k borrows sampler k).
// The background pass is three_background.wgsl. Rive allows 8 bindings a
// group; the web 16 textures a stage. Layouts are mirrored by hand in
// renderers/gpu/Layout.as; after editing, run tools/make_shader_chunks.py
// (three/shaders/lib/three_chunks.wgsl copies the shared parts).
//
// Lighting follows three.js: physical light intensities, BRDF_Lambert,
// BRDF_GGX, BRDF_BlinnPhong, Charlie sheen, clearcoat, its distance and spot
// attenuation, its tone mappers. Output is linear -> tone mapped -> fog ->
// sRGB, premultiplied.

const PI: f32 = 3.141592653589793;
const RECIPROCAL_PI: f32 = 0.3183098861837907;
const MAX_LIGHTS: u32 = 32u;

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
const KIND_SHADOW: u32 = 10u;
const KIND_DISTANCE: u32 = 11u;
const KIND_WIDE_LINE: u32 = 12u;

const SLOT_MAP: u32 = 0u;
const SLOT_NORMAL: u32 = 1u;
const SLOT_AUX: u32 = 2u;
const SLOT_METALNESS: u32 = 3u;
const SLOT_AO: u32 = 4u;
const SLOT_EMISSIVE: u32 = 5u;
const SLOT_ALPHA: u32 = 6u;
const SLOT_ENV: u32 = 7u;

const FLAG_VERTEX_COLORS: u32 = 1u;
const FLAG_FOG: u32 = 2u;
const FLAG_TRANSPARENT: u32 = 4u;
const FLAG_TONE_MAPPED: u32 = 8u;
const FLAG_RECEIVE_SHADOW: u32 = 16u;

const LIGHT_DIRECTIONAL: f32 = 0.0;
const LIGHT_POINT: f32 = 1.0;
const LIGHT_SPOT: f32 = 2.0;
const LIGHT_RECT: f32 = 3.0;   // direction.xyz half width, params.xyz half height

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
    shadow2: vec4<f32>,    // x intensity, y 1 for a point light (six layers), zw cascade view depth range (CSM)
};

const MAX_SHADOW_TILES: u32 = 24u;

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
    viewport: vec4<f32>,     // width, height (pixels), pixel ratio, 1 / log2(far + 1) (log depth)
    env: vec4<f32>,          // x 1 when there is an environment, y intensity, z max mip
    env_rotation: mat4x4<f32>,
    env_flags: vec4<u32>,    // x srgb, y flipY, z premultiplied
    shadow_params: vec4<f32>, // x type (0 basic, 1 PCF, 2 PCF soft), y texel size, z 1: linear HDR output
    probe: array<vec4<f32>, 9>,  // summed LightProbe SH coefficients (rgb)
    lights: array<Light, 32>,
    shadow_tiles: array<ShadowTile, 24>,
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
    uv_matrix: array<vec4<f32>, 16>,
    env: vec4<f32>,          // x 1: the material's envMap, y its max lod, z 1: prefiltered (PMREM)
    // Extra maps: six slots, roles mapped to them (see MaterialUniforms).
    x_uv: array<vec4<f32>, 12>,  // per slot: uv transform rows; row 0 w channel
    x_flags: vec4<u32>,      // present, sRGB, premultiplied, flipY (bit per slot)
    x_roles: vec4<u32>,      // x roles 0-7, y roles 8-15 (slot nibbles, 15 none), z 1: tangent attribute
    x_params: vec4<f32>,     // bumpScale, displacementScale, displacementBias, lightMapIntensity
    x_params2: vec4<f32>,    // normalMapType, combine, reflectivity, refractionRatio
    x_params3: vec4<f32>,    // clearcoatNormalScale xy, z 1: refraction mapping
    physical3: vec4<f32>,    // transmission, thickness, attenuationDistance, dispersion
    physical4: vec4<f32>,    // attenuationColor rgb, iridescence
    physical5: vec4<f32>,    // iridescenceIOR, thickness range min, max (nm), anisotropy
    physical6: vec4<f32>,    // anisotropy direction (cos, sin of anisotropyRotation)
    clip_planes: array<vec4<f32>, 8>,  // world: xyz normal, w constant (clipped where n.p + w < 0)
    clip: vec4<f32>,         // x union count, y total count
    misc0: vec4<f32>,        // MeshDistanceMaterial referencePosition xyz, nearDistance
    misc1: vec4<f32>,        // farDistance, y 1: alphaHash
    light_list: array<vec4<u32>, 2>,   // bytes: the count, then frame light indices
};

/// The `k`th light reaching this draw (an index into F.lights).
fn object_light(k: u32) -> u32 {
    let b = k + 1u;
    return (O.light_list[b / 16u][(b / 4u) % 4u] >> ((b % 4u) * 8u)) & 0xffu;
}

fn object_light_count() -> u32 {
    return O.light_list[0].x & 0xffu;
}

const ROLE_LIGHT: u32 = 0u;
const ROLE_BUMP: u32 = 1u;
const ROLE_DISPLACEMENT: u32 = 2u;
const ROLE_SPECULAR: u32 = 3u;
const ROLE_CLEARCOAT: u32 = 4u;
const ROLE_CLEARCOAT_ROUGHNESS: u32 = 5u;
const ROLE_CLEARCOAT_NORMAL: u32 = 6u;
const ROLE_SHEEN_COLOR: u32 = 7u;
const ROLE_SHEEN_ROUGHNESS: u32 = 8u;
const ROLE_SPECULAR_INTENSITY: u32 = 9u;
const ROLE_SPECULAR_COLOR: u32 = 10u;
const ROLE_TRANSMISSION: u32 = 11u;
const ROLE_THICKNESS: u32 = 12u;
const ROLE_IRIDESCENCE: u32 = 13u;
const ROLE_IRIDESCENCE_THICKNESS: u32 = 14u;
const ROLE_ANISOTROPY: u32 = 15u;

const MAX_BONES: u32 = 256u;

struct BonesU {
    bones: array<mat4x4<f32>, 256>,   // bone.matrixWorld x boneInverse
};

// Vertex data a draw reads from textures (morph targets, big skeletons),
// described by M. The textures borrow extra map slots (Layout.as):
// t_x4 morph deltas, t_x3 bone matrices, t_x2 InstancedMesh.morphTexture.
struct MorphU {
    // x: targets to loop over (the active ones, or every target of an
    //    instanced mesh), y: flags, z: morph texture width,
    // w: texels a target takes (vertex count x texels a vertex).
    info: vec4<u32>,
    // x: bone texture width.
    bones: vec4<u32>,
    // (target, weight) pairs, two a vec4: the targets with a weight.
    weights: array<vec4<f32>, 1022>,
};

const MORPH_NORMALS: u32 = 1u;
const MORPH_INSTANCED: u32 = 2u;
const BONE_TEXTURE: u32 = 4u;

@group(0) @binding(0) var<uniform> F: FrameU;
@group(0) @binding(1) var t_env: texture_2d<f32>;
@group(0) @binding(2) var s_env: sampler;
// The shadow maps, read with textureLoad: no comparison sampler, which
// Rive's web runtime cannot bind (shadow_compare filters as one would).
// Binding 4 is free.
@group(0) @binding(3) var t_shadow: texture_depth_2d_array;
// RectAreaLight's LTC tables: 32 x 32 texels, four pack2x16float words
// each (LTC_MAT_1 xy zw, LTC_MAT_2 xy zw).
struct LtcTable {
    t: array<vec4<u32>, 1024>,
};
@group(0) @binding(7) var<uniform> LTC: LtcTable;
// The opaque scene (linear HDR, mipmapped) for transmissive materials.
@group(0) @binding(5) var t_transmission: texture_2d<f32>;
@group(0) @binding(6) var s_transmission: sampler;
@group(1) @binding(0) var<uniform> O: ObjU;
@group(1) @binding(1) var<uniform> B: BonesU;
@group(1) @binding(7) var<uniform> M: MorphU;
@group(1) @binding(2) var t_x0: texture_2d<f32>;
@group(1) @binding(3) var t_x1: texture_2d<f32>;
@group(1) @binding(4) var t_x2: texture_2d<f32>;
@group(1) @binding(5) var t_x3: texture_2d<f32>;
@group(1) @binding(6) var t_x4: texture_2d<f32>;
@group(2) @binding(0) var t_map: texture_2d<f32>;
@group(2) @binding(1) var t_normal: texture_2d<f32>;
@group(2) @binding(2) var t_aux: texture_2d<f32>;
@group(2) @binding(3) var t_metalness: texture_2d<f32>;
@group(2) @binding(4) var t_ao: texture_2d<f32>;
@group(2) @binding(5) var t_emissive: texture_2d<f32>;
@group(2) @binding(6) var t_alpha: texture_2d<f32>;
@group(2) @binding(7) var t_envmap: texture_2d<f32>;
@group(3) @binding(0) var s_map: sampler;
@group(3) @binding(1) var s_normal: sampler;
@group(3) @binding(2) var s_aux: sampler;
@group(3) @binding(3) var s_metalness: sampler;
@group(3) @binding(4) var s_ao: sampler;
@group(3) @binding(5) var s_emissive: sampler;
@group(3) @binding(6) var s_alpha: sampler;
@group(3) @binding(7) var s_envmap: sampler;

// ---------------------------------------------------------------- variant
// What the fragment stage reads to pick its features: from the uniforms
// here (the uber-shader). tools/threeas_bake.sh replaces the lines between
// the markers with constant answers for one program key (three.js's
// getProgramCacheKey and #defines), so the compiler drops the branches and
// samples a draw does not need, keeps `discard` out of pipelines that never
// cut out, and unrolls the light loop. Keep these signatures: GPURenderer's
// programKey writes the key the baked answers come from.
// @variant-begin
fn v_kind() -> u32 { return O.tex_flags.x; }
fn v_present() -> u32 { return O.tex_flags.y; }
fn v_flags() -> u32 { return O.flags.y; }
fn v_role(role: u32) -> bool {
    let slot = role_slot(role);
    return slot < 5u && has_flag(O.x_flags.x, slot);
}
fn v_cutout() -> bool { return true; }
fn v_flat() -> bool { return O.pbr.z > 0.5; }
fn v_own_env() -> bool { return O.env.x > 0.5; }
fn v_scene_env() -> bool { return F.env.x > 0.5; }
fn v_fog() -> f32 { return F.fog_color.w; }
fn v_hemi() -> bool { return F.hemi_dir.w > 0.5; }
fn v_linear() -> bool { return F.shadow_params.z > 0.5; }
fn v_light_count() -> u32 { return object_light_count(); }
fn v_light_type(k: u32, light: Light) -> f32 { return light.position.w; }
// @variant-end

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
    @location(11) uv1: vec2<f32>,
    @location(12) tangent: vec4<f32>,
    @builtin(vertex_index) vertex: u32,
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
    @location(6) tangent: vec4<f32>,   // world xyz, w handedness
    @location(7) local: vec3<f32>,     // object-space position (alphaHash)
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
    let m = morph(in, 0u);
    return transform_vertex(m.position, m.normal, in, inst);
}

// Morph targets (three.js's morph target texture): the deltas of every
// target, relative to the base geometry, as rgba16float texels of t_x4,
// target-major: texel (target x M.info.w + vertex x stride + k), k 0 the
// position and 1 the normal (when the geometry morphs normals). An
// instanced mesh reads each instance's weights from its morphTexture
// (t_x2, a row per instance, weight k at texel k + 1): row `row`, which
// the vs_morph_instanced entry points read from a vertex attribute.
struct Morphed {
    position: vec3<f32>,
    normal: vec3<f32>,
};

fn morph_texel(index: u32) -> vec4<f32> {
    let w = max(M.info.z, 1u);
    return textureLoad(t_x4, vec2<i32>(i32(index % w), i32(index / w)), 0);
}

fn morph(in: VsIn, row: u32) -> Morphed {
    var out: Morphed;
    out.position = in.position;
    out.normal = in.normal;
    let count = M.info.x;
    if (count == 0u) {
        return out;
    }
    let normals = (M.info.y & MORPH_NORMALS) != 0u;
    let stride = select(1u, 2u, normals);
    let base = in.vertex * stride;
    let instanced = (M.info.y & MORPH_INSTANCED) != 0u;
    for (var k = 0u; k < count; k++) {
        var morph_target = k;
        var weight = 0.0;
        if (instanced) {
            weight = textureLoad(t_x2, vec2<i32>(i32(k + 1u), i32(row)), 0).r;
        } else {
            let pair = M.weights[k >> 1u];
            let odd = (k & 1u) == 1u;
            morph_target = u32(select(pair.x, pair.z, odd));
            weight = select(pair.y, pair.w, odd);
        }
        if (weight == 0.0) {
            continue;
        }
        let t = morph_target * M.info.w + base;
        out.position += morph_texel(t).xyz * weight;
        if (normals) {
            out.normal += morph_texel(t + 1u).xyz * weight;
        }
    }
    return out;
}

// displacementMap: the vertex moves along its normal by the map's red
// channel x displacementScale + displacementBias (three.js's
// displacementmap_vertex).
fn displace(position: vec3<f32>, normal: vec3<f32>, in: VsIn) -> vec3<f32> {
    let slot = role_slot(ROLE_DISPLACEMENT);
    if (slot >= 5u) {
        return position;
    }
    let h = x_sample_level(slot, x_slot_uv(slot, in.uv, in.uv1)).r;
    return position + normalize(normal) * (h * O.x_params.y + O.x_params.z);
}

@vertex
fn vs_displaced(in: VsIn, inst: InstanceIn) -> VsOut {
    let m = morph(in, 0u);
    return transform_vertex(displace(m.position, m.normal, in), m.normal, in, inst);
}

// InstancedMesh morphs (MORPH_INSTANCED): the instance's morphTexture row
// from a per-instance attribute, the renderer's 0, 1, 2 ... buffer at
// slot 7, which gives what the instance index builtin would. No entry
// point reads that builtin: naga emulates it on GLES with a plain uniform
// (its first-instance offset) that Rive's web runtime fails to query; see
// tools/check_glsl.py.
struct MorphRowIn {
    @location(13) row: f32,
};

@vertex
fn vs_morph_instanced(in: VsIn, inst: InstanceIn, r: MorphRowIn) -> VsOut {
    let m = morph(in, u32(r.row));
    return transform_vertex(m.position, m.normal, in, inst);
}

@vertex
fn vs_morph_instanced_displaced(in: VsIn, inst: InstanceIn, r: MorphRowIn) -> VsOut {
    let m = morph(in, u32(r.row));
    return transform_vertex(displace(m.position, m.normal, in), m.normal, in, inst);
}

// A bone matrix: from B (256 bones), or for bigger skeletons from t_x3,
// six rgba16float texels a bone: the three rows of its affine matrix, each
// as a half-float value plus the half-float remainder (hi + lo), so the
// sum keeps about 22 bits.
fn bone_texel(index: u32) -> vec4<f32> {
    let w = max(M.bones.x, 1u);
    return textureLoad(t_x3, vec2<i32>(i32(index % w), i32(index / w)), 0);
}

fn bone_matrix(i: u32) -> mat4x4<f32> {
    if ((M.info.y & BONE_TEXTURE) == 0u) {
        return B.bones[min(i, MAX_BONES - 1u)];
    }
    let o = i * 6u;
    let r0 = bone_texel(o) + bone_texel(o + 1u);
    let r1 = bone_texel(o + 2u) + bone_texel(o + 3u);
    let r2 = bone_texel(o + 4u) + bone_texel(o + 5u);
    return mat4x4<f32>(vec4<f32>(r0.x, r1.x, r2.x, 0.0), vec4<f32>(r0.y, r1.y, r2.y, 0.0),
        vec4<f32>(r0.z, r1.z, r2.z, 0.0), vec4<f32>(r0.w, r1.w, r2.w, 1.0));
}

// Skinned meshes: three.js's skinning (bindMatrixInverse x weighted bone
// matrices x bindMatrix) after the morph targets, before the usual
// transform.
fn skin_matrix(skin: SkinIn) -> mat4x4<f32> {
    let w = skin.weight;
    let i = vec4<u32>(skin.index);
    let bones = bone_matrix(i.x) * w.x + bone_matrix(i.y) * w.y + bone_matrix(i.z) * w.z + bone_matrix(i.w) * w.w;
    return O.bind_matrix_inverse * bones * O.bind_matrix;
}

@vertex
fn vs_skinned(in: VsIn, inst: InstanceIn, skin: SkinIn) -> VsOut {
    let mt = morph(in, 0u);
    let m = skin_matrix(skin);
    let p = (m * vec4<f32>(mt.position, 1.0)).xyz;
    let n = (m * vec4<f32>(mt.normal, 0.0)).xyz;
    return transform_vertex(p, n, in, inst);
}

@vertex
fn vs_skinned_displaced(in: VsIn, inst: InstanceIn, skin: SkinIn) -> VsOut {
    let mt = morph(in, 0u);
    let m = skin_matrix(skin);
    let p = (m * vec4<f32>(displace(mt.position, mt.normal, in), 1.0)).xyz;
    let n = (m * vec4<f32>(mt.normal, 0.0)).xyz;
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
    out.tangent = vec4<f32>((O.model * (im * vec4<f32>(in.tangent.xyz, 0.0))).xyz, in.tangent.w);
    out.local = position;
    out.uv = in.uv;
    out.uv1 = in.uv1;
    let vcolor = select(vec4<f32>(1.0), in.color, (O.flags.y & FLAG_VERTEX_COLORS) != 0u);
    out.color = vcolor * inst.color;
    out.view_depth = -(F.view * world).z;
    return out;
}

// Wide lines (three.js's LineMaterial): the base quad (position.x: side,
// position.y: < 0.5 start, > 0.5 end, beyond: caps) per segment instance
// (m0: start + distance, m1: end + distance, m2 / m3: colours), widened in
// screen space to `linewidth` pixels.
@vertex
fn vs_wideline(in: VsIn, inst: InstanceIn) -> VsOut {
    var out: VsOut;
    let mv = F.view * O.model;
    var start = mv * vec4<f32>(inst.m0.xyz, 1.0);
    var end = mv * vec4<f32>(inst.m1.xyz, 1.0);
    // A segment ending behind the camera is trimmed to the near plane.
    if (F.camera_pos.w < 0.5) {
        let near_z = -F.proj[3][2] / F.proj[2][2];
        if (start.z < 0.0 && end.z >= 0.0) {
            end = vec4<f32>(mix(start.xyz, end.xyz, (near_z - start.z) / (end.z - start.z)), 1.0);
        } else if (end.z < 0.0 && start.z >= 0.0) {
            start = vec4<f32>(mix(end.xyz, start.xyz, (near_z - end.z) / (start.z - end.z)), 1.0);
        }
    }
    let clip_start = F.proj * start;
    let clip_end = F.proj * end;
    let ndc_start = clip_start.xy / clip_start.w;
    let ndc_end = clip_end.xy / clip_end.w;
    let aspect = F.viewport.x / max(F.viewport.y, 1.0);
    var dir = ndc_end - ndc_start;
    dir.x *= aspect;
    dir = normalize(dir);
    var offset = vec2<f32>(dir.y, -dir.x);
    dir.x /= aspect;
    offset.x /= aspect;
    if (in.position.x < 0.0) {
        offset = -offset;
    }
    if (in.position.y < 0.0) {
        offset -= dir;
    } else if (in.position.y > 1.0) {
        offset += dir;
    }
    offset *= O.points.x * F.viewport.z / max(F.viewport.y, 1.0);
    let at_start = in.position.y < 0.5;
    var clip = select(clip_end, clip_start, at_start);
    clip = vec4<f32>(clip.xy + offset * clip.w, clip.zw);
    out.clip = clip;
    let world = O.model * vec4<f32>(select(inst.m1.xyz, inst.m0.xyz, at_start), 1.0);
    out.world = world.xyz;
    out.normal = -F.camera_dir.xyz;
    out.uv = in.uv;
    out.uv1 = vec2<f32>(select(inst.m1.w, inst.m0.w, at_start) * O.dash.z, 0.0);
    let c = select(inst.m3, inst.m2, at_start);
    out.color = select(vec4<f32>(1.0), vec4<f32>(c.rgb, 1.0), (O.flags.y & FLAG_VERTEX_COLORS) != 0u);
    out.tangent = vec4<f32>(0.0);
    out.local = in.position;
    out.view_depth = -select(end.z, start.z, at_start);
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
    out.tangent = vec4<f32>(0.0);
    out.local = p.position;
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
    out.tangent = vec4<f32>(0.0);
    out.local = vec3<f32>(corner, 0.0);
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

// ---------------------------------------------------------------- extra maps

/// The extra slot holding `role`'s texture (6 or more: none).
fn role_slot(role: u32) -> u32 {
    let word = select(O.x_roles.x, O.x_roles.y, role >= 8u);
    return (word >> ((role % 8u) * 4u)) & 0xfu;
}

/// An extra slot's uv (its texture.matrix and channel, then flipY).
fn x_slot_uv(slot: u32, uv: vec2<f32>, uv1: vec2<f32>) -> vec2<f32> {
    let s = min(slot, 4u);
    let r0 = O.x_uv[s * 2u];
    let r1 = O.x_uv[s * 2u + 1u];
    let p = vec3<f32>(select(uv, uv1, r0.w > 0.5), 1.0);
    let t = vec2<f32>(dot(r0.xyz, p), dot(r1.xyz, p));
    return select(t, vec2<f32>(t.x, 1.0 - t.y), has_flag(O.x_flags.w, s));
}

/// An extra slot's raw texel (any control flow: explicit gradients).
/// Extra slot k samples with base slot k's sampler (one sampler per
/// texture keeps the shader translatable to GLSL).
fn x_sample_grad(slot: u32, uv: vec2<f32>, dx: vec2<f32>, dy: vec2<f32>) -> vec4<f32> {
    switch slot {
        case 0u: { return textureSampleGrad(t_x0, s_map, uv, dx, dy); }
        case 1u: { return textureSampleGrad(t_x1, s_normal, uv, dx, dy); }
        case 2u: { return textureSampleGrad(t_x2, s_aux, uv, dx, dy); }
        case 3u: { return textureSampleGrad(t_x3, s_metalness, uv, dx, dy); }
        default: { return textureSampleGrad(t_x4, s_ao, uv, dx, dy); }
    }
}

/// Vertex stage: level 0.
fn x_sample_level(slot: u32, uv: vec2<f32>) -> vec4<f32> {
    switch slot {
        case 0u: { return textureSampleLevel(t_x0, s_map, uv, 0.0); }
        case 1u: { return textureSampleLevel(t_x1, s_normal, uv, 0.0); }
        case 2u: { return textureSampleLevel(t_x2, s_aux, uv, 0.0); }
        case 3u: { return textureSampleLevel(t_x3, s_metalness, uv, 0.0); }
        default: { return textureSampleLevel(t_x4, s_ao, uv, 0.0); }
    }
}

/// The uvs of the six extra slots and their screen derivatives, taken in
/// uniform control flow at the top of fs_main.
struct ExtraUVs {
    uv: array<vec2<f32>, 5>,
    dx: array<vec2<f32>, 5>,
    dy: array<vec2<f32>, 5>,
};

fn has_role(role: u32) -> bool {
    return v_role(role);
}

/// `role`'s texel as three.js sees it (straight alpha, linear colour), or
/// `fallback` when the material has no such map.
fn role_texel(role: u32, x: ExtraUVs, fallback: vec4<f32>) -> vec4<f32> {
    if (!v_role(role)) {
        return fallback;
    }
    let slot = role_slot(role);
    let t = x_sample_grad(slot, x.uv[slot], x.dx[slot], x.dy[slot]);
    return decode(t, has_flag(O.x_flags.z, slot), has_flag(O.x_flags.y, slot));
}

/// The bump map's height differences along the screen axes (three.js's
/// dHdxy_fwd).
fn bump_dhdxy(x: ExtraUVs) -> vec2<f32> {
    let slot = role_slot(ROLE_BUMP);
    let uv = x.uv[slot];
    let dx = x.dx[slot];
    let dy = x.dy[slot];
    let s = O.x_params.x;
    let hll = s * x_sample_grad(slot, uv, dx, dy).x;
    let dbx = s * x_sample_grad(slot, uv + dx, dx, dy).x - hll;
    let dby = s * x_sample_grad(slot, uv + dy, dx, dy).x - hll;
    return vec2<f32>(dbx, dby);
}

/// three.js's clipping: outside any union plane, or outside every
/// intersection plane (clipIntersection).
fn clipped(world: vec3<f32>) -> bool {
    let unions = u32(O.clip.x);
    let total = u32(O.clip.y);
    for (var i = 0u; i < unions; i++) {
        let p = O.clip_planes[i];
        if (dot(p.xyz, world) + p.w < 0.0) {
            return true;
        }
    }
    if (total > unions) {
        var all = true;
        for (var i = unions; i < total; i++) {
            let p = O.clip_planes[i];
            all = all && (dot(p.xyz, world) + p.w < 0.0);
        }
        return all;
    }
    return false;
}

// three.js's alphahash_pars_fragment.
fn hash2d(v: vec2<f32>) -> f32 {
    return fract(1.0e4 * sin(17.0 * v.x + 0.1 * v.y) * (0.1 + abs(sin(13.0 * v.y + v.x))));
}

fn hash3d(v: vec3<f32>) -> f32 {
    return hash2d(vec2<f32>(hash2d(v.xy), v.z));
}

/// The alpha hash threshold at `p` (object space), from its screen
/// derivatives (call in uniform control flow).
fn alpha_hash_threshold(p: vec3<f32>, dx: vec3<f32>, dy: vec3<f32>) -> f32 {
    let max_deriv = max(length(dx), length(dy));
    let pix_scale = 1.0 / (0.05 * max(max_deriv, 1e-8));
    let scales = vec2<f32>(exp2(floor(log2(pix_scale))), exp2(ceil(log2(pix_scale))));
    let a2 = vec2<f32>(hash3d(floor(scales.x * p)), hash3d(floor(scales.y * p)));
    let lerp_factor = fract(log2(pix_scale));
    let xv = (1.0 - lerp_factor) * a2.x + lerp_factor * a2.y;
    let a = max(min(lerp_factor, 1.0 - lerp_factor), 1e-6);
    let cases = vec3<f32>(xv * xv / (2.0 * a * (1.0 - a)), (xv - 0.5 * a) / (1.0 - a),
        1.0 - ((1.0 - xv) * (1.0 - xv) / (2.0 * a * (1.0 - a))));
    var threshold = cases.z;
    if (xv < 1.0 - a) {
        threshold = select(cases.y, cases.x, xv < a);
    }
    return clamp(threshold, 1.0e-6, 1.0);
}

/// three.js's getShadowMask: the product of every shadow on this point
/// (1: lit), for ShadowMaterial.
fn shadow_mask(world: vec3<f32>, normal: vec3<f32>) -> f32 {
    var mask = 1.0;
    let count = min(u32(F.ambient.w), MAX_LIGHTS);
    for (var i = 0u; i < count; i++) {
        mask *= shadow_factor(F.lights[i], world, normal);
    }
    return mask;
}

/// Shadow passes of cut-out casters (alphaTest, alphaHash), clipped too.
@fragment
fn fs_shadow_cutout(in: VsOut) {
    var threshold = 0.0;
    if (O.misc1.y > 0.5) {
        threshold = alpha_hash_threshold(in.local, dpdx(in.local), dpdy(in.local));
    }
    let present = O.tex_flags.y;
    var a = O.color.a;
    if (has_flag(present, SLOT_MAP)) {
        a *= sample_slot(t_map, s_map, slot_uv(in.uv, in.uv1, SLOT_MAP), SLOT_MAP).a;
    }
    if (has_flag(present, SLOT_ALPHA)) {
        a *= sample_slot(t_alpha, s_alpha, slot_uv(in.uv, in.uv1, SLOT_ALPHA), SLOT_ALPHA).g;
    }
    if (a < O.emissive.w || (O.misc1.y > 0.5 && a < threshold) || clipped(in.world)) {
        discard;
    }
}

/// Shadow passes of clipShadows casters.
@fragment
fn fs_clip(in: VsOut) {
    if (clipped(in.world)) {
        discard;
    }
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
    // Not `gl`: GLSL reserves every gl_ name, and the GL backend escapes
    // `gl` to `gl_1` (a compile error on WebGL2).
    let vis_v = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    let vis_l = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    return 0.5 / max(vis_v + vis_l, 1e-6);
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

// ---------------------------------------------------------------- physical extensions

/// GGX with three.js's iridescence (the thin-film Fresnel mixed in) and
/// anisotropy (alphaT along T, roughness^2 along B).
fn BRDF_GGX_physical(L: vec3<f32>, V: vec3<f32>, N: vec3<f32>, f0: vec3<f32>, f90: f32, roughness: f32,
                     iridescence: f32, irid_fresnel: vec3<f32>, anisotropy: f32, alpha_t: f32,
                     T: vec3<f32>, B: vec3<f32>) -> vec3<f32> {
    let alpha = roughness * roughness;
    let H = normalize(L + V);
    let dotNL = saturate(dot(N, L));
    let dotNV = saturate(dot(N, V));
    let dotNH = saturate(dot(N, H));
    let dotVH = saturate(dot(V, H));
    var F = F_Schlick(f0, f90, dotVH);
    F = mix(F, irid_fresnel, iridescence);
    if (anisotropy <= 0.0) {
        return F * (V_GGX_SmithCorrelated(alpha, dotNL, dotNV) * D_GGX(alpha, dotNH));
    }
    let dotTL = dot(T, L);
    let dotTV = dot(T, V);
    let dotTH = dot(T, H);
    let dotBL = dot(B, L);
    let dotBV = dot(B, V);
    let dotBH = dot(B, H);
    let vis_v = dotNL * length(vec3<f32>(alpha_t * dotTV, alpha * dotBV, dotNV));
    let vis_l = dotNV * length(vec3<f32>(alpha_t * dotTL, alpha * dotBL, dotNL));
    let vis = saturate(0.5 / (vis_v + vis_l));
    let a2 = alpha_t * alpha;
    let v = vec3<f32>(alpha * dotTH, alpha_t * dotBH, a2 * dotNH);
    let w2 = a2 / dot(v, v);
    let D = RECIPROCAL_PI * a2 * w2 * w2;
    return F * (vis * D);
}

const XYZ_TO_REC709 = mat3x3<f32>(
    vec3<f32>(3.2404542, -0.9692660, 0.0556434),
    vec3<f32>(-1.5371385, 1.8760108, -0.2040259),
    vec3<f32>(-0.4985314, 0.0415560, 1.0572252));

fn ior_to_fresnel0(transmitted: vec3<f32>, incident: f32) -> vec3<f32> {
    let r = (transmitted - vec3<f32>(incident)) / (transmitted + vec3<f32>(incident));
    return r * r;
}

fn eval_sensitivity(opd: f32, shift: vec3<f32>) -> vec3<f32> {
    let phase = 2.0 * PI * opd * 1.0e-9;
    let val = vec3<f32>(5.4856e-13, 4.4201e-13, 5.2481e-13);
    let pos = vec3<f32>(1.6810e+06, 1.7953e+06, 2.2084e+06);
    let vr = vec3<f32>(4.3278e+09, 9.3046e+09, 6.6121e+09);
    var xyz = val * sqrt(2.0 * PI * vr) * cos(pos * phase + shift) * exp(-(phase * phase) * vr);
    xyz.x += 9.7470e-14 * sqrt(2.0 * PI * 4.5282e+09) * cos(2.2399e+06 * phase + shift.x) * exp(-4.5282e+09 * phase * phase);
    xyz /= 1.0685e-7;
    return XYZ_TO_REC709 * xyz;
}

/// three.js's evalIridescence (Belcour and Barla's thin film).
fn eval_iridescence(outside_ior: f32, eta2: f32, cos_theta1: f32, thickness: f32, base_f0: vec3<f32>) -> vec3<f32> {
    let film_ior = mix(outside_ior, eta2, smoothstep(0.0, 0.03, thickness));
    let sin_theta2_sq = (outside_ior / film_ior) * (outside_ior / film_ior) * (1.0 - cos_theta1 * cos_theta1);
    let cos_theta2_sq = 1.0 - sin_theta2_sq;
    if (cos_theta2_sq < 0.0) {
        return vec3<f32>(1.0);
    }
    let cos_theta2 = sqrt(cos_theta2_sq);
    let r0 = ((film_ior - outside_ior) / (film_ior + outside_ior)) * ((film_ior - outside_ior) / (film_ior + outside_ior));
    let r12 = r0 + (1.0 - r0) * pow(1.0 - cos_theta1, 5.0);
    let t121 = 1.0 - r12;
    let phi12 = select(0.0, PI, film_ior < outside_ior);
    let phi21 = PI - phi12;
    let sf0 = sqrt(clamp(base_f0, vec3<f32>(0.0), vec3<f32>(0.9999)));
    let base_ior = (vec3<f32>(1.0) + sf0) / (vec3<f32>(1.0) - sf0);
    let r1 = ior_to_fresnel0(base_ior, film_ior);
    let r23 = r1 + (vec3<f32>(1.0) - r1) * pow(1.0 - cos_theta2, 5.0);
    let phi23 = select(vec3<f32>(0.0), vec3<f32>(PI), base_ior < vec3<f32>(film_ior));
    let opd = 2.0 * film_ior * thickness * cos_theta2;
    let phi = vec3<f32>(phi21) + phi23;
    let r123 = clamp(r12 * r23, vec3<f32>(1e-5), vec3<f32>(0.9999));
    let sr123 = sqrt(r123);
    let rs = t121 * t121 * r23 / (vec3<f32>(1.0) - r123);
    var I = vec3<f32>(r12) + rs;
    var cm = rs - vec3<f32>(t121);
    for (var m = 1; m <= 2; m++) {
        cm *= sr123;
        I += cm * 2.0 * eval_sensitivity(f32(m) * opd, f32(m) * phi);
    }
    return max(I, vec3<f32>(0.0));
}

/// three.js's Schlick_to_F0.
fn schlick_to_f0(f: vec3<f32>, f90: f32, dot_vh: f32) -> vec3<f32> {
    let x = clamp(1.0 - dot_vh, 0.0, 1.0);
    let x2 = x * x;
    let x5 = clamp(x * x2 * x2, 0.0, 0.9999);
    return (f - vec3<f32>(f90) * x5) / (1.0 - x5);
}

/// Light through a transmissive volume (three.js's getIBLVolumeRefraction):
/// the opaque scene along the refracted ray, blurred by roughness,
/// attenuated (Beer's law) and tinted, per colour channel with dispersion.
fn volume_refraction(n: vec3<f32>, v: vec3<f32>, roughness: f32, diffuse_color: vec3<f32>, f0: vec3<f32>,
                     f90: f32, world: vec3<f32>, ior: f32, thickness: f32, dispersion: f32) -> vec4<f32> {
    let scale = vec3<f32>(length(O.model[0].xyz), length(O.model[1].xyz), length(O.model[2].xyz));
    let size = vec2<f32>(textureDimensions(t_transmission));
    let lod = log2(max(size.x, 1.0)) * roughness * clamp(ior * 2.0 - 2.0, 0.0, 1.0);
    let half_spread = (ior - 1.0) * 0.025 * dispersion;
    let iors = vec3<f32>(ior - half_spread, ior, ior + half_spread);
    var light = vec3<f32>(0.0);
    var alpha = 0.0;
    var ray_len = 0.0;
    for (var i = 0; i < 3; i++) {
        let ray = normalize(refract(-v, normalize(n), 1.0 / iors[i])) * thickness * scale;
        ray_len = length(ray);
        let clip = F.view_proj * vec4<f32>(world + ray, 1.0);
        let ndc = clip.xy / clip.w;
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        let t = textureSampleLevel(t_transmission, s_transmission, uv, lod);
        light[i] = t[i];
        alpha += t.a / 3.0;
        if (dispersion <= 0.0) {
            light = t.rgb;
            alpha = t.a;
            break;
        }
    }
    var att = vec3<f32>(1.0);
    let dist = O.physical3.z;
    if (dist > 0.0 && dist < 1e30) {
        let coefficient = -log(max(O.physical4.rgb, vec3<f32>(1e-4))) / dist;
        att = exp(-coefficient * ray_len);
    }
    let transmittance = diffuse_color * att;
    let fab = dfg_approx(n, v, roughness);
    let fr = f0 * fab.x + vec3<f32>(f90 * fab.y);
    let tf = (transmittance.r + transmittance.g + transmittance.b) / 3.0;
    return vec4<f32>((vec3<f32>(1.0) - fr) * transmittance * light, 1.0 - (1.0 - alpha) * tf);
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
    if (v_own_env()) {
        // The material's own envMap (equirectangular; cube maps arrive
        // converted).
        var uv = vec2<f32>(atan2(dir.z, dir.x) * 0.5 * RECIPROCAL_PI + 0.5,
                           asin(clamp(dir.y, -1.0, 1.0)) * RECIPROCAL_PI + 0.5);
        uv = flip_uv(uv, SLOT_ENV);
        let texel = textureSampleLevel(t_envmap, s_envmap, uv, lod);
        return decode(texel, has_flag(O.flags.x, SLOT_ENV), has_flag(O.tex_flags.z, SLOT_ENV)).rgb;
    }
    let d = (F.env_rotation * vec4<f32>(dir, 0.0)).xyz;
    var uv = vec2<f32>(atan2(d.z, d.x) * 0.5 * RECIPROCAL_PI + 0.5,
                       asin(clamp(d.y, -1.0, 1.0)) * RECIPROCAL_PI + 0.5);
    if (F.env_flags.y != 0u) {
        uv.y = 1.0 - uv.y;
    }
    let texel = textureSampleLevel(t_env, s_env, uv, lod);
    return decode(texel, F.env_flags.z != 0u, F.env_flags.x != 0u).rgb;
}

/// three.js's envmap_fragment for Basic, Lambert and Phong: the envMap
/// along the reflected (or refracted) view ray, combined with the lit
/// colour by `combine`, `reflectivity` and the specular strength.
fn env_combine(outgoing: vec3<f32>, world: vec3<f32>, n: vec3<f32>, specular_strength: f32) -> vec3<f32> {
    let camera_to_frag = select(normalize(world - F.camera_pos.xyz), F.camera_dir.xyz, F.camera_pos.w > 0.5);
    var dir = reflect(camera_to_frag, n);
    if (O.x_params3.z > 0.5) {
        dir = refract(camera_to_frag, n, O.x_params2.w);
    }
    let env = env_sample(dir, 0.0);
    let k = specular_strength * O.x_params2.z;
    let combine = u32(O.x_params2.y);
    if (combine == 1u) {
        return mix(outgoing, env, k);
    }
    if (combine == 2u) {
        return outgoing + env * k;
    }
    return mix(outgoing, outgoing * env, k);
}

// ---------------------------------------------------------------- area lights and probes

struct LtcSample {
    m1: vec4<f32>,
    m2: vec4<f32>,
};

/// A half float's value (unpack2x16float needs a capability Rive's
/// validator does not enable).
fn half_bits(h: u32) -> f32 {
    let sign = (h >> 15u) & 1u;
    let e = (h >> 10u) & 0x1fu;
    let m = h & 0x3ffu;
    var v: f32;
    if (e == 0u) {
        v = f32(m) * 5.960464477539063e-8;
    } else if (e == 31u) {
        v = 65504.0;
    } else {
        v = bitcast<f32>(((e + 112u) << 23u) | (m << 13u));
    }
    return select(v, -v, sign == 1u);
}

fn halves(w: u32) -> vec2<f32> {
    return vec2<f32>(half_bits(w & 0xffffu), half_bits(w >> 16u));
}

fn ltc_texel(x: i32, y: i32) -> LtcSample {
    let w = LTC.t[clamp(y, 0, 31) * 32 + clamp(x, 0, 31)];
    var s: LtcSample;
    s.m1 = vec4<f32>(halves(w.x), halves(w.y));
    s.m2 = vec4<f32>(halves(w.z), halves(w.w));
    return s;
}

/// The LTC fit at (roughness, sqrt(1 - n.v)), bilinear (three.js's LTC_Uv
/// and texture lookups).
fn ltc_lookup(N: vec3<f32>, V: vec3<f32>, roughness: f32) -> LtcSample {
    let p = vec2<f32>(roughness, sqrt(1.0 - saturate(dot(N, V)))) * 31.0;
    let i = vec2<i32>(floor(p));
    let f = p - floor(p);
    let a = ltc_texel(i.x, i.y);
    let b = ltc_texel(i.x + 1, i.y);
    let c = ltc_texel(i.x, i.y + 1);
    let d = ltc_texel(i.x + 1, i.y + 1);
    var s: LtcSample;
    s.m1 = mix(mix(a.m1, b.m1, f.x), mix(c.m1, d.m1, f.x), f.y);
    s.m2 = mix(mix(a.m2, b.m2, f.x), mix(c.m2, d.m2, f.x), f.y);
    return s;
}

fn ltc_edge(v1: vec3<f32>, v2: vec3<f32>) -> vec3<f32> {
    let x = dot(v1, v2);
    let y = abs(x);
    let a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
    let b = 3.4175940 + (4.1616724 + y) * y;
    let v = a / b;
    let theta_sintheta = select(0.5 * inverseSqrt(max(1.0 - x * x, 1e-7)) - v, v, x > 0.0);
    return cross(v1, v2) * theta_sintheta;
}

/// three.js's LTC_Evaluate: the polygon's form factor through `m_inv`.
fn ltc_evaluate(N: vec3<f32>, V: vec3<f32>, P: vec3<f32>, m_inv: mat3x3<f32>, c0: vec3<f32>, c1: vec3<f32>,
                c2: vec3<f32>, c3: vec3<f32>) -> f32 {
    let v1 = c1 - c0;
    let v2 = c3 - c0;
    if (dot(cross(v1, v2), P - c0) < 0.0) {
        return 0.0;
    }
    let T1 = normalize(V - N * dot(V, N));
    let T2 = -cross(N, T1);
    let m = m_inv * transpose(mat3x3<f32>(T1, T2, N));
    let p0 = normalize(m * (c0 - P));
    let p1 = normalize(m * (c1 - P));
    let p2 = normalize(m * (c2 - P));
    let p3 = normalize(m * (c3 - P));
    let f = ltc_edge(p0, p1) + ltc_edge(p1, p2) + ltc_edge(p2, p3) + ltc_edge(p3, p0);
    let l = length(f);
    return max((l * l + f.z) / (l + 1.0), 0.0);
}

/// three.js's shGetIrradianceAt over the summed light probes.
fn probe_irradiance(n: vec3<f32>) -> vec3<f32> {
    let c = F.probe;
    var r = c[0].rgb * 0.886227;
    r += c[1].rgb * 2.0 * 0.511664 * n.y;
    r += c[2].rgb * 2.0 * 0.511664 * n.z;
    r += c[3].rgb * 2.0 * 0.511664 * n.x;
    r += c[4].rgb * 2.0 * 0.429043 * n.x * n.y;
    r += c[5].rgb * 2.0 * 0.429043 * n.y * n.z;
    r += c[6].rgb * (0.743125 * n.z * n.z - 0.247708);
    r += c[7].rgb * 2.0 * 0.429043 * n.x * n.z;
    r += c[8].rgb * 0.429043 * (n.x * n.x - n.y * n.y);
    return r;
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

/// Texel `p` of shadow map `layer` (clamped to its edge) compared with
/// `depth`: 1 when `depth` <= the stored depth (lit), else 0.
fn shadow_texel(p: vec2<i32>, size: vec2<i32>, layer: i32, depth: f32) -> f32 {
    let q = clamp(p, vec2<i32>(0), size - vec2<i32>(1));
    return select(0.0, 1.0, depth <= textureLoad(t_shadow, q, layer, 0));
}

/// A comparison sample of shadow map `layer` at `uv`, as a linear
/// lessEqual comparison sampler with clamp-to-edge filters it: the 2x2
/// texels around `uv` compared, then weighted bilinearly.
fn shadow_compare(uv: vec2<f32>, size: vec2<i32>, layer: i32, depth: f32) -> f32 {
    let t = uv * vec2<f32>(size) - 0.5;
    let i = vec2<i32>(floor(t));
    let f = t - floor(t);
    let a = shadow_texel(i, size, layer, depth);
    let b = shadow_texel(i + vec2<i32>(1, 0), size, layer, depth);
    let c = shadow_texel(i + vec2<i32>(0, 1), size, layer, depth);
    let d = shadow_texel(i + vec2<i32>(1, 1), size, layer, depth);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

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
    let size = vec2<i32>(textureDimensions(t_shadow));
    var lit = 0.0;
    if (kind == 0u) {
        lit = shadow_compare(uv, size, layer, depth);
    } else {
        // A (2 reach + 1)^2 grid of comparison samples, `step` apart.
        let reach = select(1, 2, kind == 2u);
        let count = f32((2 * reach + 1) * (2 * reach + 1));
        if (light.shadow.w <= 1.0) {
            // Samples one texel apart share their texels: compare each
            // texel of the (2 reach + 2)^2 block once, weighted by the
            // samples it is in: per axis 1 - f for the first row (column),
            // f for the last, (1 - f) + f for those between.
            let t = uv * vec2<f32>(size) - 0.5;
            let i = vec2<i32>(floor(t));
            let f = t - floor(t);
            for (var y = -reach; y <= reach + 1; y++) {
                let wy = select(0.0, 1.0 - f.y, y <= reach) + select(0.0, f.y, y > -reach);
                for (var x = -reach; x <= reach + 1; x++) {
                    let wx = select(0.0, 1.0 - f.x, x <= reach) + select(0.0, f.x, x > -reach);
                    lit += wx * wy * shadow_texel(i + vec2<i32>(x, y), size, layer, depth);
                }
            }
        } else {
            let step = F.shadow_params.y * light.shadow.w;
            for (var y = -reach; y <= reach; y++) {
                for (var x = -reach; x <= reach; x++) {
                    lit += shadow_compare(uv + vec2<f32>(f32(x), f32(y)) * step, size, layer, depth);
                }
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

// The colour of a fragment (fs_main, fs_main_logdepth).
fn surface(in: VsOut, front: bool) -> vec4<f32> {
    let kind = v_kind();
    let present = v_present();
    let flags = v_flags();
    let physical_kind = kind == KIND_PHYSICAL;
    let pbr_kind = kind == KIND_STANDARD || physical_kind;
    let has_normal_map = has_flag(present, SLOT_NORMAL) && kind != KIND_DEPTH;
    let needs_world_deriv = v_flat() || (has_normal_map && O.x_params2.x <= 0.5)
        || (has_role(ROLE_BUMP) && kind != KIND_DEPTH)
        || (physical_kind && (has_role(ROLE_CLEARCOAT_NORMAL) || O.physical5.w != 0.0));

    // Derivatives and samples, each guarded by uniform flags before any discard.
    var dpx = vec3<f32>(0.0);
    var dpy = vec3<f32>(0.0);
    if (needs_world_deriv) {
        dpx = dpdx(in.world);
        dpy = dpdy(in.world);
    }
    var duvx = vec2<f32>(0.0);
    var duvy = vec2<f32>(0.0);
    var c_normal = vec4<f32>(0.5, 0.5, 1.0, 1.0);
    if (has_normal_map) {
        let uv_normal = slot_uv(in.uv, in.uv1, SLOT_NORMAL);
        if (O.x_params2.x <= 0.5) {
            duvx = dpdx(uv_normal);
            duvy = dpdy(uv_normal);
        }
        c_normal = textureSample(t_normal, s_normal, flip_uv(uv_normal, SLOT_NORMAL));
    }
    var dnx = vec3<f32>(0.0);
    var dny = vec3<f32>(0.0);
    if (pbr_kind) {
        dnx = dpdx(in.normal);
        dny = dpdy(in.normal);
    }
    var duv0x = vec2<f32>(0.0);
    var duv0y = vec2<f32>(0.0);
    if (physical_kind && O.physical5.w != 0.0) {
        duv0x = dpdx(in.uv);
        duv0y = dpdy(in.uv);
    }
    var hash_threshold = 0.0;
    if (v_cutout() && O.misc1.y > 0.5) {
        hash_threshold = alpha_hash_threshold(in.local, dpdx(in.local), dpdy(in.local));
    }
    var x: ExtraUVs;
    if (O.x_flags.x != 0u) {
        for (var s = 0u; s < 5u; s++) {
            if (has_flag(O.x_flags.x, s)) {
                let xuv = x_slot_uv(s, in.uv, in.uv1);
                x.uv[s] = xuv;
                x.dx[s] = dpdx(xuv);
                x.dy[s] = dpdy(xuv);
            }
        }
    }
    let orthographic = F.camera_pos.w > 0.5;
    let V = select(normalize(F.camera_pos.xyz - in.world), -F.camera_dir.xyz, orthographic);
    let face = select(-1.0, 1.0, front);

    // The geometric normal: interpolated or flat, flipped on back faces.
    let interp_n = normalize(in.normal) * face;
    var N = interp_n;
    if (v_flat()) {
        N = normalize(cross(dpx, dpy));
        if (dot(N, V) < 0.0) {
            N = -N;
        }
    }
    let geometry_normal = N;

    var c_map = vec4<f32>(1.0);
    if (has_flag(present, SLOT_MAP)) {
        c_map = sample_slot(t_map, s_map, slot_uv(in.uv, in.uv1, SLOT_MAP), SLOT_MAP);
    }
    var c_aux = vec4<f32>(1.0);
    if (has_flag(present, SLOT_AUX) && kind != KIND_TOON) {
        var aux_uv: vec2<f32>;
        if (kind == KIND_MATCAP) {
            // Matcap looks its texture up by the view-space normal.
            let view_n = normalize((F.view * vec4<f32>(N, 0.0)).xyz);
            let view_pos = (F.view * vec4<f32>(in.world, 1.0)).xyz;
            let view_dir = normalize(-view_pos);
            let mx = normalize(vec3<f32>(view_dir.z, 0.0, -view_dir.x));
            let my = cross(view_dir, mx);
            aux_uv = vec2<f32>(dot(mx, view_n), dot(my, view_n)) * 0.495 + 0.5;
        } else {
            aux_uv = slot_uv(in.uv, in.uv1, SLOT_AUX);
        }
        c_aux = sample_slot(t_aux, s_aux, aux_uv, SLOT_AUX);
    }
    var c_metal = vec4<f32>(1.0);
    if (pbr_kind && has_flag(present, SLOT_METALNESS)) {
        c_metal = sample_slot(t_metalness, s_metalness, slot_uv(in.uv, in.uv1, SLOT_METALNESS), SLOT_METALNESS);
    }
    var c_ao = vec4<f32>(1.0);
    if (has_flag(present, SLOT_AO)) {
        c_ao = sample_slot(t_ao, s_ao, slot_uv(in.uv, in.uv1, SLOT_AO), SLOT_AO);
    }
    var c_emissive = vec4<f32>(1.0);
    if (has_flag(present, SLOT_EMISSIVE)) {
        c_emissive = sample_slot(t_emissive, s_emissive, slot_uv(in.uv, in.uv1, SLOT_EMISSIVE), SLOT_EMISSIVE);
    }
    var c_alpha = vec4<f32>(1.0);
    if (has_flag(present, SLOT_ALPHA)) {
        c_alpha = sample_slot(t_alpha, s_alpha, slot_uv(in.uv, in.uv1, SLOT_ALPHA), SLOT_ALPHA);
    }

    // Diffuse colour and alpha.
    var diffuse = O.color * in.color;
    if (has_flag(present, SLOT_MAP)) {
        diffuse *= c_map;
    }
    if (has_flag(present, SLOT_ALPHA)) {
        diffuse.a *= c_alpha.g;
    }
    if (v_cutout() && (diffuse.a < O.emissive.w || clipped(in.world) || (O.misc1.y > 0.5 && diffuse.a < hash_threshold))) {
        discard;
    }
    if (kind == KIND_SHADOW) {
        // ShadowMaterial: colour where the shadows are.
        var mask = 1.0;
        if ((flags & FLAG_RECEIVE_SHADOW) != 0u) {
            mask = shadow_mask(in.world, interp_n);
        }
        let sa = O.color.a * (1.0 - mask);
        let sc = select(linear_to_srgb(O.color.rgb), O.color.rgb, v_linear());
        return vec4<f32>(sc * sa, sa);
    }
    if (kind == KIND_DISTANCE) {
        let dist = saturate((length(in.world - O.misc0.xyz) - O.misc0.w) / (O.misc1.x - O.misc0.w));
        return vec4<f32>(vec3<f32>(dist) * diffuse.a, diffuse.a);
    }
    if (kind == KIND_WIDE_LINE) {
        // Round caps, and dashes along the line distance.
        let u = in.uv;
        if (O.misc1.z > 0.5) {
            if (u.y < -1.0 || u.y > 1.0) {
                discard;
            }
            if ((in.uv1.x + O.dash.w) % (O.dash.x + O.dash.y) > O.dash.x) {
                discard;
            }
        }
        if (abs(u.y) > 1.0) {
            let b = select(u.y + 1.0, u.y - 1.0, u.y > 0.0);
            if (u.x * u.x + b * b > 1.0) {
                discard;
            }
        }
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
        if (O.x_params2.x > 0.5) {
            // ObjectSpaceNormalMap.
            N = normalize((O.normal_matrix * vec4<f32>(map_n, 0.0)).xyz) * face;
        } else {
            map_n = vec3<f32>(map_n.xy * O.extra.xy, map_n.z);
            if (O.x_roles.z != 0u && dot(in.tangent.xyz, in.tangent.xyz) > 0.0) {
                // The tangent attribute (three.js's USE_TANGENT).
                let T = normalize(in.tangent.xyz - N * dot(N, in.tangent.xyz)) * face;
                let B = cross(normalize(in.normal), normalize(in.tangent.xyz)) * in.tangent.w * face;
                N = normalize(T * map_n.x + B * map_n.y + N * map_n.z);
            } else {
                let q1perp = cross(dpy, N);
                let q0perp = cross(N, dpx);
                let T = q1perp * duvx.x + q0perp * duvy.x;
                let B = q1perp * duvx.y + q0perp * duvy.y;
                let det = max(dot(T, T), dot(B, B));
                let scale = select(inverseSqrt(det), 0.0, det == 0.0);
                N = normalize(T * (map_n.x * scale) + B * (map_n.y * scale) + N * map_n.z);
            }
        }
    } else if (has_role(ROLE_BUMP) && kind != KIND_DEPTH) {
        // three.js's perturbNormalArb.
        let dh = bump_dhdxy(x);
        let sx = normalize(dpx);
        let sy = normalize(dpy);
        let r1 = cross(sy, N);
        let r2 = cross(N, sx);
        let fdet = dot(sx, r1) * face;
        let grad = sign(fdet) * (dh.x * r1 + dh.y * r2);
        N = normalize(abs(fdet) * N - grad);
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
    // Basic, Lambert: specularMap; Phong's is the aux slot.
    var specular_strength = role_texel(ROLE_SPECULAR, x, vec4<f32>(1.0)).r;
    if (kind == KIND_PHONG && has_flag(present, SLOT_AUX)) {
        specular_strength = c_aux.r;
    }
    let light_map = role_texel(ROLE_LIGHT, x, vec4<f32>(0.0)).rgb * O.x_params.w;
    if (kind == KIND_BASIC || kind == KIND_LINE_DASHED || kind == KIND_WIDE_LINE) {
        // three.js: a lightMap replaces the unit indirect light.
        let indirect = select(vec3<f32>(1.0), light_map * RECIPROCAL_PI, has_role(ROLE_LIGHT));
        rgb = diffuse.rgb * indirect * ao;
        if (kind == KIND_BASIC && v_own_env()) {
            rgb = env_combine(rgb, in.world, N, specular_strength);
        }
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
                let spec_intensity = O.physical0.w * role_texel(ROLE_SPECULAR_INTENSITY, x, vec4<f32>(1.0)).a;
                let spec_color = O.physical2.rgb * role_texel(ROLE_SPECULAR_COLOR, x, vec4<f32>(1.0)).rgb;
                let dielectric = min(vec3<f32>(r * r) * spec_color, vec3<f32>(1.0)) * spec_intensity;
                f0 = mix(dielectric, diffuse.rgb, metalness);
                f90 = mix(spec_intensity, 1.0, metalness);
            } else {
                f0 = mix(vec3<f32>(0.04), diffuse.rgb, metalness);
            }
        }
        let diffuse_color = diffuse.rgb * (1.0 - metalness);

        // Physical extensions: iridescence and anisotropy.
        var iridescence = 0.0;
        var irid_fresnel = vec3<f32>(0.0);
        var anisotropy = 0.0;
        var alpha_t = roughness * roughness;
        var aniso_t = vec3<f32>(1.0, 0.0, 0.0);
        var aniso_b = vec3<f32>(0.0, 1.0, 0.0);
        if (physical) {
            iridescence = O.physical4.w * role_texel(ROLE_IRIDESCENCE, x, vec4<f32>(1.0)).r;
            if (iridescence > 0.0) {
                var film = O.physical5.z;
                if (has_role(ROLE_IRIDESCENCE_THICKNESS)) {
                    film = mix(O.physical5.y, O.physical5.z, role_texel(ROLE_IRIDESCENCE_THICKNESS, x, vec4<f32>(1.0)).g);
                }
                irid_fresnel = eval_iridescence(1.0, O.physical5.x, saturate(dot(N, V)), film, f0);
            }
            var av = O.physical6.xy * O.physical5.w;
            if (has_role(ROLE_ANISOTROPY)) {
                let polar = role_texel(ROLE_ANISOTROPY, x, vec4<f32>(1.0, 0.5, 1.0, 1.0)).rgb;
                let m = mat2x2<f32>(vec2<f32>(av.x, av.y), vec2<f32>(-av.y, av.x));
                av = m * normalize(2.0 * polar.rg - vec2<f32>(1.0)) * polar.b;
            }
            let strength = length(av);
            if (strength > 0.0) {
                let dir = av / strength;
                anisotropy = saturate(strength);
                alpha_t = mix(roughness * roughness, 1.0, anisotropy * anisotropy);
                // The surface's tangent frame: its tangents, else derivatives.
                var T0: vec3<f32>;
                var B0: vec3<f32>;
                if (O.x_roles.z != 0u && dot(in.tangent.xyz, in.tangent.xyz) > 0.0) {
                    T0 = normalize(in.tangent.xyz);
                    B0 = cross(normalize(in.normal), T0) * in.tangent.w;
                } else {
                    let q1perp = cross(dpy, N);
                    let q0perp = cross(N, dpx);
                    T0 = q1perp * duv0x.x + q0perp * duv0y.x;
                    B0 = q1perp * duv0x.y + q0perp * duv0y.y;
                    let det = max(dot(T0, T0), dot(B0, B0));
                    let sc = select(inverseSqrt(det), 0.0, det == 0.0);
                    T0 *= sc;
                    B0 *= sc;
                }
                if (dot(T0, T0) < 1e-12 || dot(B0, B0) < 1e-12) {
                    // No uvs (or degenerate ones): any frame around the normal.
                    let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(N.y) > 0.99);
                    T0 = normalize(cross(up, N));
                    B0 = cross(N, T0);
                }
                aniso_t = T0 * dir.x + B0 * dir.y;
                aniso_b = B0 * dir.x - T0 * dir.y;
            }
        }

        // Indirect: ambient, hemisphere and lightMap light, occluded by the aoMap.
        var indirect = F.ambient.rgb + light_map + probe_irradiance(N);
        if (v_hemi()) {
            let w = 0.5 * dot(N, F.hemi_dir.xyz) + 0.5;
            indirect += mix(F.hemi_ground.rgb, F.hemi_sky.rgb, w);
        }
        var diffuse_light = indirect * ao;
        var specular = vec3<f32>(0.0);
        var sheen = vec3<f32>(0.0);
        var clearcoat_spec = vec3<f32>(0.0);
        var sheen_color = vec3<f32>(0.0);
        var sheen_roughness = 1.0;
        var clearcoat = 0.0;
        var clearcoat_roughness = 0.0525;
        var cc_n = geometry_normal;
        if (physical) {
            sheen_color = O.physical1.rgb * role_texel(ROLE_SHEEN_COLOR, x, vec4<f32>(1.0)).rgb;
            sheen_roughness = clamp(O.physical0.z * role_texel(ROLE_SHEEN_ROUGHNESS, x, vec4<f32>(1.0)).a, 0.07, 1.0);
            clearcoat = O.physical0.x * role_texel(ROLE_CLEARCOAT, x, vec4<f32>(1.0)).r;
            clearcoat_roughness = clamp(O.physical0.y * role_texel(ROLE_CLEARCOAT_ROUGHNESS, x, vec4<f32>(1.0)).g,
                0.0525, 1.0);
            // The clearcoat's own normal: the geometry normal, or its normal map
            // (tangent space, from derivatives).
            if (has_role(ROLE_CLEARCOAT_NORMAL)) {
                var m = role_texel(ROLE_CLEARCOAT_NORMAL, x, vec4<f32>(0.5, 0.5, 1.0, 1.0)).xyz * 2.0 - 1.0;
                m = vec3<f32>(m.xy * O.x_params3.xy, m.z);
                let slot = role_slot(ROLE_CLEARCOAT_NORMAL);
                let q1perp = cross(dpy, cc_n);
                let q0perp = cross(cc_n, dpx);
                let T = q1perp * x.dx[slot].x + q0perp * x.dy[slot].x;
                let B = q1perp * x.dx[slot].y + q0perp * x.dy[slot].y;
                let det = max(dot(T, T), dot(B, B));
                let sc = select(inverseSqrt(det), 0.0, det == 0.0);
                cc_n = normalize(T * (m.x * sc) + B * (m.y * sc) + cc_n * m.z);
            }
        }
        let has_sheen = physical && (sheen_color.r + sheen_color.g + sheen_color.b) > 0.0;
        let has_cc = physical && clearcoat > 0.0;

        // The lights reaching this draw (culled per object by the renderer).
        let count = v_light_count();
        for (var k = 0u; k < count; k++) {
            let light = F.lights[object_light(k)];
            // A CSM cascade lights only the view depths it covers.
            if (light.shadow2.w > 0.0 && (in.view_depth < light.shadow2.z || in.view_depth >= light.shadow2.w)) {
                continue;
            }
            if (v_light_type(k, light) == LIGHT_RECT) {
                // RectAreaLight (three.js's RE_Direct_RectArea_Physical):
                // physically based materials only.
                if (pbr) {
                    let hw = light.direction.xyz;
                    let hh = light.params.xyz;
                    let lp = light.position.xyz;
                    let c0 = lp + hw - hh;
                    let c1 = lp - hw - hh;
                    let c2 = lp - hw + hh;
                    let c3 = lp + hw + hh;
                    let t = ltc_lookup(N, V, roughness);
                    let m_inv = mat3x3<f32>(vec3<f32>(t.m1.x, 0.0, t.m1.y), vec3<f32>(0.0, 1.0, 0.0),
                        vec3<f32>(t.m1.z, 0.0, t.m1.w));
                    let fresnel = f0 * t.m2.x + (vec3<f32>(1.0) - f0) * t.m2.y;
                    specular += light.color.rgb * fresnel * ltc_evaluate(N, V, in.world, m_inv, c0, c1, c2, c3);
                    // diffuse_light is multiplied by diffuse_color / PI below.
                    diffuse_light += light.color.rgb * PI * ltc_evaluate(N, V, in.world,
                        mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 0.0, 1.0)),
                        c0, c1, c2, c3);
                }
                continue;
            }
            var L: vec3<f32>;
            var radiance = light.color.rgb;
            if (v_light_type(k, light) == LIGHT_DIRECTIONAL) {
                L = light.direction.xyz;
            } else {
                let to_light = light.position.xyz - in.world;
                let d = length(to_light);
                L = to_light / max(d, 1e-6);
                radiance *= distance_attenuation(d, light.color.w, light.params.x);
                if (v_light_type(k, light) == LIGHT_SPOT) {
                    let angle_cos = dot(L, light.direction.xyz);
                    radiance *= smoothstep(light.direction.w, light.params.y, angle_cos);
                }
            }
            let dotNL = saturate(dot(N, L));
            let dot_cc = select(0.0, saturate(dot(cc_n, L)), has_cc);
            if ((flags & FLAG_RECEIVE_SHADOW) != 0u && (dotNL > 0.0 || kind == KIND_TOON || dot_cc > 0.0)) {
                radiance *= shadow_factor(light, in.world, interp_n);
            }
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
            if (dotNL > 0.0) {
                if (kind == KIND_PHONG) {
                    specular += irradiance * BRDF_BlinnPhong(L, V, N, O.specular.rgb, O.specular.w) * specular_strength;
                } else if (physical) {
                    specular += irradiance * BRDF_GGX_physical(L, V, N, f0, f90, roughness, iridescence, irid_fresnel,
                        anisotropy, alpha_t, aniso_t, aniso_b);
                    if (has_sheen) {
                        sheen += irradiance * BRDF_Sheen(L, V, N, sheen_color, sheen_roughness);
                    }
                } else if (pbr) {
                    specular += irradiance * BRDF_GGX(L, V, N, f0, f90, roughness);
                }
            }
            if (has_cc && dot_cc > 0.0) {
                let cc_irradiance = dot_cc * radiance;
                clearcoat_spec += cc_irradiance * BRDF_GGX(L, V, cc_n, vec3<f32>(0.04), 1.0, clearcoat_roughness);
            }
        }
        var total_diffuse = diffuse_light * (diffuse_color * RECIPROCAL_PI);
        var total_specular = specular;
        let own_env = v_own_env();
        if (pbr && (own_env || v_scene_env())) {
            // Image-based light (three.js's getIBLIrradiance / getIBLRadiance
            // and multiscattering), from the environment's mip chain:
            // envMap, else scene.environment (with environmentIntensity).
            let intensity = select(F.env.y, 1.0, own_env) * O.extra.z;
            let max_lod = select(F.env.z, O.env.y, own_env);
            let prefiltered = select(F.env.w, O.env.z, own_env) > 0.5;
            // Irradiance: the PMREM at roughness 1 (three.js's
            // getIBLIrradiance); from a plain mip chain, a coarse level that
            // still separates sky and ground.
            let irradiance = PI * env_sample(N, select(max(0.0, max_lod - 1.0), max_lod, prefiltered)) * intensity;
            // Anisotropy reflects about a bent normal (three.js's
            // getIBLAnisotropyRadiance).
            var ibl_n = N;
            if (anisotropy > 0.0) {
                let bent = normalize(cross(cross(aniso_b, V), aniso_b));
                let k = 1.0 - anisotropy * (1.0 - roughness);
                ibl_n = normalize(mix(bent, N, k * k * k * k));
            }
            let r = normalize(mix(reflect(-V, ibl_n), ibl_n, roughness * roughness));
            let radiance = env_sample(r, roughness * max_lod) * intensity;
            let fab = dfg_approx(N, V, roughness);
            let f0_ibl = mix(f0, schlick_to_f0(irid_fresnel, 1.0, saturate(dot(N, V))), iridescence);
            let fss_ess = f0_ibl * fab.x + vec3<f32>(f90 * fab.y);
            let ess = fab.x + fab.y;
            let ems = 1.0 - ess;
            let f_avg = f0_ibl + (vec3<f32>(1.0) - f0_ibl) * 0.047619;
            let fms = fss_ess * f_avg / (vec3<f32>(1.0) - ems * f_avg);
            let multi = fms * ems;
            let total = fss_ess + multi;
            let cosine_irradiance = irradiance * RECIPROCAL_PI;
            let ibl_diffuse = diffuse_color * (1.0 - max(total.r, max(total.g, total.b))) * cosine_irradiance;
            let ibl_specular = radiance * fss_ess + multi * cosine_irradiance;
            total_diffuse += ibl_diffuse * ao;
            total_specular += ibl_specular * ao;
            if (physical && clearcoat > 0.0) {
                // The clearcoat reflects the environment too (three.js's
                // clearcoatSpecularIndirect).
                let rc = reflect(-V, cc_n);
                let cc_radiance = env_sample(normalize(mix(rc, cc_n, clearcoat_roughness * clearcoat_roughness)),
                    clearcoat_roughness * max_lod) * intensity;
                let cfab = dfg_approx(cc_n, V, clearcoat_roughness);
                clearcoat_spec += cc_radiance * (vec3<f32>(0.04) * cfab.x + vec3<f32>(cfab.y)) * ao;
            }
        }
        if (physical && O.physical3.x > 0.0) {
            // Transmission: the opaque scene through the volume replaces
            // the diffuse light (three.js's transmission_fragment).
            let transmission = O.physical3.x * role_texel(ROLE_TRANSMISSION, x, vec4<f32>(1.0)).r;
            let thickness = O.physical3.y * role_texel(ROLE_THICKNESS, x, vec4<f32>(1.0)).g;
            let tr = volume_refraction(N, V, roughness, diffuse_color, f0, f90, in.world, O.extra.w, thickness,
                O.physical3.w);
            total_diffuse = mix(total_diffuse, tr.rgb, transmission);
        }
        rgb = total_diffuse + total_specular + emissive;
        if (physical) {
            let sc = sheen_color;
            rgb = rgb * (1.0 - 0.157 * max(sc.r, max(sc.g, sc.b))) + sheen;
            let fcc = F_Schlick(vec3<f32>(0.04), 1.0, saturate(dot(cc_n, V)));
            rgb = rgb * (1.0 - clearcoat * fcc) + clearcoat_spec * clearcoat;
        }
        if (!pbr && v_own_env()) {
            // Lambert and Phong envMap (three.js's envmap_fragment).
            rgb = env_combine(rgb, in.world, N, specular_strength);
        }
    }

    let linear_output = v_linear();
    if ((flags & FLAG_TONE_MAPPED) != 0u && !linear_output) {
        rgb = tone_map(rgb);
    }
    if ((flags & FLAG_FOG) != 0u && v_fog() > 0.5) {
        var fog = 0.0;
        if (v_fog() == FOG_LINEAR) {
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

@fragment
fn fs_main(in: VsOut, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    return surface(in, front);
}

// logarithmicDepthBuffer: three.js's logdepthbuf_fragment, log2(1 + w)
// over log2(1 + far) (the window depth as is for orthographic cameras).
struct LogDepthOut {
    @location(0) color: vec4<f32>,
    @builtin(frag_depth) depth: f32,
};

@fragment
fn fs_main_logdepth(in: VsOut, @builtin(front_facing) front: bool) -> LogDepthOut {
    var out: LogDepthOut;
    out.color = surface(in, front);
    let fc = F.viewport.w;
    out.depth = select(in.clip.z, log2(1.0 + in.view_depth) * fc, fc > 0.0);
    return out;
}
