// three.js Audio: a non-positional sound (music, ambience), played by the
// listener's mixer on the audio thread. `setBuffer` takes an AudioBuffer
// (AudioLoader: a Rive audio asset by name, or WAV bytes);
// `setMediaElementSource` takes a Rive AudioSource (an audio asset) and
// decodes it into one; `setNodeSource` takes an OscillatorNode. A play
// that reaches its end calls `onEnded()` and dispatches an "ended" event
// (three.js's `source.onended`).

import { Object3D } from "../core/Object3D";
import { Event } from "../core/EventDispatcher";
import { AudioSource, AudioSound, Audio as RiveAudio } from "rive/audio";
import { Promise } from "rive/promise";
import { AudioListener } from "./AudioListener";
import { AudioContext } from "./AudioContext";
import { AudioNode, GainNode, BiquadFilterNode, OscillatorNode, AnalyserNode, AudioBuffer } from "./AudioNodes";
import { computedPlaybackRate } from "./AudioMath";
import {
    MIX_MAX_FILTERS, P_SOURCE, P_GEN, P_PLAYING, P_OFFSET, P_DELAY, P_DURATION, P_LOOP, P_LOOP_START, P_LOOP_END,
    P_RATE, P_LL, P_LR, P_RL, P_RR, P_GAIN, P_MASTER, P_TAP_PRE, P_ITD_L, P_ITD_R, P_LPF_L, P_LPF_R, P_ANALYSER,
    P_STOP_GEN, P_STOP_DELAY, P_FREQUENCY, P_FILTERS, P_FILTER0, S_POSITION, SOURCE_NONE,
} from "./AudioMixer";

export class Audio extends Object3D {
    listener: AudioListener;
    context: AudioContext;
    gain: GainNode = new GainNode();
    autoplay: bool = false;
    buffer: AudioBuffer? = null;
    detune: f64 = 0;
    loop: bool = false;
    loopStart: f64 = 0;
    loopEnd: f64 = 0;
    offset: f64 = 0;
    /// Seconds of the buffer to play; 0 (three.js's undefined) to the end.
    duration: f64 = 0;
    playbackRate: f64 = 1;
    isPlaying: bool = false;
    hasPlaybackControl: bool = true;
    /// "empty", "buffer" or "audioNode".
    sourceType: string = "empty";
    /// The oscillator given to setNodeSource.
    source: OscillatorNode? = null;
    filters: Array<BiquadFilterNode> = [];

    /// The mixer voice playing it, -1 when none.
    voice: i32 = -1;
    /// The generation of the current (or last) play.
    playGen: f64 = 0;
    /// Paused: the mixer holds the position for the next play().
    paused: bool = false;
    /// The analyser listening to it.
    analyser: AnalyserNode? = null;
    _startedAt: f64 = 0;
    _progress: f64 = 0;
    _connected: bool = false;
    private startDelay: f64 = 0;
    private startOffset: f64 = 0;
    private stopGen: f64 = 0;
    private stopDelay: f64 = 0;
    private nodeGeneration: i32 = -1;
    private pendingBuffer: bool = false;
    // Fallback playback (Rive's Audio.play) where processors cannot run.
    private sound: AudioSound? = null;
    private soundGen: f64 = 0;
    private soundPaused: bool = false;

    constructor(listener: AudioListener) {
        super();
        this.type = "Audio";
        this.listener = listener;
        this.context = listener.context;
    }

    getOutput(): AudioNode {
        return this.gain;
    }

    /// Plays an OscillatorNode (it sounds between its start() and stop();
    /// play/pause/stop do not apply, as three.js).
    setNodeSource(audioNode: OscillatorNode): Audio {
        this.hasPlaybackControl = false;
        this.sourceType = "audioNode";
        this.source = audioNode;
        audioNode._audio = this;
        this.connect();
        return this;
    }

    /// A Rive audio asset in place of a media element: decoded into a
    /// buffer and played as one (with playback control, unlike three.js's
    /// media element sources).
    setMediaElementSource(mediaElement: AudioSource): Audio {
        const buffer = new AudioBuffer(<i32>mediaElement.channels, 0, mediaElement.sampleRate);
        decodeSource(mediaElement, buffer);
        return this.setBuffer(buffer);
    }

