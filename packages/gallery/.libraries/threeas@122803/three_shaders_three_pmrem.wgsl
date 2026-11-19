// ThreeAS PMREM (renderers/gpu/GPUTextures.as): prefilters an
// equirectangular environment into a mip chain where level k is the
// environment convolved with the GGX lobe of roughness k / (levels - 1),
// as three.js's PMREMGenerator does into its cube-UV layout. Filtered
// importance sampling: each sample reads the source mip whose texels match
// the sample's solid angle. Output: linear, straight alpha, row 0 at the
// top (+y).

@group(0) @binding(0) var t_src: texture_2d<f32>;
@group(0) @binding(1) var s_src: sampler;
struct Params {
    params: vec4<f32>,   // x roughness, y source max lod, z source texels (w x h), w unused
    flags: vec4<f32>,    // x sRGB, y premultiplied, z flipY (row 0 at the top)
};
@group(0) @binding(2) var<uniform> P: Params;

const PI: f32 = 3.141592653589793;
const SAMPLES: u32 = 96u;

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
    out.uv = vec2<f32>(x * 0.5 + 0.5, y * 0.5 + 0.5);   // v = 1 at the top row
    return out;
}

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 0.0773993808;
    let hi = pow(c * 0.9478672986 + vec3<f32>(0.0521327014), vec3<f32>(2.4));
    return select(hi, lo, c < vec3<f32>(0.04045));
}

fn source(dir: vec3<f32>, lod: f32) -> vec3<f32> {
    var uv = vec2<f32>(atan2(dir.z, dir.x) * 0.5 / PI + 0.5, asin(clamp(dir.y, -1.0, 1.0)) / PI + 0.5);
    if (P.flags.z > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    var c = textureSampleLevel(t_src, s_src, uv, lod);
    if (P.flags.y > 0.5 && c.a > 0.0) {
        c = vec4<f32>(c.rgb / c.a, c.a);
    }
    if (P.flags.x > 0.5) {
        return srgb_to_linear(c.rgb);
    }
    return c.rgb;
}

fn radical_inverse(bits_in: u32) -> f32 {
    var bits = bits_in;
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return f32(bits) * 2.3283064365386963e-10;
}

@fragment
fn fs_prefilter(in: BlitOut) -> @location(0) vec4<f32> {
    let phi = (in.uv.x - 0.5) * 2.0 * PI;
    let theta = (in.uv.y - 0.5) * PI;
    let N = vec3<f32>(cos(theta) * cos(phi), sin(theta), cos(theta) * sin(phi));
    let roughness = P.params.x;
    if (roughness <= 0.0) {
        return vec4<f32>(source(N, 0.0), 1.0);
    }
    let alpha = roughness * roughness;
    let a2 = alpha * alpha;
    // A tangent frame around N.
    let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(N.y) > 0.999);
    let tx = normalize(cross(up, N));
    let ty = cross(N, tx);
    let texel_solid_angle = 4.0 * PI / P.params.z;
    var sum = vec3<f32>(0.0);
    var weight = 0.0;
    for (var i = 0u; i < SAMPLES; i++) {
        let xi = vec2<f32>(f32(i) / f32(SAMPLES), radical_inverse(i));
        let ph = 2.0 * PI * xi.x;
        let cos_t = sqrt((1.0 - xi.y) / (1.0 + (a2 - 1.0) * xi.y));
        let sin_t = sqrt(1.0 - cos_t * cos_t);
        let H = tx * (sin_t * cos(ph)) + ty * (sin_t * sin(ph)) + N * cos_t;
        let L = 2.0 * dot(N, H) * H - N;   // V = N
        let n_dot_l = dot(N, L);
        if (n_dot_l > 0.0) {
            let n_dot_h = max(cos_t, 1e-4);
            let d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
            let D = a2 / (PI * d * d);
            let pdf = D * 0.25;   // D n.h / (4 v.h), with v = n
            let sample_solid_angle = 1.0 / (f32(SAMPLES) * pdf + 1e-4);
            let lod = clamp(0.5 * log2(sample_solid_angle / texel_solid_angle) + 1.0, 0.0, P.params.y);
            sum += source(L, lod) * n_dot_l;
            weight += n_dot_l;
        }
    }
    return vec4<f32>(sum / max(weight, 1e-4), 1.0);
}
