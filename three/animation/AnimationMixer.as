// three.js AnimationMixer and AnimationAction: plays clips on a root
// object, blending actions by weight (fades and cross-fades included).
//
//     mixer = new AnimationMixer(model);
//     const action = mixer.clipAction(clip);
//     action.play();
//     // each advance:
//     mixer.update(seconds);
//
// Events ("finished", "loop") are not dispatched; poll action.isRunning()
// or action.enabled / action.paused.

import { Object3D } from "../core/Object3D";
import { AnimationClip } from "./AnimationClip";
import { PropertyBinding } from "./PropertyBinding";
import { LoopOnce, LoopRepeat, LoopPingPong } from "../constants";

/// Accumulates the weighted values of every action driving one property.
export class PropertyMixer {
    binding: PropertyBinding;
    valueSize: i32;
    original: Float64Array;
    accum: Float64Array;
    cumulativeWeight: f64 = 0;
    useCount: i32 = 0;

    constructor(binding: PropertyBinding) {
        this.binding = binding;
        this.valueSize = binding.valueSize;
        this.original = new Float64Array(this.valueSize);
        this.accum = new Float64Array(this.valueSize);
        binding.getValue(this.original);
    }

    accumulate(incoming: Float64Array, weight: f64): void {
        if (weight == 0) return;
        const n = this.valueSize;
        if (this.cumulativeWeight == 0) {
            for (let i = 0; i < n; i++) this.accum[i] = incoming[i];
            this.cumulativeWeight = weight;
        } else {
            this.cumulativeWeight += weight;
            this.mix(this.accum, incoming, weight / this.cumulativeWeight);
        }
    }

    /// Writes the blend to the property (towards the original value where
    /// the actions' weights sum below 1).
    apply(): void {
        const weight = this.cumulativeWeight;
        if (weight > 0) {
            if (weight < 1) this.mix(this.accum, this.original, 1 - weight);
            this.binding.setValue(this.accum);
        }
        this.cumulativeWeight = 0;
    }

    saveOriginalState(): void { this.binding.getValue(this.original); }
    restoreOriginalState(): void { this.binding.setValue(this.original); }

    private mix(into: Float64Array, from: Float64Array, t: f64): void {
        const n = this.valueSize;
        if (this.binding.isQuaternion) {
            let x1 = from[0], y1 = from[1], z1 = from[2], w1 = from[3];
            const x0 = into[0], y0 = into[1], z0 = into[2], w0 = into[3];
            let cos = x0 * x1 + y0 * y1 + z0 * z1 + w0 * w1;
            if (cos < 0) { x1 = -x1; y1 = -y1; z1 = -z1; w1 = -w1; cos = -cos; }
            let s0 = 1 - t, s1 = t;
            if (cos < 0.9995) {
                const theta = Math.acos(Math.min(1, cos));
                const sin = Math.sin(theta);
                s0 = Math.sin((1 - t) * theta) / sin;
                s1 = Math.sin(t * theta) / sin;
            }
            into[0] = x0 * s0 + x1 * s1; into[1] = y0 * s0 + y1 * s1;
            into[2] = z0 * s0 + z1 * s1; into[3] = w0 * s0 + w1 * s1;
            const l = Math.sqrt(into[0] * into[0] + into[1] * into[1] + into[2] * into[2] + into[3] * into[3]);
            if (l > 0) for (let i = 0; i < 4; i++) into[i] /= l;
        } else {
            for (let i = 0; i < n; i++) into[i] += (from[i] - into[i]) * t;
        }
    }
}

export class AnimationAction {
    readonly mixer: AnimationMixer;
    readonly clip: AnimationClip;
    readonly localRoot: Object3D;
    /// LoopOnce, LoopRepeat or LoopPingPong.
    loop: i32 = LoopRepeat;
    repetitions: f64 = Infinity;
    /// Local time, seconds.
    time: f64 = 0;
    timeScale: f64 = 1;
    weight: f64 = 1;
    enabled: bool = true;
    paused: bool = false;
    /// Hold the last frame when a LoopOnce (or the last repetition) ends.
    clampWhenFinished: bool = false;

    private mixers: Array<PropertyMixer?> = [];
    private buffers: Array<Float64Array> = [];
    private loopCount: f64 = -1;
    private startTime: f64 = -1;
    private effectiveWeight: f64 = 1;
    private effectiveTimeScale: f64 = 1;
    private fading: bool = false;
    private fadeStart: f64 = 0;
    private fadeDuration: f64 = 0;
    private fadeFrom: f64 = 0;
    private fadeTo: f64 = 0;

    constructor(mixer: AnimationMixer, clip: AnimationClip, localRoot: Object3D) {
        this.mixer = mixer;
        this.clip = clip;
        this.localRoot = localRoot;
        const tracks = clip.tracks;
        for (let i = 0; i < tracks.length; i++) {
            const pm = mixer.bindingFor(localRoot, tracks[i].name);
            this.mixers.push(pm);
            this.buffers.push(new Float64Array(max<i32>(4, tracks[i].getValueSize())));
        }
    }

