// Stand-ins for the Web Audio nodes three.js's audio classes hold (Rive has
// no audio graph): `audio.gain`, `positionalAudio.panner`,
// `audioAnalyser.analyser`, filters from `context.createBiquadFilter()`,
// oscillators for `setNodeSource`, and AudioBuffer. They keep Web Audio's
// names, fields and defaults; AudioContext.update() reads them every frame
// and hands the mixer on the audio thread what they say.
//
// AudioParam automation (`setTargetAtTime`, `linearRampToValueAtTime` ...)
// sets the value at once: the mixer smooths every change over about 10 ms.

import { Blob } from "rive/shared";
import { AudioSource } from "rive/audio";
import { Promise } from "rive/promise";
import { blackman, fft, biquadCoefficients } from "./AudioMath";
import { MixAnalyserFrame, MIX_MAX_FFT, SOURCE_SINE, SOURCE_SQUARE, SOURCE_SAWTOOTH, SOURCE_TRIANGLE } from "./AudioMixer";
import { Audio } from "./Audio";
import { AudioContext } from "./AudioContext";

/// A Web Audio AudioParam: a value. Automation sets it now (the mixer ramps
/// it over about 10 ms); the times are ignored.
export class AudioParam {
    value: f64;
    readonly defaultValue: f64;
    minValue: f64 = -3.4028234663852886e38;
    maxValue: f64 = 3.4028234663852886e38;

    constructor(value: f64) {
        this.value = value;
        this.defaultValue = value;
    }

    setValueAtTime(value: f64, startTime: f64): AudioParam { this.value = value; return this; }
    linearRampToValueAtTime(value: f64, endTime: f64): AudioParam { this.value = value; return this; }
    exponentialRampToValueAtTime(value: f64, endTime: f64): AudioParam { this.value = value; return this; }
    setTargetAtTime(target: f64, startTime: f64, timeConstant: f64): AudioParam { this.value = target; return this; }
    cancelScheduledValues(cancelTime: f64): AudioParam { return this; }
}

/// The base of the node stand-ins. `connect` / `disconnect` are no-ops
/// kept so ported code compiles: the routing is fixed (source, filters,
/// panner, gain, the listener's gain and filter).
export class AudioNode {
    numberOfInputs: i32 = 1;
    numberOfOutputs: i32 = 1;
    channelCount: i32 = 2;

    connect(destination: AudioNode): AudioNode { return destination; }
    disconnect(): void {}
}

/// GainNode: `gain.value` scales what passes (an Audio's volume, the
/// listener's master volume).
export class GainNode extends AudioNode {
    gain: AudioParam = new AudioParam(1);
}

/// PannerNode's settings, as Web Audio's (PositionalAudio's `panner`).
/// `panningModel` "HRTF" (three.js's choice) is equal-power panning plus an
/// interaural delay and a head-shadow low-pass here; "equalpower" is Web
/// Audio's equal-power panning alone.
export class PannerNode extends AudioNode {
    panningModel: string = "equalpower";
    distanceModel: string = "inverse";
    refDistance: f64 = 1;
    maxDistance: f64 = 10000;
    rolloffFactor: f64 = 1;
    coneInnerAngle: f64 = 360;
    coneOuterAngle: f64 = 360;
    coneOuterGain: f64 = 0;
    positionX: f64 = 0;
    positionY: f64 = 0;
    positionZ: f64 = 0;
    orientationX: f64 = 1;
    orientationY: f64 = 0;
    orientationZ: f64 = 0;

    setPosition(x: f64, y: f64, z: f64): void {
        this.positionX = x; this.positionY = y; this.positionZ = z;
    }

    setOrientation(x: f64, y: f64, z: f64): void {
        this.orientationX = x; this.orientationY = y; this.orientationZ = z;
    }
}

/// BiquadFilterNode: "lowpass" (default), "highpass", "bandpass",
/// "lowshelf", "highshelf", "peaking", "notch" or "allpass", with Web
/// Audio's coefficients. Use it with `audio.setFilter(s)` or
/// `listener.setFilter`.
export class BiquadFilterNode extends AudioNode {
    type: string = "lowpass";
    frequency: AudioParam = new AudioParam(350);
    Q: AudioParam = new AudioParam(1);
    gain: AudioParam = new AudioParam(0);
    detune: AudioParam = new AudioParam(0);