    setBuffer(audioBuffer: AudioBuffer): Audio {
        this.buffer = audioBuffer;
        this.sourceType = "buffer";
        if (this.autoplay) this.play();
        return this;
    }

    isNodeSource(): bool { return this.sourceType == "audioNode"; }

    play(delay: f64 = 0): Audio {
        if (this.isPlaying) {
            console.warn("THREE.Audio: Audio is already playing.");
            return this;
        }
        if (!this.hasPlaybackControl) {
            console.warn("THREE.Audio: this Audio has no playback control.");
            return this;
        }
        this._startedAt = this.context.currentTime + delay;
        this.isPlaying = true;
        this.context.acquireVoice(this);
        if (this.paused && this.voice >= 0 && delay == 0) {
            // Resume where the mixer held it.
            this.paused = false;
            return this.connect();
        }
        this.paused = false;
        this.playGen = this.context.nextGeneration();
        this.startOffset = this._progress + this.offset;
        this.startDelay = delay;
        return this.connect();
    }

    pause(): Audio {
        if (!this.hasPlaybackControl) {
            console.warn("THREE.Audio: this Audio has no playback control.");
            return this;
        }
        if (this.isPlaying) {
            // The mixer's position (three.js estimates it from the clock).
            if (this.voice >= 0) {
                this._progress = Math.max(0, this.context.voiceStatus(this.voice, S_POSITION) - this.offset);
            }
            this.isPlaying = false;
            this.paused = true;
            this.stopGen = this.context.nextGeneration();
            this.stopDelay = 0;
        }
        return this;
    }

    stop(delay: f64 = 0): Audio {
        if (!this.hasPlaybackControl) {
            console.warn("THREE.Audio: this Audio has no playback control.");
            return this;
        }
        this._progress = 0;
        this.isPlaying = false;
        this.paused = false;
        this.stopGen = this.context.nextGeneration();
        this.stopDelay = delay;
        return this;
    }

    connect(): Audio {
        this._connected = true;
        // An oscillator sounds while connected: it takes a voice (one
        // stopped or disconnected gave its voice back).
        if (this.isNodeSource()) this.context.acquireVoice(this);
        return this;
    }

    /// An oscillator source goes silent and gives its voice back once it
    /// faded out; a buffer source is muted (keeping its voice).
    disconnect(): Audio {
        this._connected = false;
        return this;
    }

    /// Rive-only (three.js leaves a dropped Audio to the garbage collector,
    /// which ends its Web Audio nodes): stops it, gives its mixer voice back
    /// once it has faded out and its analyser slot at once. Call it before
    /// dropping an Audio that may be paused or play an oscillator: those
    /// keep their voice (at most MIX_MAX_VOICES, 32) otherwise. It can play
    /// again afterwards.
    dispose(): void {
        this._progress = 0;
        this.isPlaying = false;
        this.paused = false;
        if (this.hasPlaybackControl) {
            this.stopGen = this.context.nextGeneration();
            this.stopDelay = 0;
        }
        this._connected = false;
        const analyser = this.analyser;
        if (analyser != null) {
            this.context.releaseAnalyser(analyser);
            this.analyser = null;
        }
    }

    /// Whether this Audio is silent from the main lane's side, so that its
    /// voice goes back once the mixer has faded it out: a buffer stopped,
    /// ended or disposed (not paused), an oscillator not started, stopped
    /// or disconnected.
    isSilenced(): bool {
        if (this.isNodeSource()) {
            const osc = this.source;
            return osc == null || !osc.started || osc.stopped || !this._connected;
        }
        return !this.isPlaying && !this.paused;
    }

    getFilters(): Array<BiquadFilterNode> {
        return this.filters;
    }

    /// At most two filters per Audio are applied (MIX_MAX_FILTERS less the
    /// listener's).
    setFilters(value: Array<BiquadFilterNode>): Audio {
        this.filters = value.slice();
        return this;
    }

