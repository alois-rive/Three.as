// three.js KeyframeTrack and its typed subclasses: `times` (seconds,
// ascending) and `values` (valueSize per key) for one property named
// "nodeName.property" (".property" for the root; see PropertyBinding).
//
// Interpolation: InterpolateDiscrete, InterpolateLinear (quaternions slerp),
// InterpolateSmooth (three.js's CubicInterpolant), and glTF's CUBICSPLINE
// (InterpolateGLTFCubicSpline: in-tangent, value, out-tangent per key).

import { InterpolateDiscrete, InterpolateLinear, InterpolateSmooth } from "../constants";
import { Dynamic } from "rive/dynamic";
import { numbersOf } from "../core/JSON";

/// glTF CUBICSPLINE keys (three.js's GLTFCubicSplineInterpolant).
export const InterpolateGLTFCubicSpline: i32 = 2303;

export class KeyframeTrack {
    name: string;
    times: Float32Array;
    values: Float32Array;
    interpolation: i32;
    /// "number", "vector", "quaternion", "color", "bool".
    ValueTypeName: string = "";

    constructor(name: string, times: Array<f64>, values: Array<f64>, interpolation: i32 = InterpolateLinear) {
        this.name = name;
        this.times = toF32(times);
        this.values = toF32(values);
        this.interpolation = interpolation;
    }

    /// The interpolation toJSON leaves out (Discrete for boolean tracks).
    get DefaultInterpolation(): i32 {
        return this.ValueTypeName == "bool" ? InterpolateDiscrete : InterpolateLinear;
    }

    /// three.js's KeyframeTrack.toJSON(track): { name, times, values, type,
    /// interpolation (when not the default) }.
    static toJSON(track: KeyframeTrack): Dynamic {
        const json = Dynamic.newTable();
        json.set("name", Dynamic.fromString(track.name));
        json.set("times", numbersOf(track.times));
        if (track.ValueTypeName == "bool") {
            const values = Dynamic.newTable();
            for (let i = 0; i < track.values.length; i++) values.push(Dynamic.fromBool(track.values[i] != 0));
            json.set("values", values);
        } else {
            json.set("values", numbersOf(track.values));
        }
        json.set("type", Dynamic.fromString(track.ValueTypeName));
        if (track.interpolation != track.DefaultInterpolation) {
            json.set("interpolation", Dynamic.fromNumber(<f64>track.interpolation));
        }
        return json;
    }

    /// Values per key.
    getValueSize(): i32 {
        const stride = this.interpolation == InterpolateGLTFCubicSpline ? 3 : 1;
        const n = this.times.length;
        return n > 0 ? this.values.length / (n * stride) : 0;
    }

    setInterpolation(interpolation: i32): KeyframeTrack {
        this.interpolation = interpolation;
        return this;
    }

    getInterpolation(): i32 { return this.interpolation; }

    /// Shifts every key by `timeOffset` seconds.
    shift(timeOffset: f64): KeyframeTrack {
        if (timeOffset != 0) for (let i = 0; i < this.times.length; i++) this.times[i] += <f32>timeOffset;
        return this;
    }

    scale(timeScale: f64): KeyframeTrack {
        if (timeScale != 1) for (let i = 0; i < this.times.length; i++) this.times[i] *= <f32>timeScale;
        return this;
    }

