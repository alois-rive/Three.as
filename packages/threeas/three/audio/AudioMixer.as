// The audio thread side of ThreeAS's audio (Rive-only plumbing behind
// three.js's Audio classes): one `AudioMixProcessor` per AudioListener
// mixes every voice, and the main lane steers it through shared memory:
//
// - `params`, a Snapshot of every voice's parameters (buffer, transport,
//   loop, rate, the panning matrix with distance and cone gains, volume,
//   interaural delays, head-shadow cutoffs, filters), published each frame
//   by AudioContext.update();
// - `buffers`, a Ring announcing decoded buffers (AudioBuffer: a Blob of
//   interleaved f32 frames, from AudioSource.toBlob or the WAV decoder) by
//   blob id: a processor cannot receive shared objects through a ring, so it
//   takes a handle of its own with `new Blob(id)`, once per buffer;
// - `status`, a Snapshot back: the clock, each voice's position and which
//   play ended;
// - `analysers`, one Snapshot per AudioAnalyser slot: the latest samples of
//   the voice it listens to, for the main lane's FFT.
//
// `MixCore` does the work and runs on any lane (tests drive it directly);
// the processor only wires it to the shared objects. `process` allocates
// nothing except the Blob handle when a buffer arrives. Rate changes,
// gains, pans, delays and cutoffs ramp over each block (a one-pole step of
// MIX_SMOOTHING seconds), starts from an offset fade in over
// MIX_FADE_IN_SECONDS and stops and pauses fade out over
// MIX_FADE_OUT_SECONDS, so nothing clicks.

import { AudioProcessor } from "rive/audio";
import { Ring, Snapshot, Blob } from "rive/shared";

export const MIX_MAX_VOICES: i32 = 32;
export const MIX_MAX_BUFFERS: i32 = 64;
export const MIX_MAX_ANALYSERS: i32 = 4;
/// The largest AnalyserNode fftSize (Web Audio's is 32768).
export const MIX_MAX_FFT: i32 = 4096;
export const MIX_MAX_FILTERS: i32 = 3;

export const MIX_FADE_IN_SECONDS: f64 = 0.005;
export const MIX_FADE_OUT_SECONDS: f64 = 0.01;
export const MIX_SMOOTHING: f64 = 0.01;
/// The mix fades out when the main lane has not published for this long
/// (the script stopped advancing: paused, gone or offscreen).
export const MIX_STALE_SECONDS: f64 = 0.5;

// Voice sources: a buffer slot (>= 0), none, or an oscillator.
export const SOURCE_NONE: i32 = -1;
export const SOURCE_SINE: i32 = -2;
export const SOURCE_SQUARE: i32 = -3;
export const SOURCE_SAWTOOTH: i32 = -4;
export const SOURCE_TRIANGLE: i32 = -5;

// Parameters per voice, in MixParams.data (f64).
export const P_SOURCE: i32 = 0;       // buffer slot, SOURCE_NONE or an oscillator
export const P_GEN: i32 = 1;          // play generation: a new one (re)starts the voice at P_OFFSET
export const P_PLAYING: i32 = 2;      // 1 playing, 0 paused or stopped (fades out and holds)
export const P_OFFSET: i32 = 3;       // seconds into the buffer to start from
export const P_DELAY: i32 = 4;        // seconds to wait before starting
export const P_DURATION: i32 = 5;     // seconds of buffer to play, 0 to the end
export const P_LOOP: i32 = 6;
export const P_LOOP_START: i32 = 7;   // seconds
export const P_LOOP_END: i32 = 8;     // seconds, 0 the buffer's end
export const P_RATE: i32 = 9;         // playbackRate with detune applied
export const P_LL: i32 = 10;          // the panning matrix with distance and cone gains
export const P_LR: i32 = 11;
export const P_RL: i32 = 12;
export const P_RR: i32 = 13;
export const P_GAIN: i32 = 14;        // the Audio's volume
export const P_MASTER: i32 = 15;      // the listener's master volume
export const P_TAP_PRE: i32 = 16;     // 1: the analyser hears the voice before its volume
export const P_ITD_L: i32 = 17;       // seconds the left ear lags
export const P_ITD_R: i32 = 18;
export const P_LPF_L: i32 = 19;       // head-shadow cutoff (Hz) for the left ear, 0 off
export const P_LPF_R: i32 = 20;
export const P_ANALYSER: i32 = 21;    // analyser slot or -1
export const P_STOP_GEN: i32 = 22;    // a new one applies P_PLAYING = 0 after P_STOP_DELAY
export const P_STOP_DELAY: i32 = 23;
export const P_FREQUENCY: i32 = 24;   // oscillator frequency (Hz)
export const P_FILTERS: i32 = 25;     // biquads in use (0 to MIX_MAX_FILTERS)
export const P_FILTER0: i32 = 26;     // MIX_MAX_FILTERS x (b0, b1, b2, a1, a2)
export const P_STRIDE: i32 = P_FILTER0 + 5 * MIX_MAX_FILTERS;

// Status per voice, in MixStatus.data (f64).
export const S_POSITION: i32 = 0;     // seconds into the buffer
export const S_ENDED: i32 = 1;        // the last generation that played to its end
export const S_STATE: i32 = 2;        // VOICE_*
export const S_GEN: i32 = 3;          // the generation in effect
export const S_SOURCE: i32 = 4;       // the source slot currently held by the audio thread
export const S_STRIDE: i32 = 5;

export const VOICE_IDLE: i32 = 0;
export const VOICE_WAITING: i32 = 1;  // a delay, or a buffer not arrived yet
export const VOICE_PLAYING: i32 = 2;
export const VOICE_HELD: i32 = 3;     // paused or stopped: silent, position kept

/// What the main lane publishes every frame.
export class MixParams {
    /// Bumped by each publish: the processor's heartbeat.
    tick: f64 = 0;
    data: StaticArray<f64> = new StaticArray<f64>(MIX_MAX_VOICES * P_STRIDE);
}

