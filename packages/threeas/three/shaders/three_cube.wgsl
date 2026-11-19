// ThreeAS cube map conversion (renderers/gpu/GPUTextures.as): draws the six
// faces of a CubeTexture into an equirectangular texture, linear and
// straight alpha, row 0 at the top (+y), as the renderer samples
// equirectangular maps (three.js's equirectUv).

@group(0) @binding(0) var t_px: texture_2d<f32>;
@group(0) @binding(1) var t_nx: texture_2d<f32>;
@group(0) @binding(2) var t_py: texture_2d<f32>;
@group(0) @binding(3) var t_ny: texture_2d<f32>;
@group(0) @binding(4) var t_pz: texture_2d<f32>;
@group(0) @binding(5) var t_nz: texture_2d<f32>;
@group(0) @binding(6) var s_face: sampler;
struct Params {
    flags: vec4<f32>,   // x flip x (image cube maps), y rows bottom up, z sRGB, w premultiplied
};
@group(0) @binding(7) var<uniform> P: Params;

const PI: f32 = 3.141592653589793;

struct BlitOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_blit(@builtin(vertex_index) vi: u32) -> BlitOut {
    var out: BlitOut;
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    out.clip = vec4<f32>(x, y, 0.0, 1.0);
    // v = 1 at the top row.
    out.uv = vec2<f32>(x * 0.5 + 0.5, y * 0.5 + 0.5);
    return out;
}

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 0.0773993808;
    let hi = pow(c * 0.9478672986 + vec3<f32>(0.0521327014), vec3<f32>(2.4));
    return select(hi, lo, c < vec3<f32>(0.04045));
}

@fragment
fn fs_cube_to_equirect(in: BlitOut) -> @location(0) vec4<f32> {
    // The inverse of equirectUv: u = atan2(z, x) / 2pi + 0.5, v = asin(y) / pi + 0.5.
    let phi = (in.uv.x - 0.5) * 2.0 * PI;
    let theta = (in.uv.y - 0.5) * PI;
    var d = vec3<f32>(cos(theta) * cos(phi), sin(theta), cos(theta) * sin(phi));
    if (P.flags.x > 0.5) {
        d.x = -d.x;
    }
    // The cube map face and coordinates (sc, tc), as the GL/WebGPU rules.
    let a = abs(d);
    var face = 0;
    var sc = 0.0;
    var tc = 0.0;
    var ma = 1.0;
    if (a.x >= a.y && a.x >= a.z) {
        ma = a.x;
        if (d.x > 0.0) { face = 0; sc = -d.z; tc = -d.y; } else { face = 1; sc = d.z; tc = -d.y; }
    } else if (a.y >= a.z) {
        ma = a.y;
        if (d.y > 0.0) { face = 2; sc = d.x; tc = d.z; } else { face = 3; sc = d.x; tc = -d.z; }
    } else {
        ma = a.z;
        if (d.z > 0.0) { face = 4; sc = d.x; tc = -d.y; } else { face = 5; sc = -d.x; tc = -d.y; }
    }
    var st = vec2<f32>(sc / ma, tc / ma) * 0.5 + vec2<f32>(0.5);
    if (P.flags.y > 0.5) {
        st.y = 1.0 - st.y;
    }
    let c0 = textureSampleLevel(t_px, s_face, st, 0.0);
    let c1 = textureSampleLevel(t_nx, s_face, st, 0.0);
    let c2 = textureSampleLevel(t_py, s_face, st, 0.0);
    let c3 = textureSampleLevel(t_ny, s_face, st, 0.0);
    let c4 = textureSampleLevel(t_pz, s_face, st, 0.0);
    let c5 = textureSampleLevel(t_nz, s_face, st, 0.0);
    var c = c0;
    if (face == 1) { c = c1; } else if (face == 2) { c = c2; } else if (face == 3) { c = c3; }
    else if (face == 4) { c = c4; } else if (face == 5) { c = c5; }
    if (P.flags.w > 0.5 && c.a > 0.0) {
        c = vec4<f32>(c.rgb / c.a, c.a);
    }
    if (P.flags.z > 0.5) {
        c = vec4<f32>(srgb_to_linear(c.rgb), c.a);
    }
    return c;
}
