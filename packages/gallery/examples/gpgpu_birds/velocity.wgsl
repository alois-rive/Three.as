// The birds' velocities (three.js webgl_gpgpu_birds' fragmentShaderVelocity),
// a GPUComputationRenderer compute shader: separation, alignment and
// cohesion against every other bird, flight from the predator, a pull to
// the centre and a speed limit. Vertex stage and bindings as
// three/shaders/misc/gpu_computation.wgsl.

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> @builtin(position) vec4<f32> {
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    return vec4<f32>(position.xy, 0.5 + keep, 1.0);
}

// Uniforms in insertion order: resolution (GPUComputationRenderer), then
// the example's (predator first, so the vec3 starts a 16-byte row as HLSL
// packs it); then the dependencies' textures (texturePosition,
// textureVelocity) and their sampler.
struct Uniforms {
    resolution: vec2<f32>,
    predator: vec3<f32>,
    time: f32,
    testing: f32,
    delta: f32,
    separationDistance: f32,
    alignmentDistance: f32,
    cohesionDistance: f32,
    freedomFactor: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var texturePosition: texture_2d<f32>;
@group(2) @binding(2) var textureVelocity: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

const PI: f32 = 3.141592653589793;
const PI_2: f32 = PI * 2.0;

// three.js's define BOUNDS (800.00).
const UPPER_BOUNDS: f32 = 800.0;
const LOWER_BOUNDS: f32 = -UPPER_BOUNDS;

const SPEED_LIMIT: f32 = 9.0;

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    _ = s_tex;   // bound by the contract, unused (textureLoad)
    let zoneRadius = u.separationDistance + u.alignmentDistance + u.cohesionDistance;
    let separationThresh = u.separationDistance / zoneRadius;
    let alignmentThresh = (u.separationDistance + u.alignmentDistance) / zoneRadius;
    let zoneRadiusSquared = zoneRadius * zoneRadius;

    let self_p = vec2<i32>(frag.xy);
    let selfPosition = textureLoad(texturePosition, self_p, 0).xyz;
    let selfVelocity = textureLoad(textureVelocity, self_p, 0).xyz;

    var dist: f32;
    var dir: vec3<f32>;
    var distSquared: f32;
    var f: f32;
    var percent: f32;

    var velocity = selfVelocity;
    var limit = SPEED_LIMIT;

    dir = u.predator * UPPER_BOUNDS - selfPosition;
    dir.z = 0.0;
    dist = length(dir);
    distSquared = dist * dist;

    let preyRadius = 150.0;
    let preyRadiusSq = preyRadius * preyRadius;

    // move birds away from predator
    if (dist < preyRadius) {
        f = (distSquared / preyRadiusSq - 1.0) * u.delta * 100.0;
        velocity += normalize(dir) * f;
        limit += 5.0;
    }

    // Attract flocks to the center
    let central = vec3<f32>(0.0, 0.0, 0.0);
    dir = selfPosition - central;
    dist = length(dir);
    dir.y *= 2.5;
    velocity -= normalize(dir) * u.delta * 5.0;

    let size = vec2<i32>(textureDimensions(texturePosition));
    for (var y = 0; y < size.y; y++) {
        for (var x = 0; x < size.x; x++) {
            let ref_p = vec2<i32>(x, y);
            let birdPosition = textureLoad(texturePosition, ref_p, 0).xyz;

            dir = birdPosition - selfPosition;
            dist = length(dir);

            if (dist < 0.0001) { continue; }

            distSquared = dist * dist;

            if (distSquared > zoneRadiusSquared) { continue; }

            percent = distSquared / zoneRadiusSquared;

            if (percent < separationThresh) { // low
                // Separation - Move apart for comfort
                f = (separationThresh / percent - 1.0) * u.delta;
                velocity -= normalize(dir) * f;
            } else if (percent < alignmentThresh) { // high
                // Alignment - fly the same direction
                let threshDelta = alignmentThresh - separationThresh;
                let adjustedPercent = (percent - separationThresh) / threshDelta;
                let birdVelocity = textureLoad(textureVelocity, ref_p, 0).xyz;
                f = (0.5 - cos(adjustedPercent * PI_2) * 0.5 + 0.5) * u.delta;
                velocity += normalize(birdVelocity) * f;
            } else {
                // Attraction / Cohesion - move closer
                let threshDelta = 1.0 - alignmentThresh;
                var adjustedPercent: f32;
                if (threshDelta == 0.0) {
                    adjustedPercent = 1.0;
                } else {
                    adjustedPercent = (percent - alignmentThresh) / threshDelta;
                }
                f = (0.5 - (cos(adjustedPercent * PI_2) * -0.5 + 0.5)) * u.delta;
                velocity += normalize(dir) * f;
            }
        }
    }

    // Speed Limits
    if (length(velocity) > limit) {
        velocity = normalize(velocity) * limit;
    }

    return vec4<f32>(velocity, 1.0);
}
