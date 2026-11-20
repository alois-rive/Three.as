// A WAV decoder for audio that does not come from a Rive audio asset
// (fetched urls, blob assets, decodeAudioData): Rive decodes WAV, MP3 and
// FLAC only from its own AudioAssets (AudioSource.toBlob), so bytes are
// decoded here. PCM 8, 16, 24 and 32-bit and IEEE float 32 and 64-bit, plain
// or WAVE_FORMAT_EXTENSIBLE. Channels past the second are dropped.

import { Blob } from "rive/shared";
import { BinaryReader } from "rive/binary_reader";

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

/// Reads a RIFF/WAVE header: format, channels, rate and where the samples are.
export function parseWAVHeader(buffer: ArrayBuffer): WAVInfo {
    const info = new WAVInfo();
    const reader = new BinaryReader(buffer);
    const n: u32 = reader.byteLength;
    if (n < 12 || reader.readString(4) != "RIFF") {
        info.error = "not a WAV file (RIFF/WAVE): Rive decodes MP3 and FLAC only from its audio assets";
        return info;
    }
    reader.skip(4);   // RIFF chunk size
    if (reader.readString(4) != "WAVE" || reader.didOverflow) {
        info.error = "not a WAV file (RIFF/WAVE): Rive decodes MP3 and FLAC only from its audio assets";
        return info;
    }
    let haveFormat = false;
    while (reader.remaining >= 8) {
        const id = reader.readString(4);
        const size = reader.readUint32();
        const body = reader.position;
        const avail = reader.remaining;
        if (id == "fmt " && avail >= 16) {
            const sub = reader.slice(min<u32>(size, avail));
            let format = <i32>sub.readUint16();
            info.channels = <i32>sub.readUint16();
            info.sampleRate = <f64>sub.readUint32();
            sub.skip(6);   // byteRate + blockAlign
            info.bitsPerSample = <i32>sub.readUint16();
            if (format == 0xfffe && size >= 40 && sub.remaining >= 10) {
                sub.skip(8);   // cbSize + validBits + channelMask
                format = <i32>sub.readUint16();
            }
            info.format = format;
            haveFormat = true;
            const pad: u32 = size & 1;
            if (size >= avail || size + pad > avail) break;
            reader.position = body + size + pad;
        } else if (id == "data") {
            info.dataOffset = <i32>body;
            info.dataLength = <i32>min<u32>(size, avail);
            if (haveFormat) break;
            const pad: u32 = size & 1;
            if (size >= avail || size + pad > avail) break;
            reader.position = body + size + pad;
        } else {
            const pad: u32 = size & 1;
            if (size >= avail || size + pad > avail) break;
            reader.position = body + size + pad;
        }
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
    const channels = info.channels;
    const outChannels = min<i32>(channels, 2);
    const bytesPer = info.bitsPerSample / 8;
    const frames = info.frames;
    const out = new Float32Array(frames * outChannels);
    const reader = new BinaryReader(buffer, info.dataOffset, info.dataLength);
    const skipExtra: u32 = <u32>((channels - outChannels) * bytesPer);
    for (let f = 0; f < frames; f++) {
        for (let c = 0; c < outChannels; c++) {
            let v: f64 = 0;
            if (info.format == 3) {
                v = bytesPer == 4 ? <f64>reader.readFloat32() : reader.readFloat64();
            } else if (bytesPer == 1) {
                v = (<f64>reader.readByte() - 128) / 128;
            } else if (bytesPer == 2) {
                v = <f64>reader.read<i16>() / 32768;
            } else if (bytesPer == 3) {
                const b0 = <i32>reader.readByte();
                const b1 = <i32>reader.readByte();
                const b2 = <i32>reader.readByte();
                let s = b0 | (b1 << 8) | (b2 << 16);
                if ((s & 0x800000) != 0) s |= 0xff000000;
                v = <f64>s / 8388608;
            } else {
                v = <f64>reader.read<i32>() / 2147483648;
            }
            out[f * outChannels + c] = <f32>v;
        }
        if (skipExtra > 0) reader.skip(skipExtra);
    }
    return Blob.fromArray(out);
}