/// What the processor publishes every block.
export class MixStatus {
    /// Frames rendered since the start, at `sampleRate`.
    frames: f64 = 0;
    blocks: f64 = 0;
    sampleRate: f64 = 0;
    /// Voices that made sound in the last block.
    active: f64 = 0;
    data: StaticArray<f64> = new StaticArray<f64>(MIX_MAX_VOICES * S_STRIDE);
}

/// A decoded buffer, announced to the processor.
export class MixBuffer {
    slot: i32 = 0;
    blobId: u32 = 0;
    channels: i32 = 1;
    sampleRate: f64 = 48000;
    frames: f64 = 0;
}

/// An analyser's latest samples, oldest first.
export class MixAnalyserFrame {
    /// Samples written since the start.
    written: f64 = 0;
    samples: StaticArray<f32> = new StaticArray<f32>(MIX_MAX_FFT);
}

/// The processor's start argument.
export class MixInputs {
    params: Snapshot<MixParams> = Snapshot.create<MixParams>(<u32>(MIX_MAX_VOICES * P_STRIDE * 8 + 1024));
    status: Snapshot<MixStatus> = Snapshot.create<MixStatus>(<u32>(MIX_MAX_VOICES * S_STRIDE * 8 + 1024));
    buffers: Ring<MixBuffer> = Ring.create<MixBuffer>(8192);
    analysers: Array<Snapshot<MixAnalyserFrame>> = makeAnalyserSnapshots();
}

function makeAnalyserSnapshots(): Array<Snapshot<MixAnalyserFrame>> {
    const list = new Array<Snapshot<MixAnalyserFrame>>();
    for (let i = 0; i < MIX_MAX_ANALYSERS; i++) list.push(Snapshot.create<MixAnalyserFrame>(<u32>(MIX_MAX_FFT * 4 + 256)));
    return list;
}

const WINDOW_FRAMES: i32 = 2048;
const ANALYSER_PUBLISH_FRAMES: i32 = 512;
const DELAY_LENGTH: i32 = 256;           // a power of two
const DELAY_MASK: i32 = DELAY_LENGTH - 1;

/// One voice's state on the audio thread.
export class MixVoice {
    gen: f64 = -1;
    stopGen: f64 = 0;
    endedGen: f64 = -1;
    state: i32 = VOICE_IDLE;
    source: i32 = SOURCE_NONE;
    /// Read position in buffer frames (oscillators: phase in turns).
    pos: f64 = 0;
    /// Frames left to wait before starting / before a delayed stop.
    wait: f64 = 0;
    stopWait: f64 = -1;
    /// Buffer frames left to play (duration), -1 unlimited.
    remaining: f64 = -1;
    /// The fade envelope and its target.
    env: f32 = 0;
    target: f32 = 0;
    /// Starts a new generation once faded out.
    pending: bool = false;
    /// Ends (reports the generation ended) once faded out.
    ending: bool = false;
    // Smoothed parameters.
    ll: f32 = 0; lr: f32 = 0; rl: f32 = 0; rr: f32 = 0;
    gain: f32 = 0;
    tap: f32 = 0;
    rate: f64 = 1;
    itdL: f32 = 0; itdR: f32 = 0;
    lpfL: f32 = 1; lpfR: f32 = 1;
    // Head-shadow low-pass states.
    yL: f32 = 0; yR: f32 = 0;
    // Interaural delay lines.
    delayL: StaticArray<f32> = new StaticArray<f32>(DELAY_LENGTH);
    delayR: StaticArray<f32> = new StaticArray<f32>(DELAY_LENGTH);
    delayWrite: i32 = 0;
    wasDelay: bool = false;
    wasLpf: bool = false;
    // Biquad states (transposed direct form II), per filter and channel.
    biquad: StaticArray<f32> = new StaticArray<f32>(MIX_MAX_FILTERS * 4);
    coefficients: StaticArray<f32> = new StaticArray<f32>(MIX_MAX_FILTERS * 5);
    filters: i32 = 0;
    // The window of the buffer read last: frames [winStart, winStart + winCount).
    window: StaticArray<f32> = new StaticArray<f32>(WINDOW_FRAMES * 2);
    winSlot: i32 = -1;
    winStart: i32 = 0;
    winCount: i32 = 0;
    // Single-frame cache for loop-wrap interpolation (avoids thrashing `window` at low rates).
    loopFrame: StaticArray<f32> = new StaticArray<f32>(2);
    loopCacheSlot: i32 = -1;
    loopCacheIndex: i32 = -1;
    loopCacheL: f32 = 0;
    loopCacheR: f32 = 0;
}

/// The mixer: voices, buffers and analysers. `render` mixes one block.
export class MixCore {
    sampleRate: f64 = 48000;
    channels: i32 = 2;
    maxFrames: i32 = 0;
    voices: Array<MixVoice> = new Array<MixVoice>();
    params: MixParams = new MixParams();
    status: MixStatus = new MixStatus();
    // Buffers by slot.
    blobs: StaticArray<Blob?> = new StaticArray<Blob?>(MIX_MAX_BUFFERS);
    bufferChannels: StaticArray<i32> = new StaticArray<i32>(MIX_MAX_BUFFERS);
    bufferRates: StaticArray<f64> = new StaticArray<f64>(MIX_MAX_BUFFERS);
    bufferFrames: StaticArray<i32> = new StaticArray<i32>(MIX_MAX_BUFFERS);
    // Analysers: a ring of each one's latest samples.
    taps: Array<StaticArray<f32>> = new Array<StaticArray<f32>>();
    tapWrite: StaticArray<i32> = new StaticArray<i32>(MIX_MAX_ANALYSERS);
    tapWritten: StaticArray<f64> = new StaticArray<f64>(MIX_MAX_ANALYSERS);
    tapFed: StaticArray<bool> = new StaticArray<bool>(MIX_MAX_ANALYSERS);
    frame: MixAnalyserFrame = new MixAnalyserFrame();
    // Heartbeat.
    lastTick: f64 = -1;
    staleFrames: f64 = 0;
    masterEnv: f32 = 1;
    frames: f64 = 0;
    blocks: f64 = 0;

