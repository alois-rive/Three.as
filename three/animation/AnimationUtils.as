// three.js AnimationUtils: array helpers for keyframe data, subclip and
// makeClipAdditive.
//
//     const idle = AnimationUtils.subclip(clip, "idle", 0, 120);     // frames 0-119 at 30 fps
//     AnimationUtils.makeClipAdditive(lean);                          // relative to frame 0
//     mixer.clipAction(lean).play();                                  // blends additively
//
// The array helpers work on `Array<f64>` (three.js takes any array or
// typed array): convertArray copies into a Float32Array, sortedArray
// returns a plain array.

import { Dynamic, DynamicKind } from "rive/dynamic";
import { AnimationClip } from "./AnimationClip";
import { KeyframeTrack, InterpolateGLTFCubicSpline } from "./KeyframeTrack";
import { AdditiveAnimationBlendMode } from "../constants";
import { jget, asNum } from "../core/JSON";

/// `array` as a Float32Array (three.js's convertArray to Float32Array).
export function convertArray(array: Array<f64>): Float32Array {
    const out = new Float32Array(array.length);
    for (let i = 0; i < array.length; i++) out[i] = <f32>array[i];
    return out;
}

/// Whether `value` is a typed array (an ArrayBufferView).
export function isTypedArray<T>(value: T): bool {
    if (isReference<T>()) {
        return value instanceof Float32Array || value instanceof Float64Array || value instanceof Uint8Array
            || value instanceof Uint16Array || value instanceof Uint32Array || value instanceof Int8Array
            || value instanceof Int16Array || value instanceof Int32Array || value instanceof Uint8ClampedArray;
    }
    return false;
}

/// The indices of `times` in ascending time order (stable).
export function getKeyframeOrder(times: Array<f64>): Array<i32> {
    const n = times.length;
    const result = new Array<i32>(n);
    for (let i = 0; i < n; i++) result[i] = i;
    // Insertion sort: key counts are small and it keeps equal times in order.
    for (let i = 1; i < n; i++) {
        const v = result[i];
        let j = i - 1;
        while (j >= 0 && times[result[j]] > times[v]) {
            result[j + 1] = result[j];
            j--;
        }
        result[j + 1] = v;
    }
    return result;
}

/// `values` (`stride` per key) reordered by `order` (getKeyframeOrder).
export function sortedArray(values: Array<f64>, stride: i32, order: Array<i32>): Array<f64> {
    const nValues = values.length;
    const result = new Array<f64>(nValues);
    for (let i = 0, dstOffset = 0; dstOffset != nValues; ++i) {
        const srcOffset = order[i] * stride;
        for (let j = 0; j != stride; ++j) result[dstOffset++] = values[srcOffset + j];
    }
    return result;
}

/// Reads keys in three.js's array-of-structures JSON ([{ time, pos: [...] }])
/// into `times` and `values`: `valuePropertyName` names each key's value
/// (a number or an array of numbers). Keys without it are skipped.
export function flattenJSON(jsonKeys: Dynamic?, times: Array<f64>, values: Array<f64>, valuePropertyName: string): void {
    if (jsonKeys == null || jsonKeys.kind != DynamicKind.table) return;
    const keys = Dynamic.asArray(jsonKeys);
    for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        const value = jget(key, valuePropertyName);
        if (value == null) continue;
        times.push(asNum(jget(key, "time"), 0));
        if (value.kind == DynamicKind.table) {
            const items = Dynamic.asArray(value);
            for (let k = 0; k < items.length; k++) values.push(asNum(items[k], 0));
        } else {
            values.push(asNum(value, 0));
        }
    }
}

/// A copy of `sourceClip` keeping the keys of frames [startFrame, endFrame)
/// at `fps`, shifted to start at 0.
export function subclip(sourceClip: AnimationClip, name: string, startFrame: f64, endFrame: f64,
                        fps: f64 = 30): AnimationClip {
    const clip = sourceClip.clone();
    clip.name = name;
    const tracks: Array<KeyframeTrack> = [];
    for (let i = 0; i < clip.tracks.length; ++i) {
        const track = clip.tracks[i];
        const stride = track.getKeyStride();
        const times: Array<f64> = [];
        const values: Array<f64> = [];
        for (let j = 0; j < track.times.length; ++j) {
            const frame = <f64>track.times[j] * fps;
            if (frame < startFrame || frame >= endFrame) continue;
            times.push(track.times[j]);
            for (let k = 0; k < stride; ++k) values.push(track.values[j * stride + k]);
        }
        if (times.length == 0) continue;
        track.times = convertArray(times);
        track.values = convertArray(values);
        tracks.push(track);
    }
    clip.tracks = tracks;
    let minStartTime: f64 = Infinity;
    for (let i = 0; i < clip.tracks.length; ++i) {
        if (minStartTime > <f64>clip.tracks[i].times[0]) minStartTime = clip.tracks[i].times[0];
    }
    for (let i = 0; i < clip.tracks.length; ++i) clip.tracks[i].shift(-minStartTime);
    clip.resetDuration();
    return clip;
}