    /// Writes the value at `time` into `out` (getValueSize() entries).
    evaluate(time: f64, out: Float64Array): void {
        const times = this.times;
        const n = times.length;
        const size = this.getValueSize();
        if (n == 0) return;
        const cubic = this.interpolation == InterpolateGLTFCubicSpline;
        const stride = cubic ? size * 3 : size;
        const valueOffset = cubic ? size : 0;
        if (n == 1 || time <= <f64>times[0]) {
            this.copyKey(0, stride, valueOffset, size, out);
            return;
        }
        if (time >= <f64>times[n - 1]) {
            this.copyKey(n - 1, stride, valueOffset, size, out);
            return;
        }
        // Binary search for the key interval [i, i + 1].
        let lo = 0, hi = n - 1;
        while (hi - lo > 1) {
            const mid = (lo + hi) >> 1;
            if (<f64>times[mid] <= time) lo = mid; else hi = mid;
        }
        const t0: f64 = times[lo], t1: f64 = times[hi];
        const dt = t1 - t0;
        const t = dt > 0 ? (time - t0) / dt : 0;
        if (this.interpolation == InterpolateDiscrete) {
            this.copyKey(lo, stride, valueOffset, size, out);
        } else if (cubic) {
            this.cubicSpline(lo, hi, t, dt, size, out);
        } else if (this.interpolation == InterpolateSmooth) {
            this.smooth(lo, hi, t, size, out);
        } else {
            this.lerp(lo, hi, t, size, out);
        }
    }

    protected copyKey(i: i32, stride: i32, valueOffset: i32, size: i32, out: Float64Array): void {
        const v = this.values;
        for (let k = 0; k < size; k++) out[k] = v[i * stride + valueOffset + k];
    }

    /// Linear interpolation; QuaternionKeyframeTrack overrides with slerp.
    protected lerp(i0: i32, i1: i32, t: f64, size: i32, out: Float64Array): void {
        const v = this.values;
        for (let k = 0; k < size; k++) {
            const a: f64 = v[i0 * size + k], b: f64 = v[i1 * size + k];
            out[k] = a + (b - a) * t;
        }
    }

    /// three.js's CubicInterpolant with zero-slope (clamped) ends.
    protected smooth(i0: i32, i1: i32, t: f64, size: i32, out: Float64Array): void {
        const v = this.values, times = this.times;
        const n = times.length;
        const iPrev = i0 > 0 ? i0 - 1 : i0, iNext = i1 < n - 1 ? i1 + 1 : i1;
        const tPrev: f64 = iPrev != i0 ? <f64>times[i0] - <f64>times[iPrev] : <f64>times[i1] - <f64>times[i0];
        const tNext: f64 = iNext != i1 ? <f64>times[iNext] - <f64>times[i1] : <f64>times[i1] - <f64>times[i0];
        const dt: f64 = <f64>times[i1] - <f64>times[i0];
        const halfDt = dt * 0.5;
        const wP = halfDt / tPrev, wN = halfDt / tNext;
        const pp = t * t, ppp = pp * t;
        const sP = -wP * ppp + 2 * wP * pp - wP * t;
        const s0 = (1 + wP) * ppp + (-1.5 - 2 * wP) * pp + (-0.5 + wP) * t + 1;
        const s1 = (-1 - wN) * ppp + (1.5 + wN) * pp + 0.5 * t;
        const sN = wN * ppp - wN * pp;
        for (let k = 0; k < size; k++) {
            out[k] = sP * <f64>v[iPrev * size + k] + s0 * <f64>v[i0 * size + k]
                + s1 * <f64>v[i1 * size + k] + sN * <f64>v[iNext * size + k];
        }
    }

    /// glTF cubic Hermite spline (keys: in-tangent, value, out-tangent).
    protected cubicSpline(i0: i32, i1: i32, t: f64, dt: f64, size: i32, out: Float64Array): void {
        const v = this.values;
        const stride = size * 3;
        const t2 = t * t, t3 = t2 * t;
        const s2 = -2 * t3 + 3 * t2;
        const s3 = t3 - t2;
        const s0 = 1 - s2;
        const s1 = s3 - t2 + t;
        for (let k = 0; k < size; k++) {
            const p0: f64 = v[i0 * stride + size + k];
            const m0: f64 = <f64>v[i0 * stride + size * 2 + k] * dt;   // out-tangent
            const p1: f64 = v[i1 * stride + size + k];
            const m1: f64 = <f64>v[i1 * stride + k] * dt;              // in-tangent
            out[k] = s0 * p0 + s1 * m0 + s2 * p1 + s3 * m1;
        }
    }
}