    setDetune(value: f64): Audio {
        this.detune = value;
        return this;
    }

    getDetune(): f64 {
        return this.detune;
    }

    getFilter(): BiquadFilterNode? {
        return this.filters.length > 0 ? this.filters[0] : null;
    }

    setFilter(filter: BiquadFilterNode?): Audio {
        this.filters = filter != null ? [filter!] : [];
        return this;
    }

    setPlaybackRate(value: f64): Audio {
        if (!this.hasPlaybackControl) {
            console.warn("THREE.Audio: this Audio has no playback control.");
            return this;
        }
        this.playbackRate = value;
        return this;
    }

    getPlaybackRate(): f64 {
        return this.playbackRate;
    }

    /// Called when a play reaches its end (three.js's source.onended).
    onEnded(): void {
        this.isPlaying = false;
    }

    getLoop(): bool {
        if (!this.hasPlaybackControl) {
            console.warn("THREE.Audio: this Audio has no playback control.");
            return false;
        }
        return this.loop;
    }

    setLoop(value: bool): Audio {
        if (!this.hasPlaybackControl) {
            console.warn("THREE.Audio: this Audio has no playback control.");
            return this;
        }
        this.loop = value;
        return this;
    }

    setLoopStart(value: f64): Audio {
        this.loopStart = value;
        return this;
    }

    setLoopEnd(value: f64): Audio {
        this.loopEnd = value;
        return this;
    }

    getVolume(): f64 {
        return this.gain.gain.value;
    }

    setVolume(value: f64): Audio {
        this.gain.gain.setTargetAtTime(value, this.context.currentTime, 0.01);
        return this;
    }

    // ------------------------------------------------- the mixer's side

    /// The mixer reports this play reached its end.
    endedByMixer(): void {
        this._progress = 0;
        this.onEnded();
        this.isPlaying = false;
        this.dispatchEvent(new Event("ended"));
    }

    /// Writes this Audio's voice parameters (the context calls it every
    /// update). PositionalAudio overrides writeSpatial.
    writeVoice(context: AudioContext, p: StaticArray<f64>, base: i32): void {
        let source = SOURCE_NONE;
        let channels = 1;
        const osc = this.source;
        if (this.sourceType == "audioNode" && osc != null) {
            source = osc.waveform();
            if (osc.generation != this.nodeGeneration) {
                this.nodeGeneration = osc.generation;
                if (osc.started && !osc.stopped) {
                    this.playGen = context.nextGeneration();
                    this.startDelay = osc.startDelay;
                    this.startOffset = 0;
                } else if (osc.stopped) {
                    this.stopGen = context.nextGeneration();
                    this.stopDelay = osc.stopDelay;
                }
            }
            this.isPlaying = osc.started && !osc.stopped;
            p[base + P_FREQUENCY] = osc.frequency.value;
            p[base + P_RATE] = computedPlaybackRate(1, osc.detune.value + this.detune);
        } else {
            const buffer = this.buffer;
            if (buffer != null) {
                const slot = context.bufferSlot(buffer);
                if (slot >= 0) {
                    source = slot;
                    channels = buffer.numberOfChannels;
                }
            }
            p[base + P_FREQUENCY] = 0;
            p[base + P_RATE] = computedPlaybackRate(this.playbackRate, this.detune);
        }
        p[base + P_SOURCE] = <f64>source;
        p[base + P_GEN] = this.playGen;
        p[base + P_PLAYING] = this.isPlaying && this._connected ? 1 : 0;
        p[base + P_OFFSET] = this.startOffset;
        p[base + P_DELAY] = this.startDelay;
        p[base + P_DURATION] = this.duration;
        p[base + P_LOOP] = this.loop ? 1 : 0;
        p[base + P_LOOP_START] = this.loopStart;
        p[base + P_LOOP_END] = this.loopEnd;
        p[base + P_GAIN] = this.gain.gain.value;
        p[base + P_MASTER] = this.listener.gain.gain.value;
        p[base + P_STOP_GEN] = this.stopGen;
        p[base + P_STOP_DELAY] = this.stopDelay;
        const analyser = this.analyser;
        p[base + P_ANALYSER] = analyser != null ? <f64>context.analyserSlot(analyser) : -1;
        p[base + P_TAP_PRE] = 0;
        // Filters: the Audio's, then the listener's.
        let count = 0;
        const rate = context.sampleRate;
        for (let i = 0; i < this.filters.length && count < MIX_MAX_FILTERS - 1; i++) {
            this.filters[i].coefficients(rate, p, base + P_FILTER0 + 5 * count);
            count++;
        }
        const lf = this.listener.filter;
        if (lf != null) {
            lf.coefficients(rate, p, base + P_FILTER0 + 5 * count);
            count++;
        }
        p[base + P_FILTERS] = <f64>count;
        this.writeSpatial(context, p, base, channels);
    }

