// three.js's `listener.context` (a Web Audio AudioContext), over Rive:
// each AudioListener owns one AudioContext, which runs one
// AudioMixProcessor (rive/audio's Audio.start) mixing every Audio of that
// listener on the audio thread. `update()` (called through the listener
// every frame) assigns voices, announces decoded buffers, publishes each
// voice's parameters through a Snapshot and reads back the processor's
// clock, positions and ended plays.
//
// The processor stops when the context is collected (its handle goes with
// it) and fades the mix out while nothing updates it (MIX_STALE_SECONDS),
// so a script that went away, paused or stopped drawing goes quiet.
//
// Where processors cannot run (a web build without threads: no cross
// origin isolation), Audio objects whose buffer came from a Rive audio
// asset play through Rive's own `Audio.play` instead, with their volume,
// distance and cone gains but no panning, rate, filters or analysers (see
// docs/DEVIATIONS.md, Audio).

import { Audio as RiveAudio, AudioHandle } from "rive/audio";
import { Blob } from "rive/shared";
import { Promise } from "rive/promise";
import { Jobs } from "rive/jobs";
import {
    MixInputs, MixParams, MixStatus, MixBuffer, AudioMixProcessor,
    MIX_MAX_VOICES, MIX_MAX_BUFFERS, MIX_MAX_ANALYSERS, P_STRIDE, P_SOURCE, P_PLAYING,
    S_STRIDE, S_ENDED, S_STATE, VOICE_IDLE, VOICE_HELD, SOURCE_NONE,
} from "./AudioMixer";
import { AudioBuffer, GainNode, BiquadFilterNode, AnalyserNode, OscillatorNode, PannerNode } from "./AudioNodes";
import { Audio } from "./Audio";
import { decodeWAV, parseWAVHeader } from "./WAV";

export class AudioContext {
    /// "suspended" until the processor renders (on the web, until the
    /// page's first click, tap or key press), then "running"; "closed" after
    /// close() or when the processor failed for good.
    state: string = "suspended";
    /// Why the processor failed, if it did.
    error: string = "";
    /// Whether audio plays through Rive's Audio.play because processors
    /// cannot run here.
    fallback: bool = false;
    /// Restart a failed processor up to this many times.
    maxRestarts: i32 = 3;

    readonly inputs: MixInputs = new MixInputs();
    readonly params: MixParams = new MixParams();
    readonly status: MixStatus = new MixStatus();
    private handle: AudioHandle? = null;
    private started: bool = false;
    private restarts: i32 = 0;
    private closed: bool = false;
    private _sampleRate: f64 = 0;
    private _generation: f64 = 0;
    private lastFrames: f64 = -1;
    private idleUpdates: i32 = 0;
    private suspendedByUser: bool = false;

    /// Voice slots: the Audio playing in each.
    voices: Array<Audio?> = new Array<Audio?>(MIX_MAX_VOICES);
    /// Buffer slots announced to the processor.
    buffers: Array<AudioBuffer?> = new Array<AudioBuffer?>(MIX_MAX_BUFFERS);
    /// Analyser slots.
    analysers: Array<AnalyserNode?> = new Array<AnalyserNode?>(MIX_MAX_ANALYSERS);
    private warnedVoices: bool = false;

    constructor() {
        for (let i = 0; i < MIX_MAX_VOICES; i++) this.params.data[i * P_STRIDE + P_SOURCE] = <f64>SOURCE_NONE;
    }

    /// The rate the mixer renders at (the processor's, else the engine's).
    get sampleRate(): f64 {
        if (this._sampleRate > 0) return this._sampleRate;
        const rate = RiveAudio.processorSampleRate();
        if (rate > 0) return rate;
        const engine = RiveAudio.sampleRate();
        return engine > 0 ? engine : 48000;
    }

    /// Seconds of audio the mixer has rendered (Web Audio's currentTime).
    get currentTime(): f64 {
        const rate = this.status.sampleRate;
        return rate > 0 ? this.status.frames / rate : 0;
    }

    /// A new play generation (unique across the context's voices).
    nextGeneration(): f64 {
        this._generation += 1;
        return this._generation;
    }

    // ----------------------------------------------------- Web Audio API

