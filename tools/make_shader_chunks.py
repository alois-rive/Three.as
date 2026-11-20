"""Writes packages/threeas/three/shaders/lib/three_chunks.wgsl, three.js's
ShaderChunk for ThreeAS: the renderer's frame and object blocks, bindings and helpers,
extracted from three/shaders/three.wgsl so they never drift. WGSL has no
#include: copy what a ShaderMaterial needs from that file (with
`lights: true` the material gets every frame binding). Also writes
packages/gallery/examples/custom_shader/lit.wgsl, an example assembled
from the same chunks, and the engine's ShaderSourceHash.as.

    python3 tools/make_shader_chunks.py
    python3 tools/make_shader_chunks.py --check   # exit 1 if any generated file is stale
"""
import hashlib, os, re, sys

check_only = "--check" in sys.argv[1:]
for a in sys.argv[1:]:
    if a != "--check":
        sys.exit("usage: python3 tools/make_shader_chunks.py [--check]")

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
engine = os.path.join(root, "packages", "threeas")
gallery = os.path.join(root, "packages", "gallery")
src = open(os.path.join(engine, "three", "shaders", "three.wgsl")).read()

def block(name, kind):
    m = re.search(r"^%s %s\b.*?^};?\n" % (kind, re.escape(name)), src, re.S | re.M)
    assert m, name
    # keep the doc comment lines right above
    start = m.start()
    lines = src[:start].split("\n")
    doc = []
    while lines and lines[-2 if lines[-1] == "" else -1].startswith("///"):
        doc.insert(0, lines.pop(-2 if lines[-1] == "" else -1))
    return ("\n".join(doc) + "\n" if doc else "") + m.group(0)

def const(name):
    m = re.search(r"^const %s\b.*;\n" % re.escape(name), src, re.M)
    assert m, name
    return m.group(0)

def binding(name):
    m = re.search(r"^@group\(\d\) @binding\(\d\) var(<uniform>)? %s:.*;\n" % re.escape(name), src, re.M)
    assert m, name
    return m.group(0)

consts = ["PI", "RECIPROCAL_PI", "MAX_LIGHTS", "MAX_SHADOW_TILES", "FLAG_VERTEX_COLORS", "FLAG_FOG",
          "FLAG_TRANSPARENT", "FLAG_TONE_MAPPED", "FLAG_RECEIVE_SHADOW", "LIGHT_DIRECTIONAL", "LIGHT_POINT",
          "LIGHT_SPOT", "FOG_LINEAR", "FOG_EXP2", "TONE_LINEAR", "TONE_REINHARD", "TONE_CINEON", "TONE_ACES",
          "TONE_AGX", "TONE_NEUTRAL"]
structs = ["Light", "ShadowTile", "FrameU", "ObjU", "LtcTable"]
bindings = ["F", "t_env", "s_env", "t_shadow", "LTC", "t_transmission", "s_transmission", "O"]
functions = ["srgb_to_linear", "linear_to_srgb", "rrt_and_odt_fit", "agx_contrast", "tone_map",
             "distance_attenuation", "shadow_texel", "shadow_compare", "shadow_factor"]