    constructor() {
        for (let i = 0; i < MIX_MAX_VOICES; i++) this.voices.push(new MixVoice());
        for (let i = 0; i < MIX_MAX_ANALYSERS; i++) this.taps.push(new StaticArray<f32>(MIX_MAX_FFT));
        for (let i = 0; i < MIX_MAX_VOICES; i++) {
            this.params.data[i * P_STRIDE + P_SOURCE] = <f64>SOURCE_NONE;
            this.status.data[i * S_STRIDE + S_GEN] = -1;
            this.status.data[i * S_STRIDE + S_SOURCE] = <f64>SOURCE_NONE;
        }
    }

    init(sampleRate: f64, maxFrames: i32, channels: i32): void {
        this.sampleRate = sampleRate > 0 && isFinite(sampleRate) ? sampleRate : 48000;
        this.maxFrames = maxFrames > 0 ? maxFrames : 4096;
        this.channels = channels > 0 ? channels : 2;
        this.status.sampleRate = this.sampleRate;
    }

    /// A buffer arrived: its handle (made by the caller) and format.
    setBuffer(slot: i32, blob: Blob?, channels: i32, sampleRate: f64, frames: i32): void {
        if (slot < 0 || slot >= MIX_MAX_BUFFERS) return;
        const valid = blob != null && channels >= 1 && channels <= 2 &&
                      isFinite(sampleRate) && sampleRate > 0 && frames > 0;
        if (valid) {
            this.blobs[slot] = blob;
            this.bufferChannels[slot] = channels;
            this.bufferRates[slot] = sampleRate;
            this.bufferFrames[slot] = frames;
        } else {
            this.blobs[slot] = null;
            this.bufferChannels[slot] = 0;
            this.bufferRates[slot] = 0;
            this.bufferFrames[slot] = 0;
        }
        // Windows and loop caches of an earlier buffer in this slot are stale.
        for (let i = 0; i < this.voices.length; i++) {
            const voice = this.voices[i];
            if (voice.winSlot == slot) voice.winSlot = -1;
            if (voice.loopCacheSlot == slot) voice.loopCacheSlot = -1;
        }
    }

    /// Mixes `frames` frames into `out` (interleaved, `channels` wide, zeroed).
    render(out: StaticArray<f32>, frames: i32): void {
        if (frames <= 0) return;
        if (frames > this.maxFrames) frames = this.maxFrames;
        const maxOutFrames = out.length / this.channels;
        if (frames > maxOutFrames) frames = maxOutFrames;
        if (frames <= 0) return;
        const params = this.params;
        const sr = this.sampleRate;
        // The heartbeat: fade everything out while the main lane is silent.
        if (params.tick != this.lastTick) {
            this.lastTick = params.tick;
            this.staleFrames = 0;
        } else {
            this.staleFrames += <f64>frames;
        }
        const masterTarget: f32 = this.staleFrames > MIX_STALE_SECONDS * sr ? 0 : 1;
        const masterFrom = this.masterEnv;
        const masterStep: f32 = <f32>((1.0 / (MIX_FADE_OUT_SECONDS * 4 * sr)));
        let masterTo = masterFrom;
        if (masterTarget > masterTo) masterTo = min<f32>(1, masterTo + masterStep * <f32>frames);
        else if (masterTarget < masterTo) masterTo = max<f32>(0, masterTo - masterStep * <f32>frames);
        this.masterEnv = masterTo;

        for (let a = 0; a < MIX_MAX_ANALYSERS; a++) this.tapFed[a] = false;
        let active = 0;
        for (let v = 0; v < MIX_MAX_VOICES; v++) {
            if (this.renderVoice(v, out, frames, masterFrom, masterTo)) active++;
        }
        // Analysers whose voice is silent hear silence.
        for (let v = 0; v < MIX_MAX_VOICES; v++) {
            const a = <i32>params.data[v * P_STRIDE + P_ANALYSER];
            if (a >= 0 && a < MIX_MAX_ANALYSERS && !this.tapFed[a]) {
                this.writeTapSilence(a, frames);
                this.tapFed[a] = true;
            }
        }
        this.frames += <f64>frames;
        this.blocks += 1;
        const status = this.status;
        status.frames = this.frames;
        status.blocks = this.blocks;
        status.active = <f64>active;
    }

    /// Whether analyser slot `a` got samples in the last render.
    tapUpdated(a: i32): bool { return this.tapFed[a]; }

    /// Copies analyser `a`'s latest samples, oldest first, into `frame`.
    fillAnalyserFrame(a: i32, frame: MixAnalyserFrame): void {
        const tap = this.taps[a];
        const w = this.tapWrite[a];
        const samples = frame.samples;
        for (let k = 0; k < MIX_MAX_FFT; k++) samples[k] = tap[(w + k) & (MIX_MAX_FFT - 1)];
        frame.written = this.tapWritten[a];
    }

    private writeTapSilence(a: i32, frames: i32): void {
        const tap = this.taps[a];
        let w = this.tapWrite[a];
        for (let i = 0; i < frames; i++) {
            tap[w] = 0;
            w = (w + 1) & (MIX_MAX_FFT - 1);
        }
        this.tapWrite[a] = w;
        this.tapWritten[a] += <f64>frames;
    }