    createGain(): GainNode { return new GainNode(); }
    createBiquadFilter(): BiquadFilterNode { return new BiquadFilterNode(); }
    createAnalyser(): AnalyserNode { return new AnalyserNode(); }
    createOscillator(): OscillatorNode { return new OscillatorNode(); }
    createPanner(): PannerNode { return new PannerNode(); }
    createBuffer(numberOfChannels: i32, length: i32, sampleRate: f64): AudioBuffer {
        const channels = new Array<Float32Array>();
        for (let c = 0; c < numberOfChannels; c++) channels.push(new Float32Array(length));
        return AudioBuffer.fromChannelData(channels, sampleRate);
    }

    /// Decodes WAV bytes (PCM 8/16/24/32-bit or float) in a job. Rive
    /// decodes MP3 and FLAC only from its audio assets: load those by name.
    decodeAudioData(bytes: ArrayBuffer): Promise<AudioBuffer> {
        return decodeAudioDataAsync(bytes, new AudioBuffer());
    }

    /// Starts the processor (it starts with the first update anyway). In a
    /// browser, audio itself starts at the page's first click, tap or key
    /// press.
    resume(): void {
        this.suspendedByUser = false;
        this.ensureStarted();
    }

    /// Fades every voice out until resume().
    suspend(): void {
        this.suspendedByUser = true;
        this.state = "suspended";
    }

    /// Stops the processor for good.
    close(): void {
        this.closed = true;
        this.state = "closed";
        const h = this.handle;
        if (h != null) {
            h.stop();
            h.release();
        }
        this.handle = null;
    }

    // ------------------------------------------------------ the plumbing

    private ensureStarted(): void {
        if (this.started || this.closed) return;
        this.started = true;
        const rate = RiveAudio.processorSampleRate();
        if (rate <= 0) {
            // No processors here (tests, a web build without threads).
            this.fallback = true;
            return;
        }
        this._sampleRate = rate;
        this.handle = RiveAudio.start(() => new AudioMixProcessor(), this.inputs);
    }

    private checkProcessor(): void {
        const h = this.handle;
        if (h == null) return;
        const failed = h.failed;
        if (failed == null) return;
        this.error = failed!;
        h.release();
        this.handle = null;
        if (this.restarts < this.maxRestarts) {
            this.restarts++;
            console.warn("three: audio mixer failed, restarting: " + this.error);
            // Buffers are announced again to the new processor.
            for (let i = 0; i < MIX_MAX_BUFFERS; i++) {
                const b = this.buffers[i];
                if (b != null) this.announce(i, b);
            }
            this.handle = RiveAudio.start(() => new AudioMixProcessor(), this.inputs);
        } else {
            console.warn("three: audio mixer failed: " + this.error);
            this.state = "closed";
            this.fallback = true;
        }
    }

    /// A voice slot for `audio` (its current one, or a free one), or -1.
    acquireVoice(audio: Audio): i32 {
        if (audio.voice >= 0 && audio.voice < MIX_MAX_VOICES && this.voices[audio.voice] === audio) return audio.voice;
        for (let i = 0; i < MIX_MAX_VOICES; i++) {
            if (this.voices[i] == null) {
                this.voices[i] = audio;
                audio.voice = i;
                return i;
            }
        }
        if (!this.warnedVoices) {
            this.warnedVoices = true;
            console.warn("three: more than " + MIX_MAX_VOICES.toString() + " Audio playing at once; the rest are silent");
        }
        return -1;
    }

    releaseVoice(audio: Audio): void {
        const v = audio.voice;
        if (v >= 0 && v < MIX_MAX_VOICES && this.voices[v] === audio) {
            this.voices[v] = null;
            const base = v * P_STRIDE;
            this.params.data[base + P_SOURCE] = <f64>SOURCE_NONE;
            this.params.data[base + P_PLAYING] = 0;
        }
        audio.voice = -1;
    }

    /// The buffer slot of `buffer`, announcing it to the processor when it
    /// is new; -1 while it is not decoded (or there is no room).
    bufferSlot(buffer: AudioBuffer): i32 {
        let free = -1;
        for (let i = 0; i < MIX_MAX_BUFFERS; i++) {
            const b = this.buffers[i];
            if (b === buffer) return i;
            if (b == null && free < 0) free = i;
        }
        if (!buffer.ready || free < 0) {
            if (free < 0) this.collectBuffers();
            return -1;
        }
        if (!this.announce(free, buffer)) return -1;
        this.buffers[free] = buffer;
        return free;
    }

    /// Frees buffer slots no voice uses (the processor keeps reading a slot
    /// until a new buffer replaces it, so only idle ones go).
    private collectBuffers(): void {
        for (let i = 0; i < MIX_MAX_BUFFERS; i++) {
            const b = this.buffers[i];
            if (b == null) continue;
            let used = false;
            for (let v = 0; v < MIX_MAX_VOICES; v++) {
                const a = this.voices[v];
                if (a != null && a.buffer === b) used = true;
            }
            if (!used) this.buffers[i] = null;
        }
    }

