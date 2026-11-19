// three.js examples/jsm/shaders/HalftoneShader.js (HalftonePass), as a
// post shader (see copy.wgsl). Shape: 1 dot, 2 ellipse, 3 line, 4 square;
// blending mode: 1 linear, 2 multiply, 3 add, 4 lighter, 5 darker. The
// grid is laid out from the bottom left, as three.js's vUV.

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

// HalftoneShader's uniforms, in insertion order.
struct Uniforms {
    shape: f32,
    radius: f32,
    rotateR: f32,
    rotateG: f32,
    rotateB: f32,
    scatter: f32,
    width: f32,
    height: f32,
    blending: f32,
    blendingMode: f32,
    greyscale: f32,
    disable: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

const SQRT2_MINUS_ONE: f32 = 0.41421356;
const SQRT2_HALF_MINUS_ONE: f32 = 0.20710678;
const PI2: f32 = 6.28318531;
const SAMPLES: i32 = 8;

fn shape_is(s: i32) -> bool { return i32(round(u.shape)) == s; }
fn mode_is(m: i32) -> bool { return i32(round(u.blendingMode)) == m; }

fn blend(a: f32, b: f32, t: f32) -> f32 {
    return a * (1.0 - t) + b * t;
}

fn hypot(x: f32, y: f32) -> f32 {
    return sqrt(x * x + y * y);
}

fn rand(seed: vec2<f32>) -> f32 {
    return fract(sin(dot(seed, vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

// GLSL's mod (x - y * floor(x / y)).
fn gmod(x: f32, y: f32) -> f32 {
    return x - y * floor(x / y);
}

fn distance_to_dot_radius(channel: f32, coord: vec2<f32>, normal: vec2<f32>, p: vec2<f32>, angle: f32,
                          rad_max: f32) -> f32 {
    var dist = hypot(coord.x - p.x, coord.y - p.y);
    var rad = channel;
    if (shape_is(1)) {
        rad = pow(abs(rad), 1.125) * rad_max;
    } else if (shape_is(2)) {
        rad = pow(abs(rad), 1.125) * rad_max;
        if (dist != 0.0) {
            let dot_p = abs((p.x - coord.x) / dist * normal.x + (p.y - coord.y) / dist * normal.y);
            dist = (dist * (1.0 - SQRT2_HALF_MINUS_ONE)) + dot_p * dist * SQRT2_MINUS_ONE;
        }
    } else if (shape_is(3)) {
        rad = pow(abs(rad), 1.5) * rad_max;
        let dot_p = (p.x - coord.x) * normal.x + (p.y - coord.y) * normal.y;
        dist = hypot(normal.x * dot_p, normal.y * dot_p);
    } else if (shape_is(4)) {
        let theta = atan2(p.y - coord.y, p.x - coord.x) - angle;
        let sin_t = abs(sin(theta));
        let cos_t = abs(cos(theta));
        rad = pow(abs(rad), 1.4);
        rad = rad_max * (rad + select(rad - cos_t * rad, rad - sin_t * rad, sin_t > cos_t));
    }
    return rad - dist;
}

struct Cell {
    normal: vec2<f32>,
    p1: vec2<f32>,
    p2: vec2<f32>,
    p3: vec2<f32>,
    p4: vec2<f32>,
};

// The texel at `point` (pixels from the bottom left).
fn texel_at(point: vec2<f32>) -> vec4<f32> {
    let uv = vec2<f32>(point.x / u.width, 1.0 - point.y / u.height);
    return textureSampleLevel(tDiffuse, s_tex, uv, 0.0);
}

fn get_sample(point: vec2<f32>) -> vec4<f32> {
    var tex = texel_at(point);
    let base = rand(vec2<f32>(floor(point.x), floor(point.y))) * PI2;
    let angle_step = PI2 / f32(SAMPLES);
    let dist = u.radius * 0.66;
    for (var i = 0; i < SAMPLES; i++) {
        let r = base + angle_step * f32(i);
        let coord = point + vec2<f32>(cos(r) * dist, sin(r) * dist);
        tex += texel_at(coord);
    }
    tex /= f32(SAMPLES) + 1.0;
    return tex;
}

fn get_dot_colour(c: Cell, p: vec2<f32>, channel: i32, angle: f32, aa: f32) -> f32 {
    let s1 = get_sample(c.p1)[channel];
    let s2 = get_sample(c.p2)[channel];
    let s3 = get_sample(c.p3)[channel];
    let s4 = get_sample(c.p4)[channel];
    let d1 = distance_to_dot_radius(s1, c.p1, c.normal, p, angle, u.radius);
    let d2 = distance_to_dot_radius(s2, c.p2, c.normal, p, angle, u.radius);
    let d3 = distance_to_dot_radius(s3, c.p3, c.normal, p, angle, u.radius);
    let d4 = distance_to_dot_radius(s4, c.p4, c.normal, p, angle, u.radius);
    var res = select(0.0, clamp(d1 / aa, 0.0, 1.0), d1 > 0.0);
    res += select(0.0, clamp(d2 / aa, 0.0, 1.0), d2 > 0.0);
    res += select(0.0, clamp(d3 / aa, 0.0, 1.0), d3 > 0.0);
    res += select(0.0, clamp(d4 / aa, 0.0, 1.0), d4 > 0.0);
    return clamp(res, 0.0, 1.0);
}

fn get_reference_cell(p: vec2<f32>, origin: vec2<f32>, grid_angle: f32, cell_step: f32) -> Cell {
    var c: Cell;
    let n = vec2<f32>(cos(grid_angle), sin(grid_angle));
    let threshold = cell_step * 0.5;
    let dot_normal = n.x * (p.x - origin.x) + n.y * (p.y - origin.y);
    let dot_line = -n.y * (p.x - origin.x) + n.x * (p.y - origin.y);
    let offset = vec2<f32>(n.x * dot_normal, n.y * dot_normal);
    let offset_normal = gmod(hypot(offset.x, offset.y), cell_step);
    let normal_dir = select(-1.0, 1.0, dot_normal < 0.0);
    let normal_scale = select(cell_step - offset_normal, -offset_normal, offset_normal < threshold) * normal_dir;
    let offset_line = gmod(hypot((p.x - offset.x) - origin.x, (p.y - offset.y) - origin.y), cell_step);
    let line_dir = select(-1.0, 1.0, dot_line < 0.0);
    let line_scale = select(cell_step - offset_line, -offset_line, offset_line < threshold) * line_dir;

    // The closest corner.
    c.normal = n;
    c.p1.x = p.x - n.x * normal_scale + n.y * line_scale;
    c.p1.y = p.y - n.y * normal_scale - n.x * line_scale;

    // Scatter.
    if (u.scatter != 0.0) {
        let off_mag = u.scatter * threshold * 0.5;
        let off_angle = rand(vec2<f32>(floor(c.p1.x), floor(c.p1.y))) * PI2;
        c.p1.x += cos(off_angle) * off_mag;
        c.p1.y += sin(off_angle) * off_mag;
    }

    // The other corners.
    let normal_step = normal_dir * select(-cell_step, cell_step, offset_normal < threshold);
    let line_step = line_dir * select(-cell_step, cell_step, offset_line < threshold);
    c.p2.x = c.p1.x - n.x * normal_step;
    c.p2.y = c.p1.y - n.y * normal_step;
    c.p3.x = c.p1.x + n.y * line_step;
    c.p3.y = c.p1.y - n.x * line_step;
    c.p4.x = c.p1.x - n.x * normal_step + n.y * line_step;
    c.p4.y = c.p1.y - n.y * normal_step - n.x * line_step;
    return c;
}

fn blend_colour(a: f32, b: f32, t: f32) -> f32 {
    if (mode_is(1)) {
        return blend(a, b, 1.0 - t);
    } else if (mode_is(3)) {
        return blend(a, min(1.0, a + b), t);
    } else if (mode_is(2)) {
        return blend(a, max(0.0, a * b), t);
    } else if (mode_is(4)) {
        return blend(a, max(a, b), t);
    } else if (mode_is(5)) {
        return blend(a, min(a, b), t);
    }
    return blend(a, b, 1.0 - t);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texel = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0);
    if (u.disable > 0.5) {
        return texel;
    }
    // Pixels from the bottom left, as three.js's vUV * (width, height).
    let p = vec2<f32>(in.uv.x * u.width, (1.0 - in.uv.y) * u.height);
    let origin = vec2<f32>(0.0, 0.0);
    let aa = select(1.25, u.radius * 0.5, u.radius < 2.5);
    let cell_r = get_reference_cell(p, origin, u.rotateR, u.radius);
    let cell_g = get_reference_cell(p, origin, u.rotateG, u.radius);
    let cell_b = get_reference_cell(p, origin, u.rotateB, u.radius);
    var r = get_dot_colour(cell_r, p, 0, u.rotateR, aa);
    var g = get_dot_colour(cell_g, p, 1, u.rotateG, aa);
    var b = get_dot_colour(cell_b, p, 2, u.rotateB, aa);

    // Blend with the original.
    r = blend_colour(r, texel.r, u.blending);
    g = blend_colour(g, texel.g, u.blending);
    b = blend_colour(b, texel.b, u.blending);
    if (u.greyscale > 0.5) {
        let grey = (r + b + g) / 3.0;
        r = grey;
        g = grey;
        b = grey;
    }
    return vec4<f32>(r, g, b, 1.0);
}