    /// Starts generation `gen` on a voice: position, wait and duration.
    private start(voice: MixVoice, p: StaticArray<f64>, base: i32, source: i32): void {
        const sr = this.sampleRate;
        voice.gen = finiteF64(p[base + P_GEN]);
        voice.source = source;
        voice.pending = false;
        voice.ending = false;
        voice.stopWait = -1;
        const bufferRate = source >= 0 && this.bufferRates[source] > 0 ? this.bufferRates[source] : sr;
        const offset = Math.max(0, finiteF64(p[base + P_OFFSET]));
        voice.pos = source >= 0 ? offset * bufferRate : 0;
        voice.wait = Math.max(0, finiteF64(p[base + P_DELAY])) * sr;
        const duration = finiteF64(p[base + P_DURATION]);
        voice.remaining = duration > 0 ? duration * bufferRate : -1;
        voice.state = voice.wait > 0 ? VOICE_WAITING : VOICE_PLAYING;
        // A start from the beginning keeps its attack; anything else fades in.
        voice.env = offset > 0 || source < 0 ? 0 : 1;
        voice.target = 1;
        voice.yL = 0; voice.yR = 0;
        for (let i = 0; i < DELAY_LENGTH; i++) { voice.delayL[i] = 0; voice.delayR[i] = 0; }
        for (let i = 0; i < MIX_MAX_FILTERS * 4; i++) voice.biquad[i] = 0;
        // Parameters start where they are (no ramp from the last play).
        voice.ll = <f32>finiteF64(p[base + P_LL]); voice.lr = <f32>finiteF64(p[base + P_LR]);
        voice.rl = <f32>finiteF64(p[base + P_RL]); voice.rr = <f32>finiteF64(p[base + P_RR]);
        voice.gain = <f32>finiteF64(p[base + P_GAIN] * p[base + P_MASTER]);
        voice.tap = <f32>finiteF64(p[base + P_TAP_PRE] > 0 ? 1 : p[base + P_GAIN]);
        voice.rate = Math.max(0, finiteF64(p[base + P_RATE], 1));
        voice.itdL = <f32>Math.min(Math.max(finiteF64(p[base + P_ITD_L]) * sr, 0), <f64>(DELAY_LENGTH - 4));
        voice.itdR = <f32>Math.min(Math.max(finiteF64(p[base + P_ITD_R]) * sr, 0), <f64>(DELAY_LENGTH - 4));
        voice.lpfL = <f32>onePole(finiteF64(p[base + P_LPF_L]), sr);
        voice.lpfR = <f32>onePole(finiteF64(p[base + P_LPF_R]), sr);
        voice.wasDelay = voice.itdL > 0 || voice.itdR > 0;
        voice.wasLpf = voice.lpfL < 1 || voice.lpfR < 1;
    }

    /// Mixes voice `v` into `out`; whether it made sound.
    private renderVoice(v: i32, out: StaticArray<f32>, frames: i32, masterFrom: f32, masterTo: f32): bool {
        const voice = this.voices[v];
        const p = this.params.data;
        const base = v * P_STRIDE;
        const source = <i32>p[base + P_SOURCE];
        const sr = this.sampleRate;
        const status = this.status.data;
        const sbase = v * S_STRIDE;

        // Transport.
        const gen = finiteF64(p[base + P_GEN]);
        const hasSource = source < SOURCE_NONE || (source >= 0 && source < MIX_MAX_BUFFERS &&
            this.blobs[source] != null && this.bufferChannels[source] >= 1 &&
            this.bufferChannels[source] <= 2 && this.bufferRates[source] > 0 && this.bufferFrames[source] > 0);
        let justStarted = false;
        if (gen != voice.gen && gen > 0) {
            if (voice.state == VOICE_PLAYING && voice.env > 0) {
                // Fade the old play out first.
                voice.pending = true;
                voice.target = 0;
            } else if (hasSource) {
                this.start(voice, p, base, source);
                justStarted = true;
            }
        }
        if (source == SOURCE_NONE && voice.state != VOICE_IDLE && !voice.pending) {
            voice.target = 0;
            voice.ending = false;
            if (voice.state == VOICE_HELD || voice.state == VOICE_WAITING || voice.env <= 0) {
                voice.state = VOICE_IDLE;
                voice.source = SOURCE_NONE;
                voice.env = 0;
                voice.wait = 0;
            }
        }
        const stopGen = finiteF64(p[base + P_STOP_GEN]);
        if (stopGen != voice.stopGen) {
            voice.stopGen = stopGen;
            voice.stopWait = Math.max(0, finiteF64(p[base + P_STOP_DELAY])) * sr;
        }
        const playing = p[base + P_PLAYING] > 0;
        if (!voice.pending && !voice.ending) {
            if (playing) {
                if (voice.state == VOICE_HELD && gen == voice.gen) {
                    voice.state = VOICE_PLAYING;   // resume
                }
                voice.target = 1;
            } else if (voice.stopWait <= 0) {
                voice.target = 0;
            }
        }
        if (voice.stopWait > 0) {
            voice.stopWait -= <f64>frames;
            if (voice.stopWait <= 0 && !playing) voice.target = 0;
        }

        // If stopped before emitting any audio (waiting in delay or stopped on the
        // very block it started), silence immediately instead of a 10 ms fade-out burst.
        if ((voice.state == VOICE_WAITING || justStarted) && voice.target <= 0 && !voice.pending) {
            voice.env = 0;
            voice.wait = 0;
            if (source == SOURCE_NONE) {
                voice.state = VOICE_IDLE;
                voice.source = SOURCE_NONE;
            } else {
                voice.state = VOICE_HELD;
            }
        }

        let made = false;
        if (voice.state == VOICE_WAITING) {
            if (voice.wait >= <f64>frames) {
                voice.wait -= <f64>frames;
            } else {
                const skip = <i32>voice.wait;
                voice.wait = 0;
                voice.state = VOICE_PLAYING;
                made = this.mix(voice, p, base, out, skip, frames, masterFrom, masterTo);
            }
        } else if (voice.state == VOICE_PLAYING) {
            made = this.mix(voice, p, base, out, 0, frames, masterFrom, masterTo);
        }
        // A pending start once the old play has faded.
        if (voice.pending && voice.env <= 0) {
            voice.pending = false;
            if (hasSource) {
                this.start(voice, p, base, source);
                if (!playing && voice.stopWait <= 0) {
                    voice.env = 0;
                    voice.target = 0;
                    voice.wait = 0;
                    voice.state = VOICE_HELD;
                }
            } else {
                voice.state = VOICE_IDLE;
                voice.source = SOURCE_NONE;
            }
        }

        const br = voice.source >= 0 && voice.source < MIX_MAX_BUFFERS ? this.bufferRates[voice.source] : 0;
        status[sbase + S_POSITION] = source >= 0 && voice.source >= 0 && br > 0 ? voice.pos / br : 0;
        status[sbase + S_ENDED] = voice.endedGen;
        status[sbase + S_STATE] = <f64>voice.state;
        status[sbase + S_GEN] = voice.gen;
        status[sbase + S_SOURCE] = <f64>voice.source;
        return made;
    }

