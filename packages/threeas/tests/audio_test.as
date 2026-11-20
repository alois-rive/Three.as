// M17 spatial audio: the panner, filter and analyser math, the WAV decoder,
// the mixer (MixCore, driven directly as the audio thread would), the
// voice parameters PositionalAudio publishes, and the mixer's cost per
// block: rive . --test (rive . --test --aot for compiled timings).

import { Expect, Tests } from "rive/test";
import { Blob } from "rive/shared";
import { clock } from "rive/os";
import {
    distanceGain, coneGain, azimuthElevation, equalPowerMatrix, interauralDelay, headShadowCutoffs,
    biquadCoefficients, BIQUAD_TYPES, fft, toDecibels, computedPlaybackRate,
} from "../three/audio/AudioMath";
import {
    MixCore, MIX_MAX_BUFFERS, MIX_MAX_FFT, P_STRIDE, P_SOURCE, P_GEN, P_PLAYING, P_DELAY, P_LOOP, P_RATE,
    P_LL, P_RR, P_LR, P_RL, P_GAIN, P_MASTER, P_ANALYSER, P_DURATION, P_FREQUENCY, P_STOP_GEN, P_STOP_DELAY,
    P_ITD_L, P_ITD_R, P_LPF_L, P_LPF_R, P_FILTERS, P_FILTER0, S_STRIDE, S_ENDED, S_POSITION, S_STATE, S_GEN,
    S_SOURCE, VOICE_IDLE, VOICE_HELD, VOICE_PLAYING, SOURCE_SINE, MixAnalyserFrame,
} from "../three/audio/AudioMixer";
import { AnalyserNode, AudioBuffer, BiquadFilterNode } from "../three/audio/AudioNodes";
import { AudioListener } from "../three/audio/AudioListener";
import { Audio } from "../three/audio/Audio";
import { PositionalAudio } from "../three/audio/PositionalAudio";
import { AudioAnalyser } from "../three/audio/AudioAnalyser";
import { parseWAVHeader, decodeWAV } from "../three/audio/WAV";
import { PositionalAudioHelper } from "../three/addons/helpers/PositionalAudioHelper";

@editTime
function near(expect: Expect, actual: f64, want: f64, eps: f64 = 1e-6): void {
    expect.that(Math.abs(actual - want)).lessThan(eps);
}

const RATE: f64 = 48000;
const BLOCK: i32 = 512;

/// A mono buffer slot 0 holding `frames` of a sine with whole cycles.
@editTime
function sineCore(frames: i32, cycles: f64): MixCore {
    const core = new MixCore();
    core.init(RATE, BLOCK, 2);
    const data = new Float32Array(frames);
    for (let i = 0; i < frames; i++) data[i] = <f32>(0.5 * Math.sin(2 * Math.PI * cycles * <f64>i / <f64>frames));
    core.setBuffer(0, Blob.fromArray(data), 1, RATE, frames);
    return core;
}

/// Plays slot 0 on voice `v` (centred, unity gain).
@editTime
function playVoice(core: MixCore, v: i32, gen: f64, loop: bool): void {
    const p = core.params.data;
    const b = v * P_STRIDE;
    p[b + P_SOURCE] = 0;
    p[b + P_GEN] = gen;
    p[b + P_PLAYING] = 1;
    p[b + P_LOOP] = loop ? 1 : 0;
    p[b + P_RATE] = 1;
    p[b + P_LL] = 1; p[b + P_RR] = 1;
    p[b + P_GAIN] = 1; p[b + P_MASTER] = 1;
    p[b + P_ANALYSER] = -1;
    core.params.tick += 1;
}

/// Renders `blocks` blocks; returns the left channel.
@editTime
function renderLeft(core: MixCore, blocks: i32): Float32Array {
    const out = new StaticArray<f32>(BLOCK * 2);
    const left = new Float32Array(blocks * BLOCK);
    for (let b = 0; b < blocks; b++) {
        for (let i = 0; i < BLOCK * 2; i++) out[i] = 0;
        core.params.tick += 1;
        core.render(out, BLOCK);
        for (let i = 0; i < BLOCK; i++) left[b * BLOCK + i] = out[i * 2];
    }
    return left;
}

@editTime
function maxStep(x: Float32Array, from: i32, to: i32): f64 {
    let m: f64 = 0;
    for (let i = max<i32>(from, 1); i < min<i32>(to, x.length); i++) m = Math.max(m, Math.abs(<f64>x[i] - <f64>x[i - 1]));
    return m;
}