/// Makes `targetClip`'s tracks relative to `referenceClip`'s values at
/// `referenceFrame` (quaternions multiplied by the reference's conjugate,
/// other numbers minus the reference) and sets its blendMode to additive.
export function makeClipAdditive(targetClip: AnimationClip, referenceFrame: f64 = 0,
                                 referenceClip: AnimationClip? = null, fps: f64 = 30): AnimationClip {
    const reference = referenceClip != null ? referenceClip : targetClip;
    if (fps <= 0) fps = 30;
    const referenceTime = referenceFrame / fps;
    const numTracks = reference.tracks.length;
    const referenceValue = new Float64Array(4);
    for (let i = 0; i < numTracks; ++i) {
        const referenceTrack = reference.tracks[i];
        const type = referenceTrack.ValueTypeName;
        if (type == "bool" || type == "string") continue;
        let targetTrack: KeyframeTrack? = null;
        for (let k = 0; k < targetClip.tracks.length; k++) {
            const t = targetClip.tracks[k];
            if (t.name == referenceTrack.name && t.ValueTypeName == type) { targetTrack = t; break; }
        }
        if (targetTrack == null) continue;
        const size = referenceTrack.getValueSize();
        const value = size > 4 ? new Float64Array(size) : referenceValue;
        // The value to subtract: evaluate clamps before the first key and
        // after the last one, as three.js's two special cases.
        referenceTrack.evaluate(referenceTime, value);
        if (type == "quaternion") {
            // Conjugate of the normalized reference.
            let l = Math.sqrt(value[0] * value[0] + value[1] * value[1] + value[2] * value[2] + value[3] * value[3]);
            if (l == 0) l = 1;
            value[0] = -value[0] / l; value[1] = -value[1] / l; value[2] = -value[2] / l; value[3] = value[3] / l;
        }
        const target = targetTrack!;
        const targetSize = target.getValueSize();
        const cubic = target.interpolation == InterpolateGLTFCubicSpline;
        const stride = cubic ? targetSize * 3 : targetSize;
        const targetOffset = cubic ? targetSize : 0;
        const v = target.values;
        const numTimes = target.times.length;
        for (let j = 0; j < numTimes; ++j) {
            const o = j * stride + targetOffset;
            if (type == "quaternion") {
                // values[o] = values[o] x reference (multiplyQuaternionsFlat).
                const ax: f64 = v[o], ay: f64 = v[o + 1], az: f64 = v[o + 2], aw: f64 = v[o + 3];
                const bx = value[0], by = value[1], bz = value[2], bw = value[3];
                v[o] = <f32>(ax * bw + aw * bx + ay * bz - az * by);
                v[o + 1] = <f32>(ay * bw + aw * by + az * bx - ax * bz);
                v[o + 2] = <f32>(az * bw + aw * bz + ax * by - ay * bx);
                v[o + 3] = <f32>(aw * bw - ax * bx - ay * by - az * bz);
            } else {
                for (let k = 0; k < targetSize; ++k) v[o + k] = <f32>(<f64>v[o + k] - value[k]);
            }
        }
    }
    targetClip.blendMode = AdditiveAnimationBlendMode;
    return targetClip;
}

/// three.js's `AnimationUtils` namespace object.
export class AnimationUtils {
    static convertArray(array: Array<f64>): Float32Array { return convertArray(array); }
    static isTypedArray<T>(value: T): bool { return isTypedArray<T>(value); }
    static getKeyframeOrder(times: Array<f64>): Array<i32> { return getKeyframeOrder(times); }
    static sortedArray(values: Array<f64>, stride: i32, order: Array<i32>): Array<f64> {
        return sortedArray(values, stride, order);
    }
    static flattenJSON(jsonKeys: Dynamic?, times: Array<f64>, values: Array<f64>, valuePropertyName: string): void {
        flattenJSON(jsonKeys, times, values, valuePropertyName);
    }
    static subclip(sourceClip: AnimationClip, name: string, startFrame: f64, endFrame: f64, fps: f64 = 30): AnimationClip {
        return subclip(sourceClip, name, startFrame, endFrame, fps);
    }
    static makeClipAdditive(targetClip: AnimationClip, referenceFrame: f64 = 0,
                            referenceClip: AnimationClip? = null, fps: f64 = 30): AnimationClip {
        return makeClipAdditive(targetClip, referenceFrame, referenceClip, fps);
    }
}