    /// Renders frames [from, frames) of a playing voice into `out`.
    private mix(voice: MixVoice, p: StaticArray<f64>, base: i32, out: StaticArray<f32>, from: i32, frames: i32,
                masterFrom: f32, masterTo: f32): bool {
        if (from < 0) from = 0;
        const sr = this.sampleRate;
        const n = frames - from;
        if (n <= 0) return false;
        const fn = <f32>n;
        // Block ramps: each parameter moves toward its target by a one-pole
        // step over the block, linearly within it.
        const k = <f32>(1 - Math.exp(-<f64>n / (MIX_SMOOTHING * sr)));
        const tLL = <f32>finiteF64(p[base + P_LL]), tLR = <f32>finiteF64(p[base + P_LR]);
        const tRL = <f32>finiteF64(p[base + P_RL]), tRR = <f32>finiteF64(p[base + P_RR]);
        const tGain = <f32>finiteF64(p[base + P_GAIN] * p[base + P_MASTER]);
        const tTap = <f32>finiteF64(p[base + P_TAP_PRE] > 0 ? 1 : p[base + P_GAIN]);
        const tItdL = <f32>(Math.min(Math.max(finiteF64(p[base + P_ITD_L]) * sr, 0), <f64>(DELAY_LENGTH - 4)));
        const tItdR = <f32>(Math.min(Math.max(finiteF64(p[base + P_ITD_R]) * sr, 0), <f64>(DELAY_LENGTH - 4)));
        const tLpfL = <f32>onePole(finiteF64(p[base + P_LPF_L]), sr), tLpfR = <f32>onePole(finiteF64(p[base + P_LPF_R]), sr);
        const tRate = Math.max(0, finiteF64(p[base + P_RATE]));

        let ll = finiteF32(voice.ll), lr = finiteF32(voice.lr), rl = finiteF32(voice.rl), rr = finiteF32(voice.rr);
        const dll = (tLL - ll) * k / fn, dlr = (tLR - lr) * k / fn, drl = (tRL - rl) * k / fn, drr = (tRR - rr) * k / fn;
        let gain = finiteF32(voice.gain), tap = finiteF32(voice.tap);
        const dgain = (tGain - gain) * k / fn, dtap = (tTap - tap) * k / fn;
        let itdL = finiteF32(voice.itdL), itdR = finiteF32(voice.itdR);
        const ditdL = (tItdL - itdL) * k / fn, ditdR = (tItdR - itdR) * k / fn;
        let lpfL = finiteF32(voice.lpfL, 1), lpfR = finiteF32(voice.lpfR, 1);
        const dlpfL = (tLpfL - lpfL) * k / fn, dlpfR = (tLpfR - lpfR) * k / fn;
        let rate = Math.max(0, finiteF64(voice.rate, 1));
        const drate = (tRate - rate) * <f64>k / <f64>n;
        const useDelay = tItdL > 0 || tItdR > 0 || itdL > 0 || itdR > 0;
        const useLpf = tLpfL < 1 || tLpfR < 1 || lpfL < 1 || lpfR < 1;
        let initDelay = useDelay && !voice.wasDelay;
        let initLpf = useLpf && !voice.wasLpf;

        // Filters (validate finiteness and Jury stability before applying).
        let filters = <i32>finiteF64(p[base + P_FILTERS]);
        if (filters < 0) filters = 0;
        if (filters > MIX_MAX_FILTERS) filters = MIX_MAX_FILTERS;
        if (filters != voice.filters) {
            for (let i = 0; i < MIX_MAX_FILTERS * 4; i++) voice.biquad[i] = 0;
            voice.filters = filters;
        }
        for (let f = 0; f < filters; f++) {
            const c = f * 5;
            const pb = base + P_FILTER0 + c;
            const b0 = <f32>p[pb], b1 = <f32>p[pb + 1], b2 = <f32>p[pb + 2];
            const a1 = <f32>p[pb + 3], a2 = <f32>p[pb + 4];
            if (isFinite(<f64>b0) && isFinite(<f64>b1) && isFinite(<f64>b2) &&
                isFinite(<f64>a1) && isFinite(<f64>a2) &&
                Mathf.abs(a2) < 1 && <f32>1 + a1 + a2 > 0 && <f32>1 - a1 + a2 > 0) {
                voice.coefficients[c] = b0;
                voice.coefficients[c + 1] = b1;
                voice.coefficients[c + 2] = b2;
                voice.coefficients[c + 3] = a1;
                voice.coefficients[c + 4] = a2;
            } else {
                voice.coefficients[c] = 1;
                voice.coefficients[c + 1] = 0;
                voice.coefficients[c + 2] = 0;
                voice.coefficients[c + 3] = 0;
                voice.coefficients[c + 4] = 0;
            }
        }

        // Envelope.
        const fadeIn = <f32>(1.0 / (MIX_FADE_IN_SECONDS * sr));
        const fadeOut = <f32>(1.0 / (MIX_FADE_OUT_SECONDS * sr));
        let env = finiteF32(voice.env);
        let target = finiteF32(voice.target);
        let master = masterFrom;
        const dmaster = (masterTo - masterFrom) / <f32>frames;
        master += dmaster * <f32>from;

        // Source.
        const source = voice.source;
        const isBuffer = source >= 0;
        let channels = 1, bufferFrames = 0;
        let ratio: f64 = 1;
        let loop = false;
        let loopStart: f64 = 0, loopEnd: f64 = 0;
        let finished = false;
        if (isBuffer) {
            if (source >= MIX_MAX_BUFFERS || this.blobs[source] == null ||
                this.bufferChannels[source] < 1 || this.bufferChannels[source] > 2 ||
                !(this.bufferRates[source] > 0) || this.bufferFrames[source] <= 0) {
                finished = true;
            } else {
                channels = this.bufferChannels[source];
                bufferFrames = this.bufferFrames[source];
                const bufferRate = this.bufferRates[source];
                ratio = bufferRate / sr;
                loop = p[base + P_LOOP] > 0;
                const ls = finiteF64(p[base + P_LOOP_START]) * bufferRate;
                const le = finiteF64(p[base + P_LOOP_END]) * bufferRate;
                if (ls >= 0 && le > 0 && ls < le) {
                    loopStart = ls;
                    loopEnd = Math.min(le, <f64>bufferFrames);
                } else {
                    loopStart = 0;
                    loopEnd = <f64>bufferFrames;
                }
                if (loopEnd - loopStart < 1) loop = false;
            }
        }
        const frequency = finiteF64(p[base + P_FREQUENCY]);
        let pos = Math.max(0, finiteF64(voice.pos));
        let remaining = isFinite(voice.remaining) ? voice.remaining : -1;
        const outChannels = this.channels;
        const analyser = <i32>p[base + P_ANALYSER];
        const hasTap = analyser >= 0 && analyser < MIX_MAX_ANALYSERS;
        let tapBuffer = hasTap ? this.taps[analyser] : this.taps[0];
        let tapW = hasTap ? this.tapWrite[analyser] : 0;
        const delayL = voice.delayL, delayR = voice.delayR;
        let dw = voice.delayWrite;
        let yL = flushDenormal(voice.yL), yR = flushDenormal(voice.yR);
        const loopStartI = <i32>Math.floor(loopStart), loopEndI = <i32>Math.ceil(loopEnd);
        let made = false;

        // Keep tap buffer and tapWritten aligned with the full block when starting mid-block.
        if (hasTap && from > 0) {
            for (let j = 0; j < from; j++) {
                tapBuffer[tapW] = 0;
                tapW = (tapW + 1) & (MIX_MAX_FFT - 1);
            }
        }

        if (finished) {
            if (hasTap) {
                for (let j = from; j < frames; j++) {
                    tapBuffer[tapW] = 0;
                    tapW = (tapW + 1) & (MIX_MAX_FFT - 1);
                }
            }
        } else {
            for (let i = from; i < frames; i++) {
                // Envelope.
                if (env < target) env = min<f32>(target, env + fadeIn);
                else if (env > target) env = max<f32>(target, env - fadeOut);

                let inL: f32 = 0, inR: f32 = 0;
                if (isBuffer) {
                    const i0 = <i32>Math.floor(pos);
                    const frac = <f32>(pos - <f64>i0);
                    let i1 = i0 + 1;
                    let wrapped = false;
                    if (loop && i1 >= loopEndI) {
                        i1 = loopStartI + (i1 - loopEndI);
                        wrapped = true;
                    }
                    const o0 = this.fetch(voice, source, i0, channels, bufferFrames);
                    const a0 = o0 >= 0 ? voice.window[o0] : <f32>0;
                    const a1 = o0 >= 0 && channels > 1 ? voice.window[o0 + 1] : a0;
                    let b0: f32 = 0, b1: f32 = 0;
                    if (wrapped && (voice.winSlot != source || i1 < voice.winStart || i1 >= voice.winStart + voice.winCount)) {
                        if (voice.loopCacheSlot != source || voice.loopCacheIndex != i1) {
                            const blob = this.blobs[source];
                            if (blob != null && i1 >= 0 && i1 < bufferFrames) {
                                const got = <i32>blob.readInto(<u32>i1 * <u32>channels * 4, voice.loopFrame, 0, channels);
                                if (got >= channels) {
                                    voice.loopCacheL = voice.loopFrame[0];
                                    voice.loopCacheR = channels > 1 ? voice.loopFrame[1] : voice.loopFrame[0];
                                } else {
                                    voice.loopCacheL = 0;
                                    voice.loopCacheR = 0;
                                }
                            } else {
                                voice.loopCacheL = 0;
                                voice.loopCacheR = 0;
                            }
                            voice.loopCacheSlot = source;
                            voice.loopCacheIndex = i1;
                        }
                        b0 = voice.loopCacheL;
                        b1 = voice.loopCacheR;
                    } else {
                        const o1 = this.fetch(voice, source, i1, channels, bufferFrames);
                        b0 = o1 >= 0 ? voice.window[o1] : <f32>0;
                        b1 = o1 >= 0 && channels > 1 ? voice.window[o1 + 1] : b0;
                    }
                    inL = a0 + (b0 - a0) * frac;
                    inR = a1 + (b1 - a1) * frac;
                    const step = rate * ratio;
                    pos += step;
                    if (remaining >= 0) {
                        remaining -= step;
                        if (remaining <= 0 && !voice.ending) { voice.ending = true; voice.target = 0; target = 0; }
                    }
                    if (loop) {
                        if (pos >= loopEnd) {
                            const len = loopEnd - loopStart;
                            pos = loopStart + (pos - loopEnd) % len;
                        }
                    } else if (pos >= <f64>bufferFrames) {
                        finished = true;
                    }
                } else {
                    // Oscillators (naive waveforms, phase in turns).
                    const ph = <f32>pos;
                    let s: f32 = 0;
                    if (source == SOURCE_SINE) s = Mathf.sin(ph * <f32>(2 * Math.PI));
                    else if (source == SOURCE_SQUARE) s = ph < 0.5 ? 1 : -1;
                    else if (source == SOURCE_SAWTOOTH) s = 2 * ph - 1;
                    else s = ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph;
                    inL = s; inR = s;
                    pos += frequency * rate / sr;
                    pos -= Math.floor(pos);
                    if (!isFinite(pos)) pos = 0;
                }

                if (!isFinite(<f64>inL)) inL = 0;
                if (!isFinite(<f64>inR)) inR = 0;

                // Filters (on each input channel), with NaN recovery and denormal flush.
                for (let f = 0; f < filters; f++) {
                    const c = f * 5, st = f * 4;
                    const b0 = voice.coefficients[c], b1 = voice.coefficients[c + 1], b2 = voice.coefficients[c + 2];
                    const a1 = voice.coefficients[c + 3], a2 = voice.coefficients[c + 4];
                    let z1 = voice.biquad[st], z2 = voice.biquad[st + 1];
                    let yl = b0 * inL + z1;
                    if (!isFinite(<f64>yl)) {
                        yl = 0; z1 = 0; z2 = 0;
                    } else {
                        z1 = flushDenormal(b1 * inL - a1 * yl + z2);
                        z2 = flushDenormal(b2 * inL - a2 * yl);
                    }
                    voice.biquad[st] = z1;
                    voice.biquad[st + 1] = z2;
                    inL = yl;
                    if (channels > 1) {
                        let zr1 = voice.biquad[st + 2], zr2 = voice.biquad[st + 3];
                        let yr = b0 * inR + zr1;
                        if (!isFinite(<f64>yr)) {
                            yr = 0; zr1 = 0; zr2 = 0;
                        } else {
                            zr1 = flushDenormal(b1 * inR - a1 * yr + zr2);
                            zr2 = flushDenormal(b2 * inR - a2 * yr);
                        }
                        voice.biquad[st + 2] = zr1;
                        voice.biquad[st + 3] = zr2;
                        inR = yr;
                    } else {
                        inR = inL;
                    }
                }

                // Panning, distance and cone.
                let l = (ll * inL + lr * inR) * env;
                let r = (rl * inL + rr * inR) * env;
                if (!isFinite(<f64>l)) l = 0;
                if (!isFinite(<f64>r)) r = 0;
                ll += dll; lr += dlr; rl += drl; rr += drr;

                // Interaural delay.
                if (useDelay) {
                    if (initDelay) {
                        for (let d = 0; d < DELAY_LENGTH; d++) { delayL[d] = l; delayR[d] = r; }
                        initDelay = false;
                    }
                    delayL[dw] = l;
                    delayR[dw] = r;
                    l = readDelay(delayL, dw, itdL);
                    r = readDelay(delayR, dw, itdR);
                    if (!isFinite(<f64>l)) l = 0;
                    if (!isFinite(<f64>r)) r = 0;
                    dw = (dw + 1) & DELAY_MASK;
                    itdL += ditdL; itdR += ditdR;
                }
                // Head shadow.
                if (useLpf) {
                    if (initLpf) {
                        yL = flushDenormal(l);
                        yR = flushDenormal(r);
                        initLpf = false;
                    }
                    yL = flushDenormal(yL + lpfL * (l - yL));
                    yR = flushDenormal(yR + lpfR * (r - yR));
                    l = yL; r = yR;
                    lpfL += dlpfL; lpfR += dlpfR;
                }

                if (hasTap) {
                    const ts = (l + r) * 0.5 * tap;
                    tapBuffer[tapW] = isFinite(<f64>ts) ? ts : 0;
                    tapW = (tapW + 1) & (MIX_MAX_FFT - 1);
                    tap += dtap;
                }
                const g = gain * master;
                gain += dgain;
                master += dmaster;
                const o = i * outChannels;
                if (outChannels >= 2) {
                    const ol = l * g, or = r * g;
                    if (isFinite(<f64>ol)) out[o] += ol;
                    if (isFinite(<f64>or)) out[o + 1] += or;
                } else {
                    const om = (l + r) * 0.5 * g;
                    if (isFinite(<f64>om)) out[o] += om;
                }
                rate += drate;
                if (finished) {
                    // Played to the end: the rest of the block is silence.
                    if (hasTap) {
                        for (let j = i + 1; j < frames; j++) {
                            tapBuffer[tapW] = 0;
                            tapW = (tapW + 1) & (MIX_MAX_FFT - 1);
                        }
                    }
                    break;
                }
                if (env <= 0 && target <= 0) {
                    if (hasTap) {
                        for (let j = i + 1; j < frames; j++) {
                            tapBuffer[tapW] = 0;
                            tapW = (tapW + 1) & (MIX_MAX_FFT - 1);
                        }
                    }
                    break;
                }
            }
            made = true;
        }

        voice.ll = finiteF32(tLL - (tLL - voice.ll) * (1 - k));
        voice.lr = finiteF32(tLR - (tLR - voice.lr) * (1 - k));
        voice.rl = finiteF32(tRL - (tRL - voice.rl) * (1 - k));
        voice.rr = finiteF32(tRR - (tRR - voice.rr) * (1 - k));
        voice.gain = finiteF32(tGain - (tGain - voice.gain) * (1 - k));
        voice.tap = finiteF32(tTap - (tTap - voice.tap) * (1 - k));
        let nextItdL = finiteF32(tItdL - (tItdL - voice.itdL) * (1 - k));
        let nextItdR = finiteF32(tItdR - (tItdR - voice.itdR) * (1 - k));
        if (tItdL == 0 && nextItdL < <f32>1e-5) nextItdL = 0;
        if (tItdR == 0 && nextItdR < <f32>1e-5) nextItdR = 0;
        voice.itdL = nextItdL;
        voice.itdR = nextItdR;
        let nextLpfL = finiteF32(tLpfL - (tLpfL - voice.lpfL) * (1 - k), 1);
        let nextLpfR = finiteF32(tLpfR - (tLpfR - voice.lpfR) * (1 - k), 1);
        if (tLpfL == 1 && <f32>1 - nextLpfL < <f32>1e-5) nextLpfL = 1;
        if (tLpfR == 1 && <f32>1 - nextLpfR < <f32>1e-5) nextLpfR = 1;
        voice.lpfL = nextLpfL;
        voice.lpfR = nextLpfR;
        voice.wasDelay = useDelay;
        voice.wasLpf = useLpf;
        voice.rate = Math.max(0, finiteF64(tRate - (tRate - voice.rate) * <f64>(1 - k), 1));
        voice.pos = Math.max(0, finiteF64(pos));
        voice.remaining = remaining;
        voice.env = finiteF32(env);
        voice.delayWrite = dw;
        voice.yL = flushDenormal(yL);
        voice.yR = flushDenormal(yR);
        if (hasTap) {
            this.tapWrite[analyser] = tapW;
            this.tapWritten[analyser] += <f64>frames;
            this.tapFed[analyser] = true;
        }

        if (finished || (voice.ending && env <= 0)) {
            voice.endedGen = voice.gen;
            voice.state = VOICE_IDLE;
            voice.source = SOURCE_NONE;
            voice.ending = false;
            voice.env = 0;
        } else if (env <= 0 && target <= 0 && !voice.pending) {
            if (<i32>p[base + P_SOURCE] == SOURCE_NONE) {
                voice.state = VOICE_IDLE;
                voice.source = SOURCE_NONE;
            } else {
                voice.state = VOICE_HELD;   // paused or stopped: keep the position
            }
        }
        return made;
    }

