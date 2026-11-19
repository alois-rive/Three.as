// How data textures reach the GPU (internal): the GPU format of a three.js
// format and type, and the bytes to upload. FloatType data uploads as half
// floats (rgba16float and friends filter everywhere; 32-bit floats need a
// feature WebGPU makes optional).

import { TextureFormat } from "rive/gpu_enums";
import {
    RGBAFormat, RGBFormat, RedFormat, RGFormat, UnsignedByteType, FloatType, HalfFloatType,
} from "../constants";

/// Channels a format has once on the GPU (RGB is widened to RGBA).
export function gpuChannels(format: i32): i32 {
    if (format == RedFormat) return 1;
    if (format == RGFormat) return 2;
    return 4;
}

export function gpuFormat(format: i32, type: i32): TextureFormat {
    const channels = gpuChannels(format);
    if (type == FloatType || type == HalfFloatType) {
        return channels == 1 ? TextureFormat.r16float : channels == 2 ? TextureFormat.rg16float : TextureFormat.rgba16float;
    }
    return channels == 1 ? TextureFormat.r8unorm : channels == 2 ? TextureFormat.rg8unorm : TextureFormat.rgba8unorm;
}

export function isFloatType(type: i32): bool {
    return type == FloatType || type == HalfFloatType;
}

/// The f16 bits of `value` (round to nearest even, inf and NaN kept).
export function toHalf(value: f32): u16 {
    const bits = reinterpret<u32>(value);
    const sign = (bits >> 16) & 0x8000;
    const exp = <i32>((bits >> 23) & 0xff);
    let mant = bits & 0x7fffff;
    if (exp == 0xff) return <u16>(sign | 0x7c00 | (mant != 0 ? 0x200 : 0));
    const e = exp - 127 + 15;
    if (e >= 31) return <u16>(sign | 0x7c00);
    if (e <= 0) {
        if (e < -10) return <u16>sign;
        mant |= 0x800000;
        const shift = <u32>(14 - e);
        let half = mant >> shift;
        const rest = mant & ((1 << shift) - 1);
        const halfway = <u32>1 << (shift - 1);
        if (rest > halfway || (rest == halfway && (half & 1) != 0)) half++;
        return <u16>(sign | half);
    }
    let half = (<u32>e << 10) | (mant >> 13);
    const rest = mant & 0x1fff;
    if (rest > 0x1000 || (rest == 0x1000 && (half & 1) != 0)) half++;
    return <u16>(sign | half);
}

/// The value of f16 bits.
export function fromHalf(h: u16): f32 {
    const sign: u32 = (<u32>h & 0x8000) << 16;
    const exp = (<u32>h >> 10) & 0x1f;
    const mant = <u32>h & 0x3ff;
    if (exp == 0) {
        const v = <f32>mant * <f32>5.960464477539063e-8;   // 2^-24
        return sign != 0 ? -v : v;
    }
    if (exp == 31) return reinterpret<f32>(sign | 0x7f800000 | (mant << 13));
    return reinterpret<f32>(sign | ((exp + 112) << 23) | (mant << 13));
}

/// The bytes of `data` (texels in `format` and `type`, `count` texels) as
/// the GPU format wants them: RGB widened to RGBA (alpha 1), floats to
/// halves. Shares `data`'s buffer when nothing changes.
export function uploadBytes(data: ArrayBufferView, format: i32, type: i32, count: i32): ArrayBuffer {
    const inChannels = format == RGBFormat ? 3 : gpuChannels(format);
    const outChannels = gpuChannels(format);
    if (type == FloatType) {
        const src = Float32Array.wrap(data.buffer, data.byteOffset, count * inChannels);
        const out = new Uint16Array(count * outChannels);
        for (let i = 0; i < count; i++) {
            for (let c = 0; c < outChannels; c++) {
                out[i * outChannels + c] = c < inChannels ? toHalf(src[i * inChannels + c]) : 0x3c00;
            }
        }
        return out.buffer;
    }
    if (type == HalfFloatType) {
        const src = Uint16Array.wrap(data.buffer, data.byteOffset, count * inChannels);
        if (inChannels == outChannels) return whole(data, count * outChannels * 2);
        const out = new Uint16Array(count * outChannels);
        for (let i = 0; i < count; i++) {
            for (let c = 0; c < outChannels; c++) {
                out[i * outChannels + c] = c < inChannels ? src[i * inChannels + c] : 0x3c00;
            }
        }
        return out.buffer;
    }
    const src = Uint8Array.wrap(data.buffer, data.byteOffset, count * inChannels);
    if (inChannels == outChannels) return whole(data, count * outChannels);
    const out = new Uint8Array(count * outChannels);
    for (let i = 0; i < count; i++) {
        for (let c = 0; c < outChannels; c++) out[i * outChannels + c] = c < inChannels ? src[i * inChannels + c] : 255;
    }
    return out.buffer;
}

function whole(data: ArrayBufferView, byteLength: i32): ArrayBuffer {
    if (data.byteOffset == 0 && data.buffer.byteLength == byteLength) return data.buffer;
    return data.buffer.slice(data.byteOffset, data.byteOffset + byteLength);
}

export { UnsignedByteType, RGBAFormat };