    /// The panning matrix, interaural delays and head-shadow cutoffs: a
    /// plain Audio is centred (each input channel to its own output).
    writeSpatial(context: AudioContext, p: StaticArray<f64>, base: i32, channels: i32): void {
        p[base + P_LL] = 1;
        p[base + P_LR] = 0;
        p[base + P_RL] = 0;
        p[base + P_RR] = 1;
        p[base + P_ITD_L] = 0;
        p[base + P_ITD_R] = 0;
        p[base + P_LPF_L] = 0;
        p[base + P_LPF_R] = 0;
    }

    /// Whether a fallback sound is playing or held.
    hasFallbackSound(): bool { return this.sound != null; }

    /// Fallback playback through Rive's Audio.play (no processors): the
    /// voice's gain as the sound's volume, loops replayed from loopStart,
    /// no panning, rate, filters or analyser.
    updateFallback(context: AudioContext, p: StaticArray<f64>, base: i32): void {
        const buffer = this.buffer;
        const source = buffer != null ? buffer.source : null;
        if (source == null || this.isNodeSource()) return;
        let sound = this.sound;
        const fade = RiveAudio.sampleRate() * 0.01;
        if (this.isPlaying && (sound == null || this.soundGen != this.playGen)) {
            if (sound != null) sound.stop(fade);
            sound = this.startDelay > 0 ? RiveAudio.playInTime(source, this.startDelay) : RiveAudio.play(source);
            if (sound != null && this.startOffset > 0) sound.seek(this.startOffset);
            this.sound = sound;
            this.soundGen = this.playGen;
            this.soundPaused = false;
        }
        if (sound == null) return;
        if (!this.isPlaying) {
            if (this.paused) {
                if (!this.soundPaused) sound.pause();
                this.soundPaused = true;
            } else {
                sound.stop(fade);
                sound.release();
                this.sound = null;
            }
            return;
        }
        if (this.soundPaused) {
            sound.resume();
            this.soundPaused = false;
        }
        const g = 0.5 * (Math.abs(p[base + P_LL]) + Math.abs(p[base + P_LR]) + Math.abs(p[base + P_RL]) + Math.abs(p[base + P_RR]));
        sound.volume = g * p[base + P_GAIN] * p[base + P_MASTER];
        if (sound.completed()) {
            if (this.loop) {
                sound.seek(this.loopStart);
                sound.play();
            } else {
                sound.release();
                this.sound = null;
                this.endedByMixer();
            }
        }
    }
}

/// Decodes a Rive audio asset into `buffer` on a job thread, at the
/// mixer's rate (the source's own where no processor runs), keeping one or
/// two channels.
export function decodeSource(source: AudioSource, buffer: AudioBuffer): void {
    buffer.source = source;
    const channels = min<u32>(max<u32>(source.channels, 1), 2);
    const rate = RiveAudio.processorSampleRate();
    decodeSourceAsync(source, buffer, rate, channels);
}

async function decodeSourceAsync(source: AudioSource, buffer: AudioBuffer, rate: f64, channels: u32): Promise<void> {
    const settled = await source.toBlob(rate, channels).settled();
    if (!settled.ok) {
        buffer.fail("could not decode '" + buffer.name + "': " + settled.error);
        return;
    }
    buffer.setBlob(settled.value, <i32>channels, rate > 0 ? rate : <f64>source.sampleRate);
}