    /// The window offset of frame `index` of buffer `slot` (loading the
    /// window around it when needed), or -1 outside the buffer.
    @inline
    private fetch(voice: MixVoice, slot: i32, index: i32, channels: i32, frames: i32): i32 {
        if (index < 0 || index >= frames || channels < 1 || channels > 2) return -1;
        if (voice.winSlot != slot || index < voice.winStart || index >= voice.winStart + voice.winCount) {
            const blob = this.blobs[slot];
            if (blob == null) return -1;
            // Overlap by one frame when advancing across a window boundary so
            // low playback rates don't thrash between i0 and i1 = i0 + 1.
            const start = index > 0 ? index - 1 : 0;
            const count = min<i32>(WINDOW_FRAMES, frames - start);
            const got = <i32>blob.readInto(<u32>start * <u32>channels * 4, voice.window, 0, count * channels);
            voice.winSlot = slot;
            voice.winStart = start;
            voice.winCount = got / channels;
            if (voice.winCount <= 0 || index < voice.winStart || index >= voice.winStart + voice.winCount) {
                voice.winSlot = -1;
                return -1;
            }
        }
        return (index - voice.winStart) * channels;
    }
}

@inline
function finiteF64(x: f64, fallback: f64 = 0): f64 {
    return isFinite(x) ? x : fallback;
}