    /// Its normalized coefficients (b0, b1, b2, a1, a2) at `sampleRate`
    /// into `out` at `offset`.
    coefficients(sampleRate: f64, out: StaticArray<f64>, offset: i32): void {
        biquadCoefficients(this.type, this.frequency.value, this.Q.value, this.gain.value, this.detune.value,
            sampleRate, out, offset);
    }
}

/// OscillatorNode, for `audio.setNodeSource(oscillator)` (three.js's
/// webaudio_sandbox): "sine" (default), "square", "sawtooth" or
/// "triangle" (naive waveforms), heard from `start()` to `stop()`.
export class OscillatorNode extends AudioNode {
    type: string = "sine";
    frequency: AudioParam = new AudioParam(440);
    detune: AudioParam = new AudioParam(0);
    started: bool = false;
    stopped: bool = false;
    startDelay: f64 = 0;
    stopDelay: f64 = 0;
    /// Bumped by start() and stop(); read by the voice.
    generation: i32 = 0;
    /// The Audio playing it (setNodeSource): start() gives it a voice again
    /// after a stop released it.
    _audio: Audio? = null;

    constructor() {
        super();
        this.numberOfInputs = 0;
    }

    start(when: f64 = 0): void {
        this.started = true;
        this.stopped = false;
        this.startDelay = when;
        this.generation++;
        const audio = this._audio;
        if (audio != null && audio.source === this && audio._connected) audio.context.acquireVoice(audio);
    }

    stop(when: f64 = 0): void {
        this.stopped = true;
        this.stopDelay = when;
        this.generation++;
    }

    /// The mixer's source code for the waveform.
    waveform(): i32 {
        if (this.type == "square") return SOURCE_SQUARE;
        if (this.type == "sawtooth") return SOURCE_SAWTOOTH;
        if (this.type == "triangle") return SOURCE_TRIANGLE;
        return SOURCE_SINE;
    }
}

/// AnalyserNode: the frequency and time-domain data of what an Audio plays
/// (made by AudioAnalyser). The samples come from the audio thread each
/// block; the FFT (Blackman window, `smoothingTimeConstant`, dB between
/// `minDecibels` and `maxDecibels`) runs here, as Web Audio defines it.
/// `fftSize` is a power of two from 32 to MIX_MAX_FFT (4096; Web Audio:
/// 32768).
export class AnalyserNode extends AudioNode {
    private _fftSize: i32 = 2048;
    minDecibels: f64 = -100;
    maxDecibels: f64 = -30;
    smoothingTimeConstant: f64 = 0.8;
    /// The mixer's analyser slot, -1 while not listening to anything.
    slot: i32 = -1;
    /// The AudioContext owning this analyser's slot (cleared on release/close).
    _context: AudioContext? = null;
    /// Last snapshot sequence number pulled from the audio thread.
    _lastSeq: f64 = 0;
    /// The latest samples (the mixer's frame) and how many were written.
    frame: MixAnalyserFrame = new MixAnalyserFrame();
    private smoothed: Float64Array = new Float64Array(1024);
    private re: Float64Array = new Float64Array(2048);
    private im: Float64Array = new Float64Array(2048);
    private computedAt: f64 = -1;

    get fftSize(): i32 { return this._fftSize; }
    set fftSize(value: i32) {
        let n = 32;
        while (n < value && n < MIX_MAX_FFT) n <<= 1;
        this._fftSize = n;
        this.smoothed = new Float64Array(n / 2);
        this.re = new Float64Array(n);
        this.im = new Float64Array(n);
        this.computedAt = -1;
    }

    get frequencyBinCount(): i32 { return this._fftSize / 2; }