    private announce(slot: i32, buffer: AudioBuffer): bool {
        const blob = buffer.interleaved();
        if (blob == null) return false;
        const m = new MixBuffer();
        m.slot = slot;
        m.blobId = blob.id;
        m.channels = buffer.numberOfChannels;
        m.sampleRate = buffer.sampleRate;
        m.frames = <f64>buffer.length;
        return this.inputs.buffers.send(m);
    }

    /// An analyser slot for `node`, or -1.
    analyserSlot(node: AnalyserNode): i32 {
        if (node.slot >= 0 && node.slot < MIX_MAX_ANALYSERS && this.analysers[node.slot] === node) return node.slot;
        for (let i = 0; i < MIX_MAX_ANALYSERS; i++) {
            if (this.analysers[i] == null) {
                this.analysers[i] = node;
                node.slot = i;
                return i;
            }
        }
        return -1;
    }

    /// The latest samples of analyser `node` into its frame.
    readAnalyser(node: AnalyserNode): void {
        const slot = node.slot;
        if (slot < 0 || slot >= MIX_MAX_ANALYSERS || this.handle == null) return;
        this.inputs.analysers[slot].latestInto(node.frame);
    }

    /// The status of voice `v` (S_POSITION ...).
    voiceStatus(v: i32, field: i32): f64 {
        return this.status.data[v * S_STRIDE + field];
    }

    /// Publishes every voice for this frame and reads the processor's
    /// status back (AudioListener.update calls it).
    update(): void {
        if (this.closed) return;
        this.ensureStarted();
        this.checkProcessor();
        const running = this.handle != null;
        if (running) this.inputs.status.latestInto(this.status);

        // Suspended (the page has had no gesture yet) while the clock stands.
        if (running) {
            if (this.status.frames != this.lastFrames) {
                this.lastFrames = this.status.frames;
                this.idleUpdates = 0;
                if (!this.suspendedByUser) this.state = "running";
            } else if (++this.idleUpdates > 60) {
                this.state = "suspended";
            }
        }

        const data = this.params.data;
        for (let v = 0; v < MIX_MAX_VOICES; v++) {
            const audio = this.voices[v];
            const base = v * P_STRIDE;
            if (audio == null) {
                data[base + P_SOURCE] = <f64>SOURCE_NONE;
                data[base + P_PLAYING] = 0;
                continue;
            }
            // Ended plays.
            if (running) {
                const ended = this.status.data[v * S_STRIDE + S_ENDED];
                if (audio.isPlaying && audio.playGen > 0 && ended == audio.playGen) audio.endedByMixer();
            }
            audio.writeVoice(this, data, base);
            if (this.suspendedByUser) data[base + P_PLAYING] = 0;
            if (this.fallback) audio.updateFallback(this, data, base);
            // A stopped voice that went quiet gives its slot back.
            if (!audio.isPlaying && !audio.paused && !audio.isNodeSource()) {
                if (running) {
                    // (Whatever generation it holds: a stopped play that never
                    // started, waiting for its buffer, goes too.)
                    const state = <i32>this.status.data[v * S_STRIDE + S_STATE];
                    if (state == VOICE_IDLE || state == VOICE_HELD) {
                        this.releaseVoice(audio);
                    }
                } else if (this.fallback && !audio.hasFallbackSound()) {
                    this.releaseVoice(audio);
                }
            }
        }
        this.params.tick += 1;
        this.inputs.params.publish(this.params);
    }
}

async function decodeAudioDataAsync(bytes: ArrayBuffer, buffer: AudioBuffer): Promise<AudioBuffer> {
    const info = parseWAVHeader(bytes);
    if (info.error.length > 0) {
        buffer.fail(info.error);
        return await Promise.reject<AudioBuffer>(info.error);
    }
    const result = await Jobs.run(decodeWAV, bytes, info).promise();
    const blob: Blob = result;
    buffer.setBlob(blob, min<i32>(info.channels, 2), info.sampleRate);
    return buffer;
}

/// Fills `buffer` from WAV bytes (AudioLoader's url and blob path).
export function decodeWAVInto(bytes: ArrayBuffer, buffer: AudioBuffer): Promise<AudioBuffer> {
    return decodeAudioDataAsync(bytes, buffer);
}