export class AudioTests extends Tests {
    override run(): void {
        group("distance models (Web Audio)", () => {
            test("inverse: ref / (ref + rolloff (d - ref)), clamped below ref", (expect) => {
                near(expect, distanceGain("inverse", 0.5, 1, 10000, 1), 1);
                near(expect, distanceGain("inverse", 2, 1, 10000, 1), 0.5);
                near(expect, distanceGain("inverse", 4, 2, 10000, 0.5), 2 / (2 + 0.5 * 2));
            });
            test("linear: 1 - rolloff (d - ref) / (max - ref), clamped to [ref, max]", (expect) => {
                near(expect, distanceGain("linear", 1, 1, 11, 1), 1);
                near(expect, distanceGain("linear", 6, 1, 11, 1), 0.5);
                near(expect, distanceGain("linear", 50, 1, 11, 1), 0);
                near(expect, distanceGain("linear", 6, 1, 11, 2), 0.5);   // rolloff clamped to 1
                near(expect, distanceGain("linear", 6, 1, 11, 0.5), 0.75);
            });
            test("exponential: (d / ref) ^ -rolloff", (expect) => {
                near(expect, distanceGain("exponential", 4, 1, 10000, 1), 0.25);
                near(expect, distanceGain("exponential", 4, 2, 10000, 2), 0.25);
                near(expect, distanceGain("exponential", 1, 2, 10000, 2), 1);
            });
        });

        group("sound cones", () => {
            test("omnidirectional by default", (expect) => {
                near(expect, coneGain(0, 0, 0, 0, 0, 1, 0, 0, -5, 360, 360, 0), 1);
            });
            test("inner, between and outer", (expect) => {
                // Source at the origin facing +Z; listener in front, at 45 deg, behind.
                near(expect, coneGain(0, 0, 0, 0, 0, 1, 0, 0, 5, 60, 180, 0.2), 1);
                // 60 deg off axis: halfway between the inner (30) and outer (90) half angles.
                const s = Math.sin(Math.PI / 3), c = Math.cos(Math.PI / 3);
                near(expect, coneGain(0, 0, 0, 0, 0, 1, 5 * s, 0, 5 * c, 60, 180, 0.2), 0.6);
                near(expect, coneGain(0, 0, 0, 0, 0, 1, 0, 0, -5, 60, 180, 0.2), 0.2);
            });
        });

        group("azimuth and equal-power panning", () => {
            const out = new StaticArray<f64>(2);
            test("azimuth in the listener's frame", (expect) => {
                // Listener at the origin facing -Z, up +Y.
                azimuthElevation(2, 0, 0, 0, 0, 0, 0, 0, -1, 0, 1, 0, out);
                near(expect, out[0], 90);
                azimuthElevation(-2, 0, 0, 0, 0, 0, 0, 0, -1, 0, 1, 0, out);
                near(expect, out[0], -90);
                azimuthElevation(0, 0, -2, 0, 0, 0, 0, 0, -1, 0, 1, 0, out);
                near(expect, out[0], 0);
                azimuthElevation(2, 0, -2, 0, 0, 0, 0, 0, -1, 0, 1, 0, out);
                near(expect, out[0], 45);
                azimuthElevation(0, 3, 0, 0, 0, 0, 0, 0, -1, 0, 1, 0, out);
                near(expect, out[1], 90);
                // Turned to face +X: a source at +X is ahead.
                azimuthElevation(5, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, out);
                near(expect, out[0], 0);
            });
            test("mono: cos / sin of (azimuth + 90) / 180 quarter turns", (expect) => {
                const m = new StaticArray<f64>(4);
                equalPowerMatrix(0, 1, m);
                near(expect, m[0], Math.SQRT1_2);
                near(expect, m[3], Math.SQRT1_2);
                equalPowerMatrix(90, 1, m);
                near(expect, m[0], 0);
                near(expect, m[3], 1);
                equalPowerMatrix(45, 1, m);
                near(expect, m[0], Math.cos(0.75 * Math.PI / 2));
                near(expect, m[3], Math.sin(0.75 * Math.PI / 2));
                // Behind folds onto the front: 135 sounds as 45.
                equalPowerMatrix(135, 1, m);
                near(expect, m[3], Math.sin(0.75 * Math.PI / 2));
                // Power is constant.
                for (let a = -180; a <= 180; a += 15) {
                    equalPowerMatrix(<f64>a, 1, m);
                    near(expect, m[0] * m[0] + m[3] * m[3], 1);
                }
            });
            test("stereo: the far side's channel folds into the near one", (expect) => {
                const m = new StaticArray<f64>(4);
                equalPowerMatrix(0, 2, m);
                near(expect, m[0], 1);
                near(expect, m[3], 1);
                near(expect, m[1], 0);
                equalPowerMatrix(90, 2, m);
                near(expect, m[0], 0);   // left input leaves the left output
                near(expect, m[2], 1);   // ...for the right
                near(expect, m[3], 1);
                equalPowerMatrix(-90, 2, m);
                near(expect, m[1], 1);
                near(expect, m[3], 0);
            });
            test("interaural delay and head shadow", (expect) => {
                near(expect, interauralDelay(0), 0);
                near(expect, interauralDelay(90), 0.0875 / 343 * (Math.PI / 2 + 1));
                near(expect, interauralDelay(-90), interauralDelay(90));
                const c = new StaticArray<f64>(2);
                headShadowCutoffs(0, c);
                near(expect, c[0], 20000, 1e-6);
                near(expect, c[1], 20000, 1e-6);
                headShadowCutoffs(90, c);
                near(expect, c[0], 3000, 1e-6);    // the left ear is in the shadow
                near(expect, c[1], 20000, 1e-6);
                headShadowCutoffs(180, c);
                near(expect, c[0], 9000, 1e-6);
            });
        });

        group("filters and analysis", () => {
            test("biquad lowpass: unity at DC, zero at Nyquist; peaking: its gain at f0", (expect) => {
                const k = new StaticArray<f64>(5);
                biquadCoefficients("lowpass", 1000, 1, 0, 0, RATE, k, 0);
                near(expect, (k[0] + k[1] + k[2]) / (1 + k[3] + k[4]), 1, 1e-9);
                near(expect, (k[0] - k[1] + k[2]) / (1 - k[3] + k[4]), 0, 1e-9);
                biquadCoefficients("peaking", 1000, 1, 6, 0, RATE, k, 0);
                // |H(e^jw0)|
                const w = 2 * Math.PI * 1000 / RATE;
                const nr = k[0] + k[1] * Math.cos(w) + k[2] * Math.cos(2 * w), ni = -k[1] * Math.sin(w) - k[2] * Math.sin(2 * w);
                const dr = 1 + k[3] * Math.cos(w) + k[4] * Math.cos(2 * w), di = -k[3] * Math.sin(w) - k[4] * Math.sin(2 * w);
                const h = Math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
                near(expect, 20 * Math.log10(h), 6, 1e-6);
                const node = new BiquadFilterNode();
                expect.that(node.type).is("lowpass");
                near(expect, node.frequency.value, 350);
            });
            test("biquad stability at DC, Nyquist, extreme Q and gain", (expect) => {
                const k = new StaticArray<f64>(5);
                const g6 = Math.pow(10, 6 / 20);
                // Exact W3C Web Audio boundary responses at f0 = 0 and f0 >= Nyquist.
                const dcWant: Array<f64> = [0, 1, 0, 1, g6, 1, 1, 1];
                const nyqWant: Array<f64> = [1, 0, 0, g6, 1, 1, 1, 1];
                for (let t = 0; t < BIQUAD_TYPES.length; t++) {
                    const typ = BIQUAD_TYPES[t];
                    biquadCoefficients(typ, 0, 1, 6, 0, RATE, k, 0);
                    near(expect, k[0], dcWant[t], 1e-6);
                    near(expect, k[1], 0); near(expect, k[2], 0);
                    near(expect, k[3], 0); near(expect, k[4], 0);

                    biquadCoefficients(typ, RATE / 2, 1, 6, 0, RATE, k, 0);
                    near(expect, k[0], nyqWant[t], 1e-6);
                    near(expect, k[1], 0); near(expect, k[2], 0);
                    near(expect, k[3], 0); near(expect, k[4], 0);

                    biquadCoefficients(typ, RATE, 1, 6, 0, RATE, k, 0);
                    near(expect, k[0], nyqWant[t], 1e-6);
                }

                // Extreme / hostile parameter sweeps: every 1000-sample f32 TDF-II
                // impulse response must stay finite and bounded (zero NaN/Infinity).
                const freqs: Array<f64> = [-100, 0, 1e-8, 1000, RATE / 2 - 1e-6, RATE / 2, RATE * 2, NaN, Infinity];
                const qs: Array<f64> = [-1e6, -5, 0, 1e-6, 1, 100, 1e6, NaN];
                const gains: Array<f64> = [-1000, 0, 1000, NaN];
                for (let t = 0; t < BIQUAD_TYPES.length; t++) {
                    const typ = BIQUAD_TYPES[t];
                    for (let fi = 0; fi < freqs.length; fi++) {
                        for (let qi = 0; qi < qs.length; qi++) {
                            for (let gi = 0; gi < gains.length; gi++) {
                                biquadCoefficients(typ, freqs[fi], qs[qi], gains[gi], 0, RATE, k, 0);
                                const b0 = <f32>k[0], b1 = <f32>k[1], b2 = <f32>k[2];
                                const a1 = <f32>k[3], a2 = <f32>k[4];
                                expect.that(isFinite(<f64>b0) && isFinite(<f64>b1) && isFinite(<f64>b2) &&
                                    isFinite(<f64>a1) && isFinite(<f64>a2)).is(true);
                                let z1: f32 = 0, z2: f32 = 0;
                                let ok = true;
                                for (let n = 0; n < 1000; n++) {
                                    const x: f32 = n == 0 ? 1 : 0;
                                    const y = b0 * x + z1;
                                    z1 = b1 * x - a1 * y + z2;
                                    z2 = b2 * x - a2 * y;
                                    if (!isFinite(<f64>y) || Math.abs(<f64>y) > 1e12) { ok = false; break; }
                                }
                                expect.that(ok).is(true);
                            }
                        }
                    }
                }
                // Invalid sampleRate falls back to unity bypass.
                biquadCoefficients("lowpass", 1000, 1, 0, 0, 0, k, 0);
                near(expect, k[0], 1);
                near(expect, k[3], 0);
                near(expect, k[4], 0);
            });
            test("FFT of a sine peaks at its bin", (expect) => {
                const n = 256;
                const re = new Float64Array(n), im = new Float64Array(n);
                for (let i = 0; i < n; i++) re[i] = Math.sin(2 * Math.PI * 10 * <f64>i / <f64>n);
                fft(re, im);
                near(expect, Math.sqrt(re[10] * re[10] + im[10] * im[10]), <f64>n / 2, 1e-6);
                near(expect, Math.sqrt(re[11] * re[11] + im[11] * im[11]), 0, 1e-6);
            });
            test("AnalyserNode: byte data peaks at a 1 kHz tone's bin", (expect) => {
                const analyser = new AnalyserNode();
                analyser.fftSize = 2048;
                analyser.smoothingTimeConstant = 0;
                const tone = new Float32Array(2048);
                for (let i = 0; i < 2048; i++) tone[i] = <f32>(0.01 * Math.sin(2 * Math.PI * 1000 * <f64>i / RATE));
                analyser.setSamples(tone, 2048);
                const data = new Uint8Array(analyser.frequencyBinCount);
                analyser.getByteFrequencyData(data);
                let peak = 0;
                for (let i = 1; i < data.length; i++) if (data[i] > data[peak]) peak = i;
                // 1000 Hz / (48000 / 2048) = bin 42.7
                expect.that(peak == 42 || peak == 43).is(true);
                // 0.01 x 0.42 (the window) / 2 = -53.6 dB: byte 255 x 46.4 / 70 = 169.
                expect.that(<i32>data[peak]).greaterThan(160);
                expect.that(<i32>data[peak]).lessThan(175);
                expect.that(<i32>data[200]).lessThan(<i32>data[peak] / 2);
                near(expect, toDecibels(0.1), -20);
                near(expect, computedPlaybackRate(1, 1200), 2);
            });
        });

        group("WAV decoding", () => {
            test("16-bit PCM", (expect) => {
                const frames = 4;
                const bytes = new Uint8Array(44 + frames * 2 * 2);
                const view = new DataView(bytes.buffer);
                const tags = ["RIFF", "WAVE", "fmt ", "data"];
                const at = [0, 8, 12, 36];
                for (let t = 0; t < 4; t++) for (let i = 0; i < 4; i++) bytes[at[t] + i] = <u8>tags[t].charCodeAt(i);
                view.setUint32(4, 36 + frames * 4, true);
                view.setUint32(16, 16, true);
                view.setUint16(20, 1, true);
                view.setUint16(22, 2, true);
                view.setUint32(24, 22050, true);
                view.setUint32(28, 22050 * 4, true);
                view.setUint16(32, 4, true);
                view.setUint16(34, 16, true);
                view.setUint32(40, frames * 4, true);
                for (let i = 0; i < frames * 2; i++) view.setInt16(44 + i * 2, <i16>(i * 4096 - 16384), true);
                const info = parseWAVHeader(bytes.buffer);
                expect.that(info.error).is("");
                expect.that(info.channels).is(2);
                expect.that(info.frames).is(frames);
                near(expect, info.sampleRate, 22050);
                const blob = decodeWAV(bytes.buffer, info);
                const out = new Float32Array(frames * 2);
                blob.readInto(0, out);
                near(expect, <f64>out[0], -0.5);
                near(expect, <f64>out[7], (7 * 4096 - 16384) / 32768);
                expect.that(parseWAVHeader(new ArrayBuffer(16)).error.length > 0).is(true);
            });
            test("data before fmt and malformed chunk sizes", (expect) => {
                // data chunk before fmt chunk
                const bytes = new Uint8Array(52);
                const view = new DataView(bytes.buffer);
                const tags = ["RIFF", "WAVE", "data", "fmt "];
                const offs = [0, 8, 12, 28];
                for (let t = 0; t < 4; t++) for (let i = 0; i < 4; i++) bytes[offs[t] + i] = <u8>tags[t].charCodeAt(i);
                view.setUint32(4, 44, true);
                view.setUint32(16, 8, true);   // 4 mono 16-bit samples
                view.setInt16(20, 16384, true);
                view.setUint32(32, 16, true);
                view.setUint16(36, 1, true);   // PCM
                view.setUint16(38, 1, true);   // mono
                view.setUint32(40, 48000, true);
                view.setUint32(44, 96000, true);
                view.setUint16(48, 2, true);
                view.setUint16(50, 16, true);
                const info = parseWAVHeader(bytes.buffer);
                expect.that(info.error).is("");
                expect.that(info.frames).is(4);
                expect.that(info.channels).is(1);
                // 0xFFFFFFFF chunk size must not hang or crash
                const bad = new Uint8Array(24);
                const bv = new DataView(bad.buffer);
                for (let i = 0; i < 4; i++) bad[i] = <u8>"RIFF".charCodeAt(i);
                for (let i = 0; i < 4; i++) bad[8 + i] = <u8>"WAVE".charCodeAt(i);
                for (let i = 0; i < 4; i++) bad[12 + i] = <u8>"JUNK".charCodeAt(i);
                bv.setUint32(16, 0xFFFFFFFF, true);
                expect.that(parseWAVHeader(bad.buffer).error.length > 0).is(true);
            });
        });

        group("the mixer (MixCore)", () => {
            test("a loop is seamless: the output is the buffer, tiled", (expect) => {
                // 1000 frames holding 5 whole cycles: the loop point falls mid-block.
                const core = sineCore(1000, 5);
                playVoice(core, 0, 1, true);
                const left = renderLeft(core, 8);
                let err: f64 = 0;
                for (let i = 0; i < left.length; i++) {
                    const want = 0.5 * Math.sin(2 * Math.PI * 5 * <f64>(i % 1000) / 1000);
                    err = Math.max(err, Math.abs(<f64>left[i] - want));
                }
                expect.that(err).lessThan(1e-6);
            });
            test("loopStart / loopEnd and playback rate", (expect) => {
                const core = sineCore(1000, 5);
                playVoice(core, 0, 1, true);
                const p = core.params.data;
                p[P_RATE] = 2;
                p[7] = 200 / RATE;   // P_LOOP_START
                p[8] = 600 / RATE;   // P_LOOP_END
                const left = renderLeft(core, 4);
                // After the first pass the read position stays in [200, 600).
                const pos = core.status.data[S_POSITION] * RATE;
                expect.that(pos).greaterThanOrEqual(200);
                expect.that(pos).lessThan(600);
                // At twice the rate, frame i reads source frame 2i (until the loop).
                near(expect, <f64>left[50], 0.5 * Math.sin(2 * Math.PI * 5 * 100 / 1000), 1e-6);
            });
            test("stop fades out over 10 ms, then holds; ended plays are reported", (expect) => {
                const core = sineCore(4800, 100);
                playVoice(core, 0, 1, true);
                renderLeft(core, 2);
                core.params.data[P_PLAYING] = 0;
                core.params.data[P_STOP_GEN] = 2;
                const left = renderLeft(core, 2);
                // No sample-to-sample jump beyond the sine's own slope.
                expect.that(maxStep(left, 0, left.length)).lessThan(0.5 * 2 * Math.PI * 1000 / RATE + 1e-3);
                // Silent after the fade (480 frames).
                let tail: f64 = 0;
                for (let i = 500; i < left.length; i++) tail = Math.max(tail, Math.abs(<f64>left[i]));
                expect.that(tail).is(0);
                expect.that(<i32>core.status.data[S_STATE]).is(VOICE_HELD);
                // A one-shot reports its generation once it ends.
                const shot = sineCore(1000, 5);
                playVoice(shot, 0, 7, false);
                renderLeft(shot, 3);
                near(expect, shot.status.data[S_ENDED], 7);
            });
            test("pause holds the position and resume fades back in", (expect) => {
                const core = sineCore(48000, 1000);
                playVoice(core, 0, 1, true);
                renderLeft(core, 2);
                core.params.data[P_PLAYING] = 0;
                renderLeft(core, 2);
                const held = core.status.data[S_POSITION];
                renderLeft(core, 2);
                near(expect, core.status.data[S_POSITION], held);
                core.params.data[P_PLAYING] = 1;
                const left = renderLeft(core, 2);
                expect.that(<i32>core.status.data[S_STATE]).is(VOICE_PLAYING);
                expect.that(Math.abs(<f64>left[0])).lessThan(0.01);   // fading in, not jumping
                expect.that(core.status.data[S_POSITION]).greaterThan(held);
            });
            test("duration ends a play", (expect) => {
                const core = sineCore(4800, 100);
                playVoice(core, 0, 3, true);
                core.params.data[P_DURATION] = 0.02;   // 960 frames
                renderLeft(core, 4);
                near(expect, core.status.data[S_ENDED], 3);
            });
            test("panning matrix, interaural delay and head shadow", (expect) => {
                const core = sineCore(4800, 100);
                playVoice(core, 0, 1, true);
                const p = core.params.data;
                p[P_LL] = 0; p[P_RR] = 0.5;
                p[P_ITD_L] = 0.0006; p[P_LPF_L] = 3000; p[P_LPF_R] = 0;
                const out = new StaticArray<f32>(BLOCK * 2);
                let peakL: f64 = 0, peakR: f64 = 0;
                for (let b = 0; b < 4; b++) {
                    for (let i = 0; i < BLOCK * 2; i++) out[i] = 0;
                    core.params.tick += 1;
                    core.render(out, BLOCK);
                    for (let i = 0; i < BLOCK; i++) {
                        peakL = Math.max(peakL, Math.abs(<f64>out[i * 2]));
                        peakR = Math.max(peakR, Math.abs(<f64>out[i * 2 + 1]));
                    }
                }
                near(expect, peakL, 0);
                near(expect, peakR, 0.25, 1e-3);
            });
            test("an oscillator and the analyser tap", (expect) => {
                const core = new MixCore();
                core.init(RATE, BLOCK, 2);
                const p = core.params.data;
                playVoice(core, 0, 1, false);
                p[P_SOURCE] = <f64>SOURCE_SINE;
                p[P_FREQUENCY] = 1000;
                p[P_ANALYSER] = 0;
                renderLeft(core, 8);
                const frame = new MixAnalyserFrame();
                core.fillAnalyserFrame(0, frame);
                expect.that(frame.written).is(<f64>(8 * BLOCK));
                const analyser = new AnalyserNode();
                analyser.fftSize = 2048;
                analyser.smoothingTimeConstant = 0;
                analyser.frame = frame;
                const data = new Float32Array(1024);
                analyser.getFloatFrequencyData(data);
                let peak = 0;
                for (let i = 1; i < data.length; i++) if (data[i] > data[peak]) peak = i;
                expect.that(peak == 42 || peak == 43).is(true);
            });
            test("NaN samples, params and filter coeffs do not poison the mix bus or latch", (expect) => {
                const core = new MixCore();
                core.init(RATE, BLOCK, 2);
                const bad = new Float32Array(BLOCK);
                for (let i = 0; i < BLOCK; i++) bad[i] = i == 10 ? <f32>NaN : (i == 20 ? <f32>Infinity : <f32>0.25);
                core.setBuffer(0, Blob.fromArray(bad), 1, RATE, BLOCK);
                const clean = new Float32Array(BLOCK);
                for (let i = 0; i < BLOCK; i++) clean[i] = <f32>(0.5 * Math.sin(2 * Math.PI * 10 * <f64>i / <f64>BLOCK));
                core.setBuffer(1, Blob.fromArray(clean), 1, RATE, BLOCK);

                // Voice 0 plays buffer with NaN/Inf samples + NaN gain + NaN filter + head shadow.
                playVoice(core, 0, 1, true);
                const p = core.params.data;
                p[P_GAIN] = NaN;
                p[P_LPF_L] = 3000;
                p[P_FILTERS] = 1;
                p[P_FILTER0] = NaN;
                p[P_FILTER0 + 3] = -2;
                p[P_FILTER0 + 4] = 1;

                // Voice 1 plays a clean sine on the same bus.
                playVoice(core, 1, 2, true);
                p[P_STRIDE + P_SOURCE] = 1;

                const left1 = renderLeft(core, 2);
                let allFinite = true;
                let maxErr: f64 = 0;
                for (let i = 0; i < left1.length; i++) {
                    if (!isFinite(<f64>left1[i])) allFinite = false;
                    // Voice 0's NaN gain sanitizes to 0, so voice 1 passes cleanly.
                    const want = 0.5 * Math.sin(2 * Math.PI * 10 * <f64>(i % BLOCK) / <f64>BLOCK);
                    maxErr = Math.max(maxErr, Math.abs(<f64>left1[i] - want));
                }
                expect.that(allFinite).is(true);
                expect.that(maxErr).lessThan(1e-5);

                // Restore voice 0's gain & filter and mute voice 1: voice 0 must recover cleanly.
                p[P_GAIN] = 1;
                biquadCoefficients("lowpass", 4000, 1, 0, 0, RATE, p, P_FILTER0);
                p[P_STRIDE + P_GAIN] = 0;
                const left2 = renderLeft(core, 4);
                let peak: f64 = 0;
                allFinite = true;
                for (let i = 0; i < left2.length; i++) {
                    if (!isFinite(<f64>left2[i])) allFinite = false;
                    peak = Math.max(peak, Math.abs(<f64>left2[i]));
                }
                expect.that(allFinite).is(true);
                expect.that(peak).greaterThan(0.1);
            });
            test("invalid buffer metadata (channels > 2 or sampleRate <= 0) is rejected safely", (expect) => {
                const core = new MixCore();
                core.init(RATE, BLOCK, 2);
                const data = new Float32Array(256);
                for (let i = 0; i < 256; i++) data[i] = 0.5;
                const blob = Blob.fromArray(data);
                core.setBuffer(0, blob, 4, RATE, 64);      // channels > 2
                core.setBuffer(1, blob, 0, RATE, 64);      // channels <= 0
                core.setBuffer(2, blob, 1, 0, 256);        // sampleRate == 0
                core.setBuffer(3, blob, 1, -48000, 256);   // sampleRate < 0
                for (let v = 0; v < 4; v++) {
                    playVoice(core, v, <f64>(v + 1), true);
                    core.params.data[v * P_STRIDE + P_SOURCE] = <f64>v;
                }
                const left = renderLeft(core, 2);
                let maxAbs: f64 = 0;
                let allFinite = true;
                for (let i = 0; i < left.length; i++) {
                    if (!isFinite(<f64>left[i])) allFinite = false;
                    maxAbs = Math.max(maxAbs, Math.abs(<f64>left[i]));
                }
                expect.that(allFinite).is(true);
                expect.that(maxAbs).is(0);
                for (let v = 0; v < 4; v++) {
                    expect.that(isFinite(core.status.data[v * S_STRIDE + S_POSITION])).is(true);
                }
            });
            test("delayed play followed by immediate stop emits pure silence (no 10 ms burst)", (expect) => {
                const core = sineCore(4800, 100);
                playVoice(core, 0, 1, true);
                core.params.data[P_DELAY] = 0.02;   // 960 frames (~2 blocks)
                // Render 1 block while still waiting in delay.
                const b0 = renderLeft(core, 1);
                let peak: f64 = 0;
                for (let i = 0; i < b0.length; i++) peak = Math.max(peak, Math.abs(<f64>b0[i]));
                expect.that(peak).is(0);
                // Stop before the delay expires.
                core.params.data[P_PLAYING] = 0;
                core.params.data[P_STOP_GEN] = 2;
                core.params.data[P_STOP_DELAY] = 0;
                const rest = renderLeft(core, 6);
                for (let i = 0; i < rest.length; i++) peak = Math.max(peak, Math.abs(<f64>rest[i]));
                expect.that(peak).is(0);
                expect.that(<i32>core.status.data[S_STATE]).is(VOICE_HELD);
            });
            test("toggling useDelay and useLpf from false to true produces no click", (expect) => {
                const core = sineCore(48000, 200);   // 200 Hz sine, max slope ~0.013/sample
                playVoice(core, 0, 1, true);
                const steady = renderLeft(core, 2);
                const naturalStep = maxStep(steady, 10, steady.length);
                // Enable ITD and head shadow mid-playback.
                const p = core.params.data;
                p[P_ITD_L] = 0.0006;
                p[P_LPF_L] = 3000;
                const on = renderLeft(core, 2);
                const boundaryJump = Math.abs(<f64>on[0] - <f64>steady[steady.length - 1]);
                expect.that(boundaryJump).lessThan(naturalStep * 2 + 1e-3);
                expect.that(maxStep(on, 0, on.length)).lessThan(naturalStep * 2 + 1e-3);
                // Turn off, let settle, then turn back on again.
                p[P_ITD_L] = 0;
                p[P_LPF_L] = 0;
                const off = renderLeft(core, 10);
                p[P_ITD_L] = 0.0006;
                p[P_LPF_L] = 3000;
                const on2 = renderLeft(core, 2);
                expect.that(Math.abs(<f64>on2[0] - <f64>off[off.length - 1])).lessThan(naturalStep * 2 + 1e-3);
                expect.that(maxStep(on2, 0, on2.length)).lessThan(naturalStep * 2 + 1e-3);
            });
            test("analyser tapWritten stays synchronized when starting mid-block (from > 0)", (expect) => {
                const core = sineCore(4800, 100);
                playVoice(core, 0, 1, true);
                core.params.data[P_DELAY] = 200 / RATE;   // starts at frame 200 inside block 0
                core.params.data[P_ANALYSER] = 0;
                renderLeft(core, 2);
                expect.that(core.tapWritten[0]).is(<f64>(2 * BLOCK));
                expect.that(core.tapWrite[0]).is((2 * BLOCK) & (MIX_MAX_FFT - 1));
                const frame = new MixAnalyserFrame();
                core.fillAnalyserFrame(0, frame);
                // First 200 frames of block 0 are silence; frames after 200 have signal.
                const base = MIX_MAX_FFT - 2 * BLOCK;
                let prePeak: f64 = 0, postPeak: f64 = 0;
                for (let i = 0; i < 200; i++) prePeak = Math.max(prePeak, Math.abs(<f64>frame.samples[base + i]));
                for (let i = 200; i < 2 * BLOCK; i++) postPeak = Math.max(postPeak, Math.abs(<f64>frame.samples[base + i]));
                expect.that(prePeak).is(0);
                expect.that(postPeak).greaterThan(0.1);
            });
            test("low-rate looping interpolates cleanly across window and loop boundaries", (expect) => {
                // 4096 frames (> WINDOW_FRAMES = 2048), played at 0.25x across loop wrap.
                const len = 4096;
                const core = sineCore(len, 16);
                playVoice(core, 0, 1, true);
                const p = core.params.data;
                p[P_RATE] = 0.25;
                // Start near the loop wrap (frame 4092) to exercise low-rate wrap interpolation.
                core.voices[0].winSlot = -1;
                p[3] = 4092 / RATE;   // P_OFFSET
                const out = renderLeft(core, 2);
                // After the 5 ms (240-frame) fade-in, sample i reads source position 4092 + 0.25 * i (mod 4096).
                // At i = 256, pos = 4156 mod 4096 = 60 (past the wrap!).
                // Verify continuity across the wrap at i = 16 (pos = 4096) and later steady samples.
                let allFinite = true;
                for (let i = 0; i < out.length; i++) if (!isFinite(<f64>out[i])) allFinite = false;
                expect.that(allFinite).is(true);
                expect.that(maxStep(out, 0, 64)).lessThan(0.05);
                // Verify exact value post-fade-in (i = 400 -> pos = 4192 mod 4096 = 96).
                const want = 0.5 * Math.sin(2 * Math.PI * 16 * 96 / <f64>len);
                near(expect, <f64>out[400], want, 1e-4);
            });
            test("cost per block", (expect) => {
                // Eight looping voices, panned, delayed and shadowed, two filtered.
                const core = sineCore(48000, 1000);
                const p = core.params.data;
                for (let v = 0; v < 8; v++) {
                    playVoice(core, v, <f64>(v + 1), true);
                    const b = v * P_STRIDE;
                    p[b + P_LL] = 0.7; p[b + P_RR] = 0.3;
                    p[b + P_ITD_R] = 0.0003; p[b + P_LPF_R] = 6000;
                }
                const out = new StaticArray<f32>(BLOCK * 2);
                const blocks = 50;
                const t0 = clock();
                for (let k = 0; k < blocks; k++) {
                    for (let i = 0; i < BLOCK * 2; i++) out[i] = 0;
                    core.params.tick += 1;
                    core.render(out, BLOCK);
                }
                const per = (clock() - t0) / <f64>blocks;
                const budget = <f64>BLOCK / RATE;
                console.log("audio: MixCore, 8 voices, " + BLOCK.toString() + "-frame block: " +
                    (per * 1000).toString() + " ms (" + (100 * per / budget).toString() + "% of the block's " +
                    (budget * 1000).toString() + " ms)");
                // An idle mixer costs next to nothing.
                const idle = new MixCore();
                idle.init(RATE, BLOCK, 2);
                const t1 = clock();
                for (let k = 0; k < blocks; k++) idle.render(out, BLOCK);
                const idlePer = (clock() - t1) / <f64>blocks;
                console.log("audio: idle MixCore block: " + (idlePer * 1000).toString() + " ms");
                expect.that(per).lessThan(budget);
            });
        });

        group("Audio, PositionalAudio and the listener", () => {
            test("a PositionalAudio publishes Web Audio's gains", (expect) => {
                const listener = new AudioListener();
                const sound = new PositionalAudio(listener);
                sound.position.set(2, 0, 0);
                const buffer = new AudioBuffer(1, 0, RATE);
                sound.setBuffer(buffer);
                sound.play();
                expect.that(sound.isPlaying).is(true);
                listener.update();
                const v = sound.voice;
                expect.that(v).greaterThanOrEqual(0);
                const p = listener.context.params.data;
                const b = v * P_STRIDE;
                near(expect, sound.distanceGain, 0.5);
                near(expect, sound.azimuth, 90);
                near(expect, p[b + P_LL], 0);
                near(expect, p[b + P_RR], 0.5);
                expect.that(p[b + P_ITD_L]).greaterThan(0.0006);   // HRTF: the left ear lags
                near(expect, p[b + P_ITD_R], 0);
                near(expect, p[b + P_LPF_L], 3000, 1e-6);
                // Equal power: no delay, no shadow.
                sound.panner.panningModel = "equalpower";
                sound.setDistanceModel("linear");
                sound.setMaxDistance(5);
                sound.position.set(0, 0, -3);
                listener.update();
                near(expect, sound.distanceGain, 0.5);
                near(expect, p[b + P_LL], 0.5 * Math.SQRT1_2);
                near(expect, p[b + P_ITD_L], 0);
                near(expect, p[b + P_LPF_L], 0);
                // Turning the listener turns the scene: facing +X.
                listener.rotation.y = -Math.PI / 2;
                sound.position.set(3, 0, 0);
                listener.update();
                near(expect, sound.azimuth, 0, 1e-6);
                // A cone facing away.
                sound.setDirectionalCone(90, 180, 0.25);
                sound.rotation.y = Math.PI / 2;   // its +Z now points at +X, away
                listener.update();
                near(expect, sound.coneGain, 0.25);
                // Volume and master volume.
                sound.setVolume(0.5);
                listener.setMasterVolume(0.8);
                listener.update();
                near(expect, p[b + P_GAIN], 0.5);
                near(expect, p[b + P_MASTER], 0.8);
                sound.stop();
                expect.that(sound.isPlaying).is(false);
            });
            test("a plain Audio is centred; filters and the analyser are wired", (expect) => {
                const listener = new AudioListener();
                const audio = new Audio(listener);
                audio.setBuffer(AudioBuffer.fromChannelData([new Float32Array(64)], RATE));
                const f = listener.context.createBiquadFilter();
                f.type = "highpass";
                audio.setFilter(f);
                listener.setFilter(listener.context.createBiquadFilter());
                const analyser = new AudioAnalyser(audio, 256);
                expect.that(analyser.data.length).is(128);
                audio.play();
                listener.update();
                const p = listener.context.params.data;
                const b = audio.voice * P_STRIDE;
                near(expect, p[b + P_LL], 1);
                near(expect, p[b + P_RR], 1);
                near(expect, p[b + P_LR], 0);
                near(expect, p[b + P_RL], 0);
                near(expect, p[b + 25], 2);   // P_FILTERS: the Audio's and the listener's
                near(expect, p[b + P_ANALYSER], 0);
                near(expect, p[b + P_SOURCE], 0);   // the buffer's slot
                // Silence analyses to zeros.
                near(expect, analyser.getAverageFrequency(), 0);
                audio.pause();
                expect.that(audio.paused).is(true);
                audio.play();
                expect.that(audio.isPlaying).is(true);
            });
            test("an oscillator source has no playback control", (expect) => {
                const listener = new AudioListener();
                const audio = new Audio(listener);
                const osc = listener.context.createOscillator();
                osc.type = "square";
                audio.setNodeSource(osc);
                expect.that(audio.hasPlaybackControl).is(false);
                osc.start();
                listener.update();
                expect.that(audio.isPlaying).is(true);
                const p = listener.context.params.data;
                near(expect, p[audio.voice * P_STRIDE + P_SOURCE], -3);
                near(expect, p[audio.voice * P_STRIDE + P_FREQUENCY], 440);
            });
            test("PositionalAudioHelper draws the cone", (expect) => {
                const listener = new AudioListener();
                const sound = new PositionalAudio(listener);
                sound.setDirectionalCone(60, 120, 0.1);
                const helper = new PositionalAudioHelper(sound, 2);
                expect.that(helper.geometry.drawRange.count).is(16 * 3 + 1);
                expect.that(helper.outer.geometry.drawRange.count).is(2 * (2 * 3 + 1));
                expect.that(helper.outer.visible).is(true);
                const pos = helper.geometry.getAttribute("position")!;
                // The inner cone's first arc point, 30 degrees left of +Z, `range` out.
                near(expect, pos.getX(1), Math.sin(-Math.PI / 6) * 2, 1e-5);
                near(expect, pos.getZ(1), Math.cos(-Math.PI / 6) * 2, 1e-5);
                sound.setDirectionalCone(90, 90, 0);
                helper.update();
                expect.that(helper.outer.visible).is(false);
            });
            test("AnalyserNode getFloatFrequencyData / get*TimeDomainData pull live samples from context", (expect) => {
                const listener = new AudioListener();
                const ctx = listener.context;
                const analyser = ctx.createAnalyser();
                analyser.fftSize = 2048;
                analyser.smoothingTimeConstant = 0;
                const slot = ctx.analyserSlot(analyser);
                expect.that(slot).is(0);

                // Simulate the audio thread publishing a 1 kHz sine frame.
                const frame = new MixAnalyserFrame();
                frame.written = 4096;
                for (let i = 0; i < MIX_MAX_FFT; i++) {
                    frame.samples[i] = <f32>(0.5 * Math.sin(2 * Math.PI * 1000 * <f64>i / RATE));
                }
                ctx.inputs.analysers[slot].publish(frame);

                // Direct calls on AnalyserNode must pull without AudioAnalyser.getFrequencyData().
                const fTime = new Float32Array(2048);
                analyser.getFloatTimeDomainData(fTime);
                near(expect, <f64>fTime[10], <f64>frame.samples[MIX_MAX_FFT - 2048 + 10], 1e-6);

                const bTime = new Uint8Array(2048);
                analyser.getByteTimeDomainData(bTime);
                let minB: i32 = 255, maxB: i32 = 0;
                for (let i = 0; i < bTime.length; i++) {
                    if (<i32>bTime[i] < minB) minB = <i32>bTime[i];
                    if (<i32>bTime[i] > maxB) maxB = <i32>bTime[i];
                }
                expect.that(minB).lessThan(70);
                expect.that(maxB).greaterThan(185);

                const fFreq = new Float32Array(1024);
                analyser.getFloatFrequencyData(fFreq);
                let peak = 0;
                for (let i = 1; i < fFreq.length; i++) if (fFreq[i] > fFreq[peak]) peak = i;
                expect.that(peak == 42 || peak == 43).is(true);

                // A second published frame updates subsequent reads.
                frame.written = 8192;
                for (let i = 0; i < MIX_MAX_FFT; i++) frame.samples[i] = 0.25;
                ctx.inputs.analysers[slot].publish(frame);
                analyser.getFloatTimeDomainData(fTime);
                near(expect, <f64>fTime[0], 0.25, 1e-6);
            });
            test("collectBuffers keeps slots fading out on audio thread and bufferSlot retries after collect", (expect) => {
                const listener = new AudioListener();
                const ctx = listener.context;
                const bufs = new Array<AudioBuffer>();
                for (let i = 0; i < MIX_MAX_BUFFERS; i++) {
                    const b = AudioBuffer.fromChannelData([new Float32Array(32)], RATE);
                    bufs.push(b);
                    expect.that(ctx.bufferSlot(b)).is(i);
                }
                // Simulate voice 0 fading out slot 0 on the audio thread even though no main-lane Audio references it.
                ctx.status.data[S_STATE] = <f64>VOICE_PLAYING;
                ctx.status.data[S_SOURCE] = 0;
                // Keep slots 1..63 referenced by main-lane status/voices? Only voice slots 0..31 exist, so test:
                // mark voice 0 playing slot 0; leave slots 1..63 free to collect.
                // After collecting, slot 0 MUST remain untouched (bufs[0]), and buf65 MUST get slot 1 immediately!
                const extra = AudioBuffer.fromChannelData([new Float32Array(32)], RATE);
                const got = ctx.bufferSlot(extra);
                expect.that(got).is(1);
                expect.that(ctx.buffers[0] === bufs[0]).is(true);
                expect.that(ctx.buffers[1] === extra).is(true);

                // Once voice 0 finishes fading out (VOICE_IDLE), slot 0 can be reclaimed too.
                ctx.status.data[S_STATE] = <f64>VOICE_IDLE;
                ctx.status.data[S_SOURCE] = -1;
                // Refill slots 2..63 so only slot 0 is collectable when extra2 arrives (hold slots 1..63 via voices? No, just refill slots 2..63 + check slot 0):
                for (let i = 2; i < MIX_MAX_BUFFERS; i++) {
                    const b = AudioBuffer.fromChannelData([new Float32Array(32)], RATE);
                    expect.that(ctx.bufferSlot(b)).is(i);
                }
                const extra2 = AudioBuffer.fromChannelData([new Float32Array(32)], RATE);
                expect.that(ctx.bufferSlot(extra2)).is(0);
                expect.that(ctx.buffers[0] === extra2).is(true);
            });
            test("pause ignores stale S_GEN, setBuffer restores playback control, and close releases slots", (expect) => {
                const listener = new AudioListener();
                const ctx = listener.context;
                const audio = new Audio(listener);
                const osc = ctx.createOscillator();
                audio.setNodeSource(osc);
                expect.that(audio.hasPlaybackControl).is(false);
                expect.that(audio.source === osc).is(true);

                // Switching from oscillator back to buffer restores playback control and detaches oscillator.
                audio.setBuffer(AudioBuffer.fromChannelData([new Float32Array(64)], RATE));
                expect.that(audio.hasPlaybackControl).is(true);
                expect.that(audio.source == null).is(true);
                expect.that(osc._audio == null).is(true);

                // Stale audio-thread status from a prior generation must not corrupt pause() progress.
                audio.play();
                const v = audio.voice;
                expect.that(v).greaterThanOrEqual(0);
                ctx.status.data[v * S_STRIDE + S_POSITION] = 12.5;
                ctx.status.data[v * S_STRIDE + S_GEN] = audio.playGen - 1;   // stale gen
                audio.pause();
                near(expect, audio._progress, 0);

                // Matching S_GEN updates _progress accurately.
                audio.play();
                ctx.status.data[v * S_STRIDE + S_POSITION] = 3.25;
                ctx.status.data[v * S_STRIDE + S_GEN] = audio.playGen;
                audio.pause();
                near(expect, audio._progress, 3.25);

                // close() releases voice and analyser slots cleanly.
                const analyser = new AudioAnalyser(audio, 256);
                expect.that(analyser.analyser.slot).is(0);
                ctx.close();
                expect.that(ctx.state).is("closed");
                expect.that(audio.voice).is(-1);
                expect.that(analyser.analyser.slot).is(-1);
                expect.that(analyser.analyser._context == null).is(true);
            });
        });
    }
}