    /// Takes samples (oldest first, the newest at the end) as if the audio
    /// thread had sent them: what the mixer's analyser frames go through,
    /// and a way to analyse any signal.
    setSamples(samples: Float32Array, written: f64): void {
        const dst = this.frame.samples;
        const n = min<i32>(samples.length, MIX_MAX_FFT);
        for (let i = 0; i < MIX_MAX_FFT - n; i++) dst[i] = 0;
        for (let i = 0; i < n; i++) dst[MIX_MAX_FFT - n + i] = samples[samples.length - n + i];
        this.frame.written = written;
    }

    /// Computes the smoothed magnitudes (once per new block of samples).
    private compute(): void {
        if (this.frame.written == this.computedAt) return;
        this.computedAt = this.frame.written;
        const n = this._fftSize;
        const samples = this.frame.samples;
        const re = this.re, im = this.im;
        for (let i = 0; i < n; i++) {
            re[i] = <f64>samples[MIX_MAX_FFT - n + i] * blackman(i, n);
            im[i] = 0;
        }
        fft(re, im);
        const tau = Math.min(Math.max(this.smoothingTimeConstant, 0), 1);
        const smoothed = this.smoothed;
        for (let k = 0; k < n / 2; k++) {
            const magnitude = Math.sqrt(re[k] * re[k] + im[k] * im[k]) / <f64>n;
            let value = tau * smoothed[k] + (1 - tau) * magnitude;
            if (!isFinite(value)) value = 0;
            smoothed[k] = value;
        }
    }

    /// Pulls fresh samples from the audio thread when bound to an AudioContext slot.
    private pull(): void {
        const ctx = this._context;
        if (ctx != null && this.slot >= 0) ctx.readAnalyser(this);
    }

    /// Decibels per bin into `array` (-Infinity for silence).
    getFloatFrequencyData(array: Float32Array): void {
        this.pull();
        this.compute();
        const count = min<i32>(array.length, this._fftSize / 2);
        for (let k = 0; k < count; k++) {
            const v = this.smoothed[k];
            array[k] = v > 0 ? <f32>(20 * Math.log10(v)) : <f32>-Infinity;
        }
    }

    /// Bytes per bin: 0 at minDecibels, 255 at maxDecibels.
    getByteFrequencyData(array: Uint8Array): void {
        this.pull();
        this.compute();
        const count = min<i32>(array.length, this._fftSize / 2);
        const range = this.maxDecibels - this.minDecibels;
        if (!(range > 0)) {
            for (let k = 0; k < count; k++) array[k] = 0;
            return;
        }
        for (let k = 0; k < count; k++) {
            const v = this.smoothed[k];
            const db = v > 0 ? 20 * Math.log10(v) : -Infinity;
            let b = Math.floor(255 / range * (db - this.minDecibels));
            if (!(b > 0)) b = 0;
            if (b > 255) b = 255;
            array[k] = <u8>b;
        }
    }

    /// The latest fftSize samples.
    getFloatTimeDomainData(array: Float32Array): void {
        this.pull();
        const n = this._fftSize;
        const count = min<i32>(array.length, n);
        for (let i = 0; i < count; i++) array[i] = this.frame.samples[MIX_MAX_FFT - n + i];
    }

    /// The latest fftSize samples as bytes (128 is silence).
    getByteTimeDomainData(array: Uint8Array): void {
        this.pull();
        const n = this._fftSize;
        const count = min<i32>(array.length, n);
        for (let i = 0; i < count; i++) {
            let b = Math.floor(128 * (1 + <f64>this.frame.samples[MIX_MAX_FFT - n + i]));
            if (!(b > 0)) b = 0;
            if (b > 255) b = 255;
            array[i] = <u8>b;
        }
    }
}

/// Web Audio's AudioBuffer: decoded audio, as interleaved f32 frames in a
/// shared Blob (what the mixer reads on the audio thread), or channel data
/// made with `context.createBuffer` and written before it first plays.
/// Loaders return a buffer at once and fill it when decoding ends: `ready`
/// turns true and `promise` resolves.
export class AudioBuffer {
    sampleRate: f64;
    length: i32;
    numberOfChannels: i32;
    /// The interleaved frames (null until decoded).
    blob: Blob? = null;
    /// The Rive audio asset it was decoded from, if any.
    source: AudioSource? = null;
    /// The asset or url it came from.
    name: string = "";
    ready: bool = false;
    /// Why decoding failed ("" when it did not).
    error: string = "";
    promise: Promise<AudioBuffer> = new Promise<AudioBuffer>();
    private channelData: Array<Float32Array>? = null;