export class NumberKeyframeTrack extends KeyframeTrack {
    constructor(name: string, times: Array<f64>, values: Array<f64>, interpolation: i32 = InterpolateLinear) {
        super(name, times, values, interpolation);
        this.ValueTypeName = "number";
    }
}

export class VectorKeyframeTrack extends KeyframeTrack {
    constructor(name: string, times: Array<f64>, values: Array<f64>, interpolation: i32 = InterpolateLinear) {
        super(name, times, values, interpolation);
        this.ValueTypeName = "vector";
    }
}

export class ColorKeyframeTrack extends KeyframeTrack {
    constructor(name: string, times: Array<f64>, values: Array<f64>, interpolation: i32 = InterpolateLinear) {
        super(name, times, values, interpolation);
        this.ValueTypeName = "color";
    }
}

/// Discrete only, as three.js (values are 0 or 1).
export class BooleanKeyframeTrack extends KeyframeTrack {
    constructor(name: string, times: Array<f64>, values: Array<f64>) {
        super(name, times, values, InterpolateDiscrete);
        this.ValueTypeName = "bool";
    }
}

/// Quaternions (x, y, z, w per key): linear keys slerp.
export class QuaternionKeyframeTrack extends KeyframeTrack {
    constructor(name: string, times: Array<f64>, values: Array<f64>, interpolation: i32 = InterpolateLinear) {
        super(name, times, values, interpolation);
        this.ValueTypeName = "quaternion";
    }

    protected override lerp(i0: i32, i1: i32, t: f64, size: i32, out: Float64Array): void {
        const v = this.values;
        slerpFlat(out, v, i0 * 4, v, i1 * 4, t);
    }

    protected override cubicSpline(i0: i32, i1: i32, t: f64, dt: f64, size: i32, out: Float64Array): void {
        super.cubicSpline(i0, i1, t, dt, size, out);
        normalize4(out);
    }

    protected override smooth(i0: i32, i1: i32, t: f64, size: i32, out: Float64Array): void {
        super.smooth(i0, i1, t, size, out);
        normalize4(out);
    }
}

/// Shortest-arc slerp of two flat quaternions into out[0..3].
export function slerpFlat(out: Float64Array, a: Float32Array, ai: i32, b: Float32Array, bi: i32, t: f64): void {
    let x0: f64 = a[ai], y0: f64 = a[ai + 1], z0: f64 = a[ai + 2], w0: f64 = a[ai + 3];
    let x1: f64 = b[bi], y1: f64 = b[bi + 1], z1: f64 = b[bi + 2], w1: f64 = b[bi + 3];
    let cos = x0 * x1 + y0 * y1 + z0 * z1 + w0 * w1;
    if (cos < 0) { x1 = -x1; y1 = -y1; z1 = -z1; w1 = -w1; cos = -cos; }
    let s0 = 1 - t, s1 = t;
    if (cos < 0.9995) {
        const theta = Math.acos(Math.min(1, cos));
        const sin = Math.sin(theta);
        s0 = Math.sin((1 - t) * theta) / sin;
        s1 = Math.sin(t * theta) / sin;
    }
    out[0] = x0 * s0 + x1 * s1;
    out[1] = y0 * s0 + y1 * s1;
    out[2] = z0 * s0 + z1 * s1;
    out[3] = w0 * s0 + w1 * s1;
    normalize4(out);
}

function normalize4(q: Float64Array): void {
    const l = Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (l > 0) { q[0] /= l; q[1] /= l; q[2] /= l; q[3] /= l; }
}

function toF32(a: Array<f64>): Float32Array {
    const out = new Float32Array(a.length);
    for (let i = 0; i < a.length; i++) out[i] = <f32>a[i];
    return out;
}
