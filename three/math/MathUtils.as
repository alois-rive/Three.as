// three.js MathUtils, as static functions.

export const DEG2RAD: f64 = Math.PI / 180;
export const RAD2DEG: f64 = 180 / Math.PI;

let _seed: u32 = 1234567;

export class MathUtils {
    static DEG2RAD: f64 = Math.PI / 180;
    static RAD2DEG: f64 = 180 / Math.PI;

    static degToRad(degrees: f64): f64 { return degrees * DEG2RAD; }
    static radToDeg(radians: f64): f64 { return radians * RAD2DEG; }
    static clamp(value: f64, min: f64, max: f64): f64 { return Math.max(min, Math.min(max, value)); }
    static lerp(x: f64, y: f64, t: f64): f64 { return (1 - t) * x + t * y; }
    static inverseLerp(x: f64, y: f64, value: f64): f64 { return x != y ? (value - x) / (y - x) : 0; }
    static mapLinear(x: f64, a1: f64, a2: f64, b1: f64, b2: f64): f64 { return b1 + (x - a1) * (b2 - b1) / (a2 - a1); }
    static damp(x: f64, y: f64, lambda: f64, dt: f64): f64 { return MathUtils.lerp(x, y, 1 - Math.exp(-lambda * dt)); }
    static pingpong(x: f64, length: f64 = 1): f64 { return length - Math.abs(MathUtils.euclideanModulo(x, length * 2) - length); }
    static euclideanModulo(n: f64, m: f64): f64 { return ((n % m) + m) % m; }

    static smoothstep(x: f64, min: f64, max: f64): f64 {
        if (x <= min) return 0;
        if (x >= max) return 1;
        x = (x - min) / (max - min);
        return x * x * (3 - 2 * x);
    }

    static smootherstep(x: f64, min: f64, max: f64): f64 {
        if (x <= min) return 0;
        if (x >= max) return 1;
        x = (x - min) / (max - min);
        return x * x * x * (x * (x * 6 - 15) + 10);
    }

    static randInt(low: i32, high: i32): i32 { return low + <i32>Math.floor(Math.random() * <f64>(high - low + 1)); }
    static randFloat(low: f64, high: f64): f64 { return low + Math.random() * (high - low); }
    static randFloatSpread(range: f64): f64 { return range * (0.5 - Math.random()); }

    /// Deterministic pseudo-random in [0, 1) (mulberry32), as three.js.
    static seededRandom(s: i32 = -1): f64 {
        if (s >= 0) _seed = <u32>s;
        _seed += 0x6D2B79F5;
        let t: u32 = _seed;
        t = (t ^ (t >>> 15)) * (t | 1);
        t ^= t + (t ^ (t >>> 7)) * (t | 61);
        return <f64>((t ^ (t >>> 14)) >>> 0) / 4294967296.0;
    }

    static isPowerOfTwo(value: u32): bool { return value != 0 && (value & (value - 1)) == 0; }
    static ceilPowerOfTwo(value: f64): f64 { return Math.pow(2, Math.ceil(Math.log(value) / Math.LN2)); }
    static floorPowerOfTwo(value: f64): f64 { return Math.pow(2, Math.floor(Math.log(value) / Math.LN2)); }
}
