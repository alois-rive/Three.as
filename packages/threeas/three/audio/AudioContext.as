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
    S_STRIDE, S_ENDED, S_STATE, S_GEN, S_SOURCE, VOICE_IDLE, VOICE_HELD, SOURCE_NONE,
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
        for (let i = 0; i < MIX_MAX_VOICES; i++) {
            this.params.data[i * P_STRIDE + P_SOURCE] = <f64>SOURCE_NONE;
            this.status.data[i * S_STRIDE + S_GEN] = -1;
            this.status.data[i * S_STRIDE + S_SOURCE] = <f64>SOURCE_NONE;
        }
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
    createAnalyser(): AnalyserNode {
        const node = new AnalyserNode();
        node._context = this;
        return node;
    }
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
        if (this.closed) return;
        this.suspendedByUser = false;
        this.ensureStarted();
        if (this.fallback) this.state = "running";
    }

    /// Fades every voice out until resume().
    suspend(): void {
        if (this.closed) return;
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
        for (let v = 0; v < MIX_MAX_VOICES; v++) {
            const audio = this.voices[v];
            if (audio != null) {
                audio.releaseFallbackSound();
                this.releaseVoice(audio);
            }
        }
        for (let i = 0; i < MIX_MAX_ANALYSERS; i++) {
            const node = this.analysers[i];
            if (node != null) this.releaseAnalyser(node);
        }
    }

    // ------------------------------------------------------ the plumbing

    private ensureStarted(): void {
        if (this.started || this.closed) return;
        this.started = true;
        const rate = RiveAudio.processorSampleRate();
        if (rate <= 0) {
            // No processors here (tests, a web build without threads).
            this.fallback = true;
            if (!this.suspendedByUser) this.state = "running";
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
        if (!buffer.ready) return -1;
        if (free < 0) {
            this.collectBuffers();
            for (let i = 0; i < MIX_MAX_BUFFERS; i++) {
                if (this.buffers[i] == null) { free = i; break; }
            }
            if (free < 0) return -1;
        }
        if (!this.announce(free, buffer)) return -1;
        this.buffers[free] = buffer;
        return free;
    }

    /// Frees buffer slots no voice uses (neither on the main lane nor still
    /// active/fading out on the audio thread).
    private collectBuffers(): void {
        const sdata = this.status.data;
        const pdata = this.params.data;
        const hasProcessor = this.handle != null;
        for (let i = 0; i < MIX_MAX_BUFFERS; i++) {
            const b = this.buffers[i];
            if (b == null) continue;
            let used = false;
            for (let v = 0; v < MIX_MAX_VOICES; v++) {
                const a = this.voices[v];
                if (a != null && a.buffer === b) { used = true; break; }
                const state = <i32>sdata[v * S_STRIDE + S_STATE];
                if (state != VOICE_IDLE && <i32>sdata[v * S_STRIDE + S_SOURCE] == i) { used = true; break; }
                if (hasProcessor && <i32>pdata[v * P_STRIDE + P_SOURCE] == i) { used = true; break; }
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

    /// An analyser slot for `node`, or -1. When all are taken, slots whose
    /// analyser no voice listens to are freed first (their analysers take
    /// a slot again when their Audio plays).
    analyserSlot(node: AnalyserNode): i32 {
        if (node.slot >= 0 && node.slot < MIX_MAX_ANALYSERS && this.analysers[node.slot] === node) {
            node._context = this;
            return node.slot;
        }
        node.slot = -1;
        for (let pass = 0; pass < 2; pass++) {
            for (let i = 0; i < MIX_MAX_ANALYSERS; i++) {
                if (this.analysers[i] == null) {
                    this.analysers[i] = node;
                    node.slot = i;
                    node._context = this;
                    node._lastSeq = 0;
                    return i;
                }
            }
            if (pass == 0) this.collectAnalysers();
        }
        return -1;
    }

    /// Gives `node`'s analyser slot back.
    releaseAnalyser(node: AnalyserNode): void {
        const slot = node.slot;
        if (slot >= 0 && slot < MIX_MAX_ANALYSERS && this.analysers[slot] === node) this.analysers[slot] = null;
        node.slot = -1;
        node._context = null;
        node._lastSeq = 0;
    }

    /// Frees analyser slots no voice's Audio listens through.
    private collectAnalysers(): void {
        for (let i = 0; i < MIX_MAX_ANALYSERS; i++) {
            const node = this.analysers[i];
            if (node == null) continue;
            let used = false;
            for (let v = 0; v < MIX_MAX_VOICES; v++) {
                const a = this.voices[v];
                if (a != null && a.analyser === node) used = true;
            }
            if (!used) this.releaseAnalyser(node!);
        }
    }

    /// Updates the world matrices of the Audio objects holding a voice (the
    /// listener's update, before it computes the mix).
    updateVoiceMatrices(): void {
        for (let v = 0; v < MIX_MAX_VOICES; v++) {
            const audio = this.voices[v];
            if (audio != null) audio.updateWorldMatrix(true, false);
        }
    }

    /// The latest samples of analyser `node` into its frame.
    readAnalyser(node: AnalyserNode): void {
        const slot = node.slot;
        if (slot < 0 || slot >= MIX_MAX_ANALYSERS) return;
        const snap = this.inputs.analysers[slot];
        const seq = snap.seq;
        if (seq == 0 || seq == node._lastSeq) return;
        node._lastSeq = seq;
        snap.latestInto(node.frame);
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
        } else if (this.fallback) {
            this.state = this.suspendedByUser ? "suspended" : "running";
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
            // A stopped voice that went quiet gives its slot back: a buffer
            // stopped (or ended, or disposed), an oscillator stopped or
            // disconnected. A paused one keeps it (the mixer holds its
            // position) until it plays, stops or is disposed.
            if (audio.isSilenced()) {
                if (running) {
                    const state = <i32>this.status.data[v * S_STRIDE + S_STATE];
                    const sgen = this.status.data[v * S_STRIDE + S_GEN];
                    const noSource = <i32>data[base + P_SOURCE] == SOURCE_NONE;
                    const genDone = this.status.blocks == 0 || audio.playGen <= 0 || sgen == audio.playGen || noSource;
                    if (genDone && (state == VOICE_IDLE || state == VOICE_HELD)) {
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
    // The job's handle is released once its outcome is in (the decoded
    // value stays valid).
    const job = Jobs.run(decodeWAV, bytes, info);
    const settled = await job.promise().settled();
    job.release();
    if (!settled.ok) {
        buffer.fail(settled.error);
        return await Promise.reject<AudioBuffer>(settled.error);
    }
    const blob: Blob = settled.value;
    buffer.setBlob(blob, min<i32>(info.channels, 2), info.sampleRate);
    return buffer;
}

/// Fills `buffer` from WAV bytes (AudioLoader's url and blob path).
export function decodeWAVInto(bytes: ArrayBuffer, buffer: AudioBuffer): Promise<AudioBuffer> {
    return decodeAudioDataAsync(bytes, buffer);
}