@inline
function finiteF32(x: f32, fallback: f32 = 0): f32 {
    return isFinite(<f64>x) ? x : fallback;
}

@inline
function flushDenormal(x: f32): f32 {
    if (!isFinite(<f64>x)) return 0;
    return Mathf.abs(x) < <f32>1e-20 ? <f32>0 : x;
}

@inline
function readDelay(line: StaticArray<f32>, write: i32, delay: f32): f32 {
    const r = <f32>write - delay;
    const fl = Mathf.floor(r);
    const i = <i32>fl & DELAY_MASK;
    const f = r - fl;
    const a = line[i], b = line[(i + 1) & DELAY_MASK];
    return a + (b - a) * f;
}

function onePole(cutoff: f64, sampleRate: f64): f64 {
    if (!isFinite(cutoff) || cutoff <= 0 || cutoff >= sampleRate / 2) return 1;
    return 1 - Math.exp(-2 * Math.PI * cutoff / sampleRate);
}

/// The processor: MixCore wired to the listener's shared objects.
export class AudioMixProcessor extends AudioProcessor<MixInputs> {
    inputs: MixInputs? = null;
    core: MixCore = new MixCore();
    message: MixBuffer = new MixBuffer();
    paramsSeq: f64 = -1;
    sincePublish: i32 = 1 << 30;