    constructor(numberOfChannels: i32 = 1, length: i32 = 0, sampleRate: f64 = 44100) {
        this.numberOfChannels = numberOfChannels;
        this.length = length;
        this.sampleRate = sampleRate;
    }

    get duration(): f64 { return this.sampleRate > 0 ? <f64>this.length / this.sampleRate : 0; }

    /// A buffer of channel data (each channel a Float32Array of the same
    /// length), ready to play.
    static fromChannelData(channels: Array<Float32Array>, sampleRate: f64): AudioBuffer {
        const length = channels.length > 0 ? channels[0].length : 0;
        const buffer = new AudioBuffer(channels.length, length, sampleRate);
        buffer.channelData = channels;
        buffer.ready = true;
        buffer.promise.resolve(buffer);
        return buffer;
    }

    /// A buffer of decoded interleaved frames.
    static fromBlob(blob: Blob, numberOfChannels: i32, sampleRate: f64): AudioBuffer {
        const frames = numberOfChannels > 0 ? <i32>(blob.byteLength / 4) / numberOfChannels : 0;
        const buffer = new AudioBuffer(numberOfChannels, frames, sampleRate);
        buffer.setBlob(blob, numberOfChannels, sampleRate);
        return buffer;
    }

    /// Fills a pending buffer with decoded frames.
    setBlob(blob: Blob, numberOfChannels: i32, sampleRate: f64): void {
        this.blob = blob;
        this.numberOfChannels = numberOfChannels;
        this.sampleRate = sampleRate;
        this.length = numberOfChannels > 0 ? <i32>(blob.byteLength / 4) / numberOfChannels : 0;
        this.channelData = null;
        this.ready = true;
        this.promise.resolve(this);
    }

    fail(message: string): void {
        this.error = message;
        this.promise.reject(message);
    }

    /// A channel's samples. For a decoded buffer it is a copy (writes do
    /// not reach the mixer); for a created one it is the data itself,
    /// which the mixer takes when the buffer first plays.
    getChannelData(channel: i32): Float32Array {
        const data = this.channelData;
        if (data != null) return data[channel];
        const out = new Float32Array(this.length);
        const blob = this.blob;
        if (blob == null || channel >= this.numberOfChannels) return out;
        const all = new Float32Array(this.length * this.numberOfChannels);
        blob.readInto(0, all);
        for (let i = 0; i < this.length; i++) out[i] = all[i * this.numberOfChannels + channel];
        return out;
    }

    copyFromChannel(destination: Float32Array, channelNumber: i32, bufferOffset: i32 = 0): void {
        const data = this.getChannelData(channelNumber);
        for (let i = 0; i < destination.length && bufferOffset + i < data.length; i++) destination[i] = data[bufferOffset + i];
    }

    copyToChannel(source: Float32Array, channelNumber: i32, bufferOffset: i32 = 0): void {
        if (this.channelData == null) {
            const channels = new Array<Float32Array>();
            for (let c = 0; c < this.numberOfChannels; c++) channels.push(this.getChannelData(c));
            this.channelData = channels;
            this.blob = null;
        }
        const data = this.channelData!;
        const dst = data[channelNumber];
        for (let i = 0; i < source.length && bufferOffset + i < dst.length; i++) dst[bufferOffset + i] = source[i];
    }

    /// The blob the mixer reads, made from created channel data on first use.
    interleaved(): Blob? {
        const blob = this.blob;
        if (blob != null) return blob;
        const data = this.channelData;
        if (data == null || this.length == 0) return null;
        const channels = min<i32>(this.numberOfChannels, 2);
        const all = new Float32Array(this.length * channels);
        for (let c = 0; c < channels; c++) {
            const src = data[c];
            for (let i = 0; i < this.length; i++) all[i * channels + c] = src[i];
        }
        const made = Blob.fromArray(all);
        this.blob = made;
        this.numberOfChannels = channels;
        this.ready = true;
        return made;
    }
}
