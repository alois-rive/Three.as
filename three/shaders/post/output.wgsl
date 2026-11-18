// Post-processing shader (three/addons/postprocessing), ShaderMaterial
// contract: frame block at group 0, object block at group 1 (both touched so
// they stay in the layout), uniforms at group 2. Fullscreen-quad vertices
// pass through; uv (0, 0) is the bottom left, so textures rendered by the
// renderer (top row first) are read at (u, 1 - v).

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

struct QuadOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(2) uv: vec2<f32>) -> QuadOut {
    var out: QuadOut;
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    out.clip = vec4<f32>(position.xy, 0.5 + keep, 1.0);
    out.uv = vec2<f32>(uv.x, 1.0 - uv.y);
    return out;
}

// OutputPass: linear HDR -> tone mapped (three.js's operators) -> sRGB,
// premultiplied.
struct Uniforms { toneMapping: f32, exposure: f32 };
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

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

fn tone_map(color_in: vec3<f32>, mode: u32, exposure: f32) -> vec3<f32> {
    var color = color_in;
    if (mode == 1u) { return saturate(exposure * color); }
    if (mode == 2u) { color *= exposure; return saturate(color / (vec3<f32>(1.0) + color)); }
    if (mode == 3u) {
        color *= exposure;
        color = max(vec3<f32>(0.0), color - 0.004);
        return pow((color * (6.2 * color + 0.5)) / (color * (6.2 * color + 1.7) + 0.06), vec3<f32>(2.2));
    }
    if (mode == 4u) {
        let input = mat3x3<f32>(vec3<f32>(0.59719, 0.07600, 0.02840), vec3<f32>(0.35458, 0.90834, 0.13383),
            vec3<f32>(0.04823, 0.01566, 0.83777));
        let output = mat3x3<f32>(vec3<f32>(1.60475, -0.10208, -0.00327), vec3<f32>(-0.53108, 1.10813, -0.07276),
            vec3<f32>(-0.07367, -0.00605, 1.07602));
        color *= exposure / 0.6;
        return saturate(output * rrt_and_odt_fit(input * color));
    }
    if (mode == 6u) {
        let to2020 = mat3x3<f32>(vec3<f32>(0.6274, 0.0691, 0.0164), vec3<f32>(0.3293, 0.9195, 0.0880), vec3<f32>(0.0433, 0.0113, 0.8956));
        let from2020 = mat3x3<f32>(vec3<f32>(1.6605, -0.1246, -0.0182), vec3<f32>(-0.5876, 1.1329, -0.1006), vec3<f32>(-0.0728, -0.0083, 1.1187));
        let inset = mat3x3<f32>(vec3<f32>(0.856627153315983, 0.137318972929847, 0.11189821299995),
            vec3<f32>(0.0951212405381588, 0.761241990602591, 0.0767994186031903),
            vec3<f32>(0.0482516061458583, 0.101439036467562, 0.811302368396859));
        let outset = mat3x3<f32>(vec3<f32>(1.1271005818144368, -0.1413297634984383, -0.14132976349843826),
            vec3<f32>(-0.11060664309660323, 1.157823702216272, -0.11060664309660294),
            vec3<f32>(-0.016493938717834573, -0.016493938717834257, 1.2519364065950405));
        color *= exposure;
        color = max(inset * (to2020 * color), vec3<f32>(1e-10));
        color = clamp((log2(color) + 12.47393) / (4.026069 + 12.47393), vec3<f32>(0.0), vec3<f32>(1.0));
        color = pow(max(vec3<f32>(0.0), outset * agx_contrast(color)), vec3<f32>(2.2));
        return clamp(from2020 * color, vec3<f32>(0.0), vec3<f32>(1.0));
    }
    if (mode == 7u) {
        color *= exposure;
        let x = min(color.r, min(color.g, color.b));
        color -= select(0.04, x - 6.25 * x * x, x < 0.08);
        let peak = max(color.r, max(color.g, color.b));
        if (peak < 0.76) { return color; }
        let d = 0.24;
        let new_peak = 1.0 - d * d / (peak + d - 0.76);
        color *= new_peak / peak;
        let g = 1.0 - 1.0 / (0.15 * (peak - new_peak) + 1.0);
        return mix(color, vec3<f32>(new_peak), g);
    }
    return color;
}

fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let x = max(c, vec3<f32>(0.0));
    return select(1.055 * pow(x, vec3<f32>(0.41666)) - vec3<f32>(0.055), x * 12.92, x < vec3<f32>(0.0031308));
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texel = textureSample(tDiffuse, s_tex, in.uv);
    let a = texel.a;
    let straight = select(vec3<f32>(0.0), texel.rgb / a, a > 0.0);
    let mapped = tone_map(straight, u32(u.toneMapping), u.exposure);
    return vec4<f32>(linear_to_srgb(mapped) * a, a);
}