helpers = '''
// ---------------------------------------------------------------- helpers

/// Light `i` at `world`: the direction towards it and its radiance there
/// (distance and spot attenuation, and its shadow when the object
/// receives shadows; `normal` offsets the shadow lookup).
struct DirectLight {
    L: vec3<f32>,
    radiance: vec3<f32>,
};

fn three_direct_light(i: u32, world: vec3<f32>, normal: vec3<f32>) -> DirectLight {
    let light = F.lights[i];
    var out: DirectLight;
    out.radiance = light.color.rgb;
    if (light.position.w == LIGHT_DIRECTIONAL) {
        out.L = light.direction.xyz;
    } else {
        let to_light = light.position.xyz - world;
        let d = length(to_light);
        out.L = to_light / max(d, 1e-6);
        out.radiance *= distance_attenuation(d, light.color.w, light.params.x);
        if (light.position.w == LIGHT_SPOT) {
            out.radiance *= smoothstep(light.direction.w, light.params.y, dot(out.L, light.direction.xyz));
        }
    }
    if ((O.flags.y & FLAG_RECEIVE_SHADOW) != 0u) {
        out.radiance *= shadow_factor(light, world, normal);
    }
    return out;
}

/// The number of lights in the frame block.
fn three_light_count() -> u32 {
    return min(u32(F.ambient.w), MAX_LIGHTS);
}

/// Ambient plus hemisphere light along `N` (indirect irradiance).
fn three_ambient(N: vec3<f32>) -> vec3<f32> {
    var irradiance = F.ambient.rgb;
    if (F.hemi_dir.w > 0.5) {
        irradiance += mix(F.hemi_ground.rgb, F.hemi_sky.rgb, 0.5 * dot(N, F.hemi_dir.xyz) + 0.5);
    }
    return irradiance;
}

/// The renderer's output: tone mapping (when the object is tone mapped and
/// the target is not HDR), fog at view depth `depth`, sRGB, premultiplied.
fn three_output(rgb_in: vec3<f32>, alpha: f32, depth: f32) -> vec4<f32> {
    var rgb = rgb_in;
    let linear_output = F.shadow_params.z > 0.5;
    if ((O.flags.y & FLAG_TONE_MAPPED) != 0u && !linear_output) {
        rgb = tone_map(rgb);
    }
    if ((O.flags.y & FLAG_FOG) != 0u && F.fog_color.w > 0.5) {
        var fog = 0.0;
        if (F.fog_color.w == FOG_LINEAR) {
            fog = smoothstep(F.fog_params.x, F.fog_params.y, depth);
        } else {
            let d = F.fog_params.z * depth;
            fog = 1.0 - exp(-d * d);
        }
        rgb = mix(rgb, F.fog_color.rgb, fog);
    }
    if (linear_output) {
        return vec4<f32>(rgb * alpha, alpha);
    }
    return vec4<f32>(linear_to_srgb(rgb) * alpha, alpha);
}

/// Touches every frame binding, so automatic layouts keep them (a
/// `lights: true` material is bound with all of them).
fn three_keep_frame_bindings() -> f32 {
    let e = textureSampleLevel(t_env, s_env, vec2<f32>(0.0), 0.0).r;
    let s = textureLoad(t_shadow, vec2<i32>(0), 0, 0);
    let t = textureSampleLevel(t_transmission, s_transmission, vec2<f32>(0.0), 0.0).r;
    let l = f32(LTC.t[0].x & 1u);
    return (e + s + t + l) * 0.0;
}
'''

header = '''// GENERATED by tools/make_shader_chunks.py from three/shaders/three.wgsl:
// do not edit. three.js's ShaderChunk for ThreeAS: copy what a
// ShaderMaterial needs (WGSL has no #include). With `lights: true` the
// material is bound with every frame binding below (group 0: 0-3, 5-7); keep
// them all declared and used (three_keep_frame_bindings). The object block
// (group 1, 0) is the renderer's ObjU; declaring a prefix of it is fine.
// The material's own uniforms and textures go in group 2 (see
// three/materials/ShaderMaterial.as).
'''

body = "\n".join(const(c).rstrip() for c in consts) + "\n\n"
body += "\n".join(block(s, "struct") for s in structs) + "\n"
body += "".join(binding(b) for b in bindings) + "\n"
body += "\n".join(block(f, "fn") for f in functions)
body += helpers

lib = header + "\n" + body + '''
// ---------------------------------------------------------------- a minimal pair

struct ChunkOut {
    @builtin(position) clip: vec4<f32>,
};

@vertex
fn chunk_vs(@location(0) position: vec3<f32>) -> ChunkOut {
    var out: ChunkOut;
    out.clip = F.view_proj * O.model * vec4<f32>(position, 1.0);
    return out;
}

@fragment
fn chunk_fs(in: ChunkOut) -> @location(0) vec4<f32> {
    return three_output(vec3<f32>(1.0), 1.0, 0.0) + three_keep_frame_bindings();
}
'''
outputs = []
outputs.append((
    os.path.join(engine, "three", "shaders", "lib", "three_chunks.wgsl"),
    "packages/threeas/three/shaders/lib/three_chunks.wgsl",
    lib,
))

