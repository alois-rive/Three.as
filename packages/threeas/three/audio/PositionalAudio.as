// three.js PositionalAudio: an Audio placed in the scene, heard through a
// PannerNode: Web Audio's distance models ("linear", "inverse",
// "exponential"), sound cones and equal-power panning, computed every
// update from the object's and the listener's world matrices. The panner's
// "HRTF" model (three.js's choice, the default) adds an interaural delay
// and a head-shadow low-pass to equal-power panning (there is no HRTF
// convolution); "equalpower" is Web Audio's equal-power panning alone.

import { Vector3 } from "../math/Vector3";
import { Quaternion } from "../math/Quaternion";
import { Audio } from "./Audio";
import { AudioListener } from "./AudioListener";
import { AudioContext } from "./AudioContext";
import { AudioNode, PannerNode } from "./AudioNodes";
import { distanceGain as computeDistanceGain, coneGain as computeConeGain, azimuthElevation, equalPowerMatrix, interauralDelay, headShadowCutoffs } from "./AudioMath";
import { P_LL, P_LR, P_RL, P_RR, P_ITD_L, P_ITD_R, P_LPF_L, P_LPF_R, P_TAP_PRE } from "./AudioMixer";

const _position = new Vector3();
const _quaternion = new Quaternion();
const _scale = new Vector3();
const _orientation = new Vector3();
const _angles = new StaticArray<f64>(2);
const _matrix = new StaticArray<f64>(4);
const _cutoffs = new StaticArray<f64>(2);

export class PositionalAudio extends Audio {
    panner: PannerNode = new PannerNode();
    /// The gains of the last update: distance, cone, and the azimuth
    /// (degrees, + right) and elevation the source was heard at.
    distanceGain: f64 = 1;
    coneGain: f64 = 1;
    azimuth: f64 = 0;
    elevation: f64 = 0;

    constructor(listener: AudioListener) {
        super(listener);
        this.type = "PositionalAudio";
        this.panner.panningModel = "HRTF";
    }

    override getOutput(): AudioNode {
        return this.panner;
    }

    override fallbackSpatialGain(): f64 {
        return this.distanceGain * this.coneGain;
    }

    getRefDistance(): f64 { return this.panner.refDistance; }
    setRefDistance(value: f64): PositionalAudio { this.panner.refDistance = value; return this; }
    getRolloffFactor(): f64 { return this.panner.rolloffFactor; }
    setRolloffFactor(value: f64): PositionalAudio { this.panner.rolloffFactor = value; return this; }
    getDistanceModel(): string { return this.panner.distanceModel; }
    setDistanceModel(value: string): PositionalAudio { this.panner.distanceModel = value; return this; }
    getMaxDistance(): f64 { return this.panner.maxDistance; }
    setMaxDistance(value: f64): PositionalAudio { this.panner.maxDistance = value; return this; }

    setDirectionalCone(coneInnerAngle: f64, coneOuterAngle: f64, coneOuterGain: f64): PositionalAudio {
        this.panner.coneInnerAngle = coneInnerAngle;
        this.panner.coneOuterAngle = coneOuterAngle;
        this.panner.coneOuterGain = coneOuterGain;
        return this;
    }

    override writeSpatial(context: AudioContext, p: StaticArray<f64>, base: i32, channels: i32): void {
        const panner = this.panner;
        this.matrixWorld.decompose(_position, _quaternion, _scale);
        _orientation.set(0, 0, 1).applyQuaternion(_quaternion);
        panner.setPosition(_position.x, _position.y, _position.z);
        panner.setOrientation(_orientation.x, _orientation.y, _orientation.z);

        const listener = this.listener;
        const lp = listener.worldPosition, lf = listener.worldForward, lu = listener.worldUp;
        const dx = _position.x - lp.x, dy = _position.y - lp.y, dz = _position.z - lp.z;
        const distance = Math.sqrt(dx * dx + dy * dy + dz * dz);
        this.distanceGain = computeDistanceGain(panner.distanceModel, distance, panner.refDistance, panner.maxDistance, panner.rolloffFactor);
        this.coneGain = computeConeGain(_position.x, _position.y, _position.z, _orientation.x, _orientation.y, _orientation.z,
            lp.x, lp.y, lp.z, panner.coneInnerAngle, panner.coneOuterAngle, panner.coneOuterGain);
        azimuthElevation(_position.x, _position.y, _position.z, lp.x, lp.y, lp.z, lf.x, lf.y, lf.z, lu.x, lu.y, lu.z, _angles);
        this.azimuth = _angles[0];
        this.elevation = _angles[1];
        equalPowerMatrix(this.azimuth, channels, _matrix);
        const g = this.distanceGain * this.coneGain;
        p[base + P_LL] = _matrix[0] * g;
        p[base + P_LR] = _matrix[1] * g;
        p[base + P_RL] = _matrix[2] * g;
        p[base + P_RR] = _matrix[3] * g;
        // three.js's analyser listens to the panner's output (before the volume).
        p[base + P_TAP_PRE] = 1;
        if (panner.panningModel == "HRTF") {
            const itd = interauralDelay(this.azimuth);
            // The ear away from the source hears it later.
            p[base + P_ITD_L] = this.azimuth > 0 ? itd : 0;
            p[base + P_ITD_R] = this.azimuth < 0 ? itd : 0;
            headShadowCutoffs(this.azimuth, _cutoffs);
            p[base + P_LPF_L] = _cutoffs[0];
            p[base + P_LPF_R] = _cutoffs[1];
        } else {
            p[base + P_ITD_L] = 0;
            p[base + P_ITD_R] = 0;
            p[base + P_LPF_L] = 0;
            p[base + P_LPF_R] = 0;
        }
    }
}