    play(): AnimationAction {
        this.mixer.activate(this);
        return this;
    }

    stop(): AnimationAction {
        this.mixer.deactivate(this);
        return this.reset();
    }

    reset(): AnimationAction {
        this.paused = false;
        this.enabled = true;
        this.time = 0;
        this.loopCount = -1;
        this.startTime = -1;
        return this.stopFading();
    }

    isRunning(): bool {
        return this.enabled && !this.paused && this.timeScale != 0 && this.startTime < 0 && this.mixer.isActive(this);
    }

    isScheduled(): bool { return this.mixer.isActive(this); }

    startAt(time: f64): AnimationAction {
        this.startTime = time;
        return this;
    }

    setLoop(mode: i32, repetitions: f64 = Infinity): AnimationAction {
        this.loop = mode;
        this.repetitions = repetitions;
        return this;
    }

    setEffectiveWeight(weight: f64): AnimationAction {
        this.weight = weight;
        this.effectiveWeight = this.enabled ? weight : 0;
        return this.stopFading();
    }

    getEffectiveWeight(): f64 { return this.effectiveWeight; }

    setEffectiveTimeScale(timeScale: f64): AnimationAction {
        this.timeScale = timeScale;
        this.effectiveTimeScale = this.paused ? 0 : timeScale;
        return this;
    }

    getEffectiveTimeScale(): f64 { return this.effectiveTimeScale; }

    /// Plays the clip in `duration` seconds.
    setDuration(duration: f64): AnimationAction {
        this.timeScale = this.clip.duration / duration;
        return this;
    }

    syncWith(action: AnimationAction): AnimationAction {
        this.time = action.time;
        this.timeScale = action.timeScale;
        return this;
    }

    fadeIn(duration: f64): AnimationAction { return this.scheduleFading(duration, 0, 1); }
    fadeOut(duration: f64): AnimationAction { return this.scheduleFading(duration, 1, 0); }

    crossFadeFrom(fadeOutAction: AnimationAction, duration: f64, warp: bool = false): AnimationAction {
        fadeOutAction.fadeOut(duration);
        this.fadeIn(duration);
        return this;
    }

    crossFadeTo(fadeInAction: AnimationAction, duration: f64, warp: bool = false): AnimationAction {
        return fadeInAction.crossFadeFrom(this, duration, warp);
    }

    stopFading(): AnimationAction {
        this.fading = false;
        return this;
    }

    getMixer(): AnimationMixer { return this.mixer; }
    getClip(): AnimationClip { return this.clip; }
    getRoot(): Object3D { return this.localRoot; }

    private scheduleFading(duration: f64, from: f64, to: f64): AnimationAction {
        this.fading = true;
        this.fadeStart = this.mixer.time;
        this.fadeDuration = duration;
        this.fadeFrom = from;
        this.fadeTo = to;
        return this;
    }

    /// Advances and accumulates (internal; the mixer calls it).
    update(mixerTime: f64, deltaTime: f64, timeDirection: f64): void {
        if (!this.enabled) {
            this.updateWeight(mixerTime);
            return;
        }
        if (this.startTime >= 0) {
            const running = (mixerTime - this.startTime) * timeDirection;
            if (running < 0 || timeDirection == 0) {
                deltaTime = 0;
            } else {
                this.startTime = -1;
                deltaTime = timeDirection * running;
            }
        }
        this.effectiveTimeScale = this.paused ? 0 : this.timeScale;
        deltaTime *= this.effectiveTimeScale;
        const clipTime = this.updateTime(deltaTime);
        const weight = this.updateWeight(mixerTime);
        if (weight > 0) {
            const tracks = this.clip.tracks;
            for (let i = 0; i < tracks.length; i++) {
                const pm = this.mixers[i];
                if (pm == null) continue;
                tracks[i].evaluate(clipTime, this.buffers[i]);
                pm.accumulate(this.buffers[i], weight);
            }
        }
    }

    private updateWeight(time: f64): f64 {
        let weight: f64 = 0;
        if (this.enabled) {
            weight = this.weight;
            if (this.fading) {
                const t = this.fadeDuration > 0 ? Math.min(1, Math.max(0, (time - this.fadeStart) / this.fadeDuration)) : 1;
                weight *= this.fadeFrom + (this.fadeTo - this.fadeFrom) * t;
                if (t >= 1) {
                    this.fading = false;
                    if (this.fadeTo == 0) this.enabled = false;
                }
            }
        }
        this.effectiveWeight = weight;
        return weight;
    }