    override init(sampleRate: f64, maxFrames: i32, channels: i32, inputs: MixInputs): void {
        this.inputs = inputs;
        this.core.init(sampleRate, maxFrames, channels);
    }

    override process(out: StaticArray<f32>, frames: i32, startFrame: f64): void {
        const inputs = this.inputs!;
        const core = this.core;
        while (inputs.buffers.used != 0 && inputs.buffers.receiveInto(this.message)) {
            const m = this.message;
            // The one allocation: a handle on the decoded buffer.
            core.setBuffer(m.slot, new Blob(m.blobId), m.channels, m.sampleRate, <i32>m.frames);
        }
        const seq = inputs.params.seq;
        if (seq != this.paramsSeq) {
            this.paramsSeq = seq;
            inputs.params.latestInto(core.params);
        }
        core.render(out, frames);
        inputs.status.publish(core.status);
        // Analysers, at most every ANALYSER_PUBLISH_FRAMES (the main lane
        // reads them once a frame).
        this.sincePublish += frames;
        if (this.sincePublish >= ANALYSER_PUBLISH_FRAMES) {
            this.sincePublish = 0;
            for (let a = 0; a < MIX_MAX_ANALYSERS; a++) {
                if (core.tapUpdated(a)) {
                    core.fillAnalyserFrame(a, core.frame);
                    inputs.analysers[a].publish(core.frame);
                }
            }
        }
    }
}
