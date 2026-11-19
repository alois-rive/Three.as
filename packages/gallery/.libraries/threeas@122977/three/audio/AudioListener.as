// three.js AudioListener: the ears, usually a child of the camera. It owns
// the AudioContext (its own mixer on the audio thread) and the master gain
// and filter every Audio made with it goes through.
//
// three.js updates audio in updateMatrixWorld, which the renderer calls
// every frame; so does this listener (updateMatrixWorld calls update()).
// Headless captures (`--render-audio`) and scripts that do not render
// every frame call `listener.update()` themselves, from advance: it
// refreshes the world matrices it needs and publishes the mix.

import { Object3D } from "../core/Object3D";
import { Vector3 } from "../math/Vector3";
import { Quaternion } from "../math/Quaternion";
import { Audio as RiveAudio } from "rive/audio";
import { AudioContext } from "./AudioContext";
import { GainNode, BiquadFilterNode } from "./AudioNodes";
import { Audio } from "./Audio";

const _position = new Vector3();
const _quaternion = new Quaternion();
const _scale = new Vector3();

export class AudioListener extends Object3D {
    context: AudioContext = new AudioContext();
    gain: GainNode = new GainNode();
    filter: BiquadFilterNode? = null;
    /// Seconds between the last two updates.
    timeDelta: f64 = 0;
    /// The Audio objects made with this listener.
    sources: Array<Audio> = [];
    /// World position, forward (-Z) and up as of the last update.
    readonly worldPosition: Vector3 = new Vector3();
    readonly worldForward: Vector3 = new Vector3(0, 0, -1);
    readonly worldUp: Vector3 = new Vector3(0, 1, 0);
    private lastTime: f64 = -1;

    constructor() {
        super();
        this.type = "AudioListener";
    }

    getInput(): GainNode {
        return this.gain;
    }

    removeFilter(): AudioListener {
        this.filter = null;
        return this;
    }

    getFilter(): BiquadFilterNode? {
        return this.filter;
    }

    setFilter(value: BiquadFilterNode?): AudioListener {
        this.filter = value;
        return this;
    }

    getMasterVolume(): f64 {
        return this.gain.gain.value;
    }

    setMasterVolume(value: f64): AudioListener {
        this.gain.gain.setTargetAtTime(value, this.context.currentTime, 0.01);
        return this;
    }

    override updateMatrixWorld(force: bool = false): void {
        super.updateMatrixWorld(force);
        this.update(false);
    }

    /// Publishes this frame's mix: every source's gains, panning and
    /// transport, from the listener's and the sources' world matrices.
    /// `updateMatrices` refreshes those matrices first (updateMatrixWorld
    /// passes false: the render just did).
    update(updateMatrices: bool = true): void {
        const now = RiveAudio.time();
        this.timeDelta = this.lastTime >= 0 ? Math.max(0, now - this.lastTime) : 0;
        this.lastTime = now;
        if (updateMatrices) {
            this.updateWorldMatrix(true, false);
            for (let i = 0; i < this.sources.length; i++) this.sources[i].updateWorldMatrix(true, false);
        }
        this.matrixWorld.decompose(_position, _quaternion, _scale);
        this.worldPosition.copy(_position);
        this.worldForward.set(0, 0, -1).applyQuaternion(_quaternion);
        this.worldUp.copy(this.up);
        this.context.update();
    }
}
