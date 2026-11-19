// A WAV decoder for audio that does not come from a Rive audio asset
// (fetched urls, blob assets, decodeAudioData): Rive decodes WAV, MP3 and
// FLAC only from its own AudioAssets (AudioSource.toBlob), so bytes are
// decoded here. PCM 8, 16, 24 and 32-bit and IEEE float 32 and 64-bit, plain
// or WAVE_FORMAT_EXTENSIBLE. Channels past the second are dropped.

import { Blob } from "rive/shared";

/// What parseWAVHeader found.
export class WAVInfo {
    error: string = "";
    /// 1 PCM, 3 float.
    format: i32 = 0;
    channels: i32 = 0;
    sampleRate: f64 = 0;
    bitsPerSample: i32 = 0;
    dataOffset: i32 = 0;
    dataLength: i32 = 0;
    frames: i32 = 0;
}

function u16(bytes: Uint8Array, at: i32): i32 {
    return <i32>bytes[at] | (<i32>bytes[at + 1] << 8);
}

function u32(bytes: Uint8Array, at: i32): i32 {
    return <i32>bytes[at] | (<i32>bytes[at + 1] << 8) | (<i32>bytes[at + 2] << 16) | (<i32>bytes[at + 3] << 24);
}

function tag(bytes: Uint8Array, at: i32, t: string): bool {
    for (let i = 0; i < 4; i++) if (<i32>bytes[at + i] != t.charCodeAt(i)) return false;
    return true;
}

/// Reads a RIFF/WAVE header: format, channels, rate and where the samples are.
export function parseWAVHeader(buffer: ArrayBuffer): WAVInfo {
    const info = new WAVInfo();
    const bytes = Uint8Array.wrap(buffer);
    const n = bytes.length;
    if (n < 12 || !tag(bytes, 0, "RIFF") || !tag(bytes, 8, "WAVE")) {
        info.error = "not a WAV file (RIFF/WAVE): Rive decodes MP3 and FLAC only from its audio assets";
        return info;
    }
    let pos = 12;
    let haveFormat = false;
    while (pos + 8 <= n) {
        const size = u32(bytes, pos + 4);
        const body = pos + 8;
        if (tag(bytes, pos, "fmt ") && body + 16 <= n) {
            let format = u16(bytes, body);
            info.channels = u16(bytes, body + 2);
            info.sampleRate = <f64>u32(bytes, body + 4);
            info.bitsPerSample = u16(bytes, body + 14);
            if (format == 0xfffe && size >= 40 && body + 26 <= n) format = u16(bytes, body + 24);
            info.format = format;
            haveFormat = true;
        } else if (tag(bytes, pos, "data")) {
            info.dataOffset = body;
            info.dataLength = min<i32>(size, n - body);
            break;
        }
        if (size < 0) break;
        pos = body + size + (size & 1);
    }
    if (!haveFormat || info.dataOffset == 0) {
        info.error = "WAV without a fmt or data chunk";
        return info;
    }
    const bits = info.bitsPerSample;
    const pcm = info.format == 1 && (bits == 8 || bits == 16 || bits == 24 || bits == 32);
    const float = info.format == 3 && (bits == 32 || bits == 64);
    if (!pcm && !float) {
        info.error = "WAV format " + info.format.toString() + " with " + bits.toString() + "-bit samples is not supported (PCM or float only)";
        return info;
    }
    if (info.channels <= 0 || info.sampleRate <= 0) {
        info.error = "WAV with no channels or no sample rate";
        return info;
    }
    info.frames = info.dataLength / (info.channels * (bits / 8));
    return info;
}

/// Converts a WAV's samples to interleaved f32 frames (at most two
/// channels) in a shared Blob: the job behind decodeAudioData.
@job export function decodeWAV(buffer: ArrayBuffer, info: WAVInfo): Blob {
    const bytes = Uint8Array.wrap(buffer);
    const channels = info.channels;
    const outChannels = min<i32>(channels, 2);
    const bytesPer = info.bitsPerSample / 8;
    const frames = info.frames;
    const out = new Float32Array(frames * outChannels);
    const view = new DataView(buffer);
    for (let f = 0; f < frames; f++) {
        for (let c = 0; c < outChannels; c++) {
            const at = info.dataOffset + (f * channels + c) * bytesPer;
            let v: f64 = 0;
            if (info.format == 3) {
                v = bytesPer == 4 ? <f64>view.getFloat32(at, true) : view.getFloat64(at, true);
            } else if (bytesPer == 1) {
                v = (<f64>bytes[at] - 128) / 128;
            } else if (bytesPer == 2) {
                v = <f64>view.getInt16(at, true) / 32768;
            } else if (bytesPer == 3) {
                let s = <i32>bytes[at] | (<i32>bytes[at + 1] << 8) | (<i32>bytes[at + 2] << 16);
                if ((s & 0x800000) != 0) s |= 0xff000000;
                v = <f64>s / 8388608;
            } else {
                v = <f64>view.getInt32(at, true) / 2147483648;
            }
            out[f * outChannels + c] = <f32>v;
        }
    }
    return Blob.fromArray(out);
}