    private updateTime(deltaTime: f64): f64 {
        const duration = this.clip.duration;
        const loop = this.loop;
        let time = this.time + deltaTime;
        let loopCount = this.loopCount;
        const pingPong = loop == LoopPingPong;
        if (deltaTime == 0) {
            if (loopCount == -1) return time;
            return pingPong && (<i64>loopCount & 1) == 1 ? duration - time : time;
        }
        if (loop == LoopOnce) {
            if (loopCount == -1) this.loopCount = 0;
            if (time >= duration || time < 0) {
                time = time >= duration ? duration : 0;
                if (this.clampWhenFinished) this.paused = true;
                else this.enabled = false;
            }
            this.time = time;
            return time;
        }
        if (loopCount == -1) {
            loopCount = deltaTime >= 0 ? 0 : this.repetitions;
            this.loopCount = loopCount;
        }
        if (duration > 0 && (time >= duration || time < 0)) {
            const loopDelta = Math.floor(time / duration);
            time -= duration * loopDelta;
            loopCount += Math.abs(loopDelta);
            const pending = this.repetitions - loopCount;
            if (pending <= 0) {
                if (this.clampWhenFinished) this.paused = true;
                else this.enabled = false;
                time = deltaTime > 0 ? duration : 0;
            }
            this.loopCount = loopCount;
        }
        this.time = time;
        if (pingPong && (<i64>loopCount & 1) == 1) return duration - time;
        return time;
    }
}

export class AnimationMixer {
    root: Object3D;
    /// Global time, seconds.
    time: f64 = 0;
    timeScale: f64 = 1;
    private actions: Array<AnimationAction> = [];
    private active: Array<AnimationAction> = [];
    private bindings: Map<string, PropertyMixer> = new Map<string, PropertyMixer>();
    private bindingList: Array<PropertyMixer> = [];

    constructor(root: Object3D) {
        this.root = root;
    }

    /// The action playing `clip` on `optionalRoot` (default: the mixer's
    /// root), made on first use.
    clipAction(clip: AnimationClip, optionalRoot: Object3D? = null): AnimationAction {
        const root = optionalRoot != null ? optionalRoot : this.root;
        const existing = this.existingAction(clip, root);
        if (existing != null) return existing;
        const action = new AnimationAction(this, clip, root);
        this.actions.push(action);
        return action;
    }

    existingAction(clip: AnimationClip, optionalRoot: Object3D? = null): AnimationAction? {
        const root = optionalRoot != null ? optionalRoot : this.root;
        for (let i = 0; i < this.actions.length; i++) {
            const a = this.actions[i];
            if (a.clip === clip && a.localRoot === root) return a;
        }
        return null;
    }

    stopAllAction(): AnimationMixer {
        const list = this.active.slice();
        for (let i = 0; i < list.length; i++) list[i].stop();
        return this;
    }

    /// Advances every running action by `deltaTime` seconds and applies the
    /// blended values.
    update(deltaTime: f64): AnimationMixer {
        deltaTime *= this.timeScale;
        this.time += deltaTime;
        const direction: f64 = deltaTime > 0 ? 1 : deltaTime < 0 ? -1 : 0;
        const active = this.active;
        for (let i = 0; i < active.length; i++) active[i].update(this.time, deltaTime, direction);
        const list = this.bindingList;
        for (let i = 0; i < list.length; i++) list[i].apply();
        return this;
    }

    /// Jumps every action to `timeInSeconds`.
    setTime(timeInSeconds: f64): AnimationMixer {
        this.time = 0;
        for (let i = 0; i < this.actions.length; i++) this.actions[i].time = 0;
        return this.update(timeInSeconds);
    }

    getRoot(): Object3D { return this.root; }

    uncacheClip(clip: AnimationClip): void {
        for (let i = this.actions.length - 1; i >= 0; i--) {
            if (this.actions[i].clip === clip) {
                this.deactivate(this.actions[i]);
                this.actions.splice(i, 1);
            }
        }
    }

    uncacheAction(clip: AnimationClip, optionalRoot: Object3D? = null): void {
        const a = this.existingAction(clip, optionalRoot);
        if (a == null) return;
        this.deactivate(a);
        const i = this.actions.indexOf(a);
        if (i >= 0) this.actions.splice(i, 1);
    }

    // Internal.

    bindingFor(root: Object3D, trackName: string): PropertyMixer? {
        const key = root.id.toString() + ":" + trackName;
        if (this.bindings.has(key)) return this.bindings.get(key);
        const binding = new PropertyBinding(root, trackName);
        if (!binding.isBound) return null;
        const pm = new PropertyMixer(binding);
        this.bindings.set(key, pm);
        this.bindingList.push(pm);
        return pm;
    }

    activate(action: AnimationAction): void {
        if (this.active.indexOf(action) < 0) this.active.push(action);
    }

    deactivate(action: AnimationAction): void {
        const i = this.active.indexOf(action);
        if (i >= 0) this.active.splice(i, 1);
    }

    isActive(action: AnimationAction): bool { return this.active.indexOf(action) >= 0; }
}