lit = '''// GENERATED by tools/make_shader_chunks.py (the chunks, from three.wgsl)
// plus the shader below: a ShaderMaterial with `lights: true`
// (examples/custom_shader/custom_shader.as). Lambert diffuse with rim light and bands
// (a toon look), lit by the scene's lights, shadows and fog through the
// chunks.

''' + body + '''
// ---------------------------------------------------------------- the material

struct Uniforms {
    color: vec3<f32>,
    bands: f32,
    rim: vec3<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) depth: f32,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> VsOut {
    var out: VsOut;
    let world = O.model * vec4<f32>(position, 1.0);
    out.clip = F.view_proj * world;
    out.world = world.xyz;
    out.normal = (O.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    out.depth = -(F.view * world).z;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let N = normalize(in.normal);
    let V = normalize(F.camera_pos.xyz - in.world);
    var irradiance = three_ambient(N);
    for (var i = 0u; i < three_light_count(); i++) {
        let l = three_direct_light(i, in.world, N);
        let ndl = saturate(dot(N, l.L));
        // Quantised into bands.
        let banded = floor(ndl * u.bands + 0.5) / max(u.bands, 1.0);
        irradiance += banded * l.radiance;
    }
    var rgb = u.color * irradiance * RECIPROCAL_PI;
    rgb += u.rim * pow(1.0 - saturate(dot(N, V)), 3.0);
    return three_output(rgb, 1.0, in.depth) + three_keep_frame_bindings();
}
'''
outputs.append((
    os.path.join(gallery, "examples", "custom_shader", "lit.wgsl"),
    "packages/gallery/examples/custom_shader/lit.wgsl",
    lit,
))

# The addon objects' shaders (three/shaders/objects: Reflector, Water, Sky,
# Lensflare ...) carry the chunks they use between two marker lines,
# refreshed here:
#   // @chunks-begin output    the blocks, F and O, tone mapping and three_output
#   // @chunks-begin all       every chunk (a `lights: true` material)
#   // @chunks-end
m = re.search(r"^/// The renderer's output:.*?^}\n", helpers, re.S | re.M)
assert m
output = "\n".join(const(c).rstrip() for c in consts) + "\n\n"
output += "\n".join(block(s, "struct") for s in ["Light", "ShadowTile", "FrameU", "ObjU"]) + "\n"
output += binding("F") + binding("O") + "\n"
output += "\n".join(block(f, "fn") for f in ["srgb_to_linear", "linear_to_srgb", "rrt_and_odt_fit",
                                              "agx_contrast", "tone_map"])
output += "\n" + m.group(0)
chunk_sets = {"output": output, "all": body}
objects = os.path.join(engine, "three", "shaders", "objects")
marker = re.compile(r"^// @chunks-begin (\w+)\n.*?^// @chunks-end\n", re.S | re.M)
for name in sorted(os.listdir(objects)) if os.path.isdir(objects) else []:
    if not name.endswith(".wgsl"):
        continue
    path = os.path.join(objects, name)
    text = open(path).read()
    new = marker.sub(lambda mm: "// @chunks-begin %s\n// (GENERATED by tools/make_shader_chunks.py from three.wgsl: do not edit)\n\n%s// @chunks-end\n"
                     % (mm.group(1), chunk_sets[mm.group(1)].rstrip("\n") + "\n"), text)
    if new != text:
        outputs.append((path, "packages/threeas/three/shaders/objects/" + name, new))

# The hash baked variant names start from (three/renderers/gpu/ShaderVariants,
# tools/threeas_bake.sh): a variant baked from an older three.wgsl has
# another name, so it is never found.
digest = hashlib.sha256(open(os.path.join(engine, "three", "shaders", "three.wgsl"), "rb").read()).hexdigest()[:16]
hash_src = (
    "// Generated by tools/make_shader_chunks.py: the first 16 hex digits of\n"
    "// three/shaders/three.wgsl's SHA-256. Baked shader variants\n"
    "// (tools/threeas_bake.sh) are named from it, so GPURenderer finds only\n"
    "// those baked from this three.wgsl (gpu/ShaderVariants).\n"
    'export const THREE_WGSL_HASH: string = "%s";\n' % digest)
outputs.append((
    os.path.join(engine, "three", "renderers", "gpu", "ShaderSourceHash.as"),
    "packages/threeas/three/renderers/gpu/ShaderSourceHash.as",
    hash_src,
))

if check_only:
    stale = []
    for path, label, content in outputs:
        existing = open(path).read() if os.path.exists(path) else None
        if existing != content:
            stale.append(label)
    if stale:
        for label in stale:
            print("stale: %s (run python3 tools/make_shader_chunks.py)" % label, file=sys.stderr)
        sys.exit(1)
    print("shader chunks and ShaderSourceHash.as are fresh (%s)" % digest)
    sys.exit(0)

for path, label, content in outputs:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(content)
    print("wrote %s" % label)
