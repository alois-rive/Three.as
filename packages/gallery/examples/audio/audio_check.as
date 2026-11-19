// AudioCheck: one sound in an empty scene, set up from --arg values, for
// tools/check_audio.py to render with rive --render-audio and measure. The
// listener stands at the origin facing -Z.
//
//   source=sine|square|hum|chime|radio|knock|wind   (sine: an OscillatorNode)
//   freq=1000                 oscillator frequency
//   positional=1              a PositionalAudio (else a plain Audio)
//   panning=equalpower|HRTF
//   model=inverse|linear|exponential, ref=1, max=10000, rolloff=1
//   cone=inner,outer,outerGain
//   path=x,y,z;x,y,z;...      positions, one every `hold` seconds
//   angles=0,30,...           the source's turn about Y (degrees), one every `hold`
//   hold=0.5
//   loop=1, volume=1, rate=1, detune=0
//   stopAt=1.0, pauseAt=, resumeAt=
//   analyser=2048             log the analyser's peak bin every half second

import * as THREE from "lib:threeas/three/Three";
import { Context } from "rive/host";

function num(context: Context, name: string, fallback: f64): f64 {
    const v = context.arg(name);
    return v != null ? parseFloat(v!) : fallback;
}

function str(context: Context, name: string, fallback: string): string {
    const v = context.arg(name);
    return v != null ? v! : fallback;
}

export class AudioCheck extends THREE.ThreeLayout {
    listener: THREE.AudioListener = new THREE.AudioListener();
    audio: THREE.Audio? = null;
    holder: THREE.Object3D = new THREE.Object3D();
    path: Array<f64> = [];
    angles: Array<f64> = [];
    hold: f64 = 0.5;
    time: f64 = 0;
    stopAt: f64 = -1;
    pauseAt: f64 = -1;
    resumeAt: f64 = -1;
    analyser: THREE.AudioAnalyser? = null;
    nextLog: f64 = 0.5;
    oscillator: THREE.OscillatorNode? = null;

    override setup(context: Context): bool {
        this.camera.add(this.listener);
        this.scene.add(this.camera);
        this.scene.add(this.holder);
        const source = str(context, "source", "sine");
        const positional = num(context, "positional", 0) > 0;
        let audio: THREE.Audio;
        if (positional) {
            const p = new THREE.PositionalAudio(this.listener);
            p.panner.panningModel = str(context, "panning", "equalpower");
            p.setDistanceModel(str(context, "model", "inverse"));
            p.setRefDistance(num(context, "ref", 1));
            p.setMaxDistance(num(context, "max", 10000));
            p.setRolloffFactor(num(context, "rolloff", 1));
            const cone = context.arg("cone");
            if (cone != null) {
                const c = cone!.split(",");
                p.setDirectionalCone(parseFloat(c[0]), parseFloat(c[1]), parseFloat(c[2]));
            }
            audio = p;
        } else {
            audio = new THREE.Audio(this.listener);
        }
        this.holder.add(audio);
        if (source == "sine" || source == "square" || source == "sawtooth" || source == "triangle") {
            const osc = this.listener.context.createOscillator();
            osc.type = source;
            osc.frequency.value = num(context, "freq", 1000);
            audio.setNodeSource(osc);
            this.oscillator = osc;
        } else {
            audio.setBuffer(new THREE.AudioLoader(context).load(source));
            audio.setLoop(num(context, "loop", 0) > 0);
            audio.setPlaybackRate(num(context, "rate", 1));
            audio.setDetune(num(context, "detune", 0));
        }
        audio.setVolume(num(context, "volume", 1));
        const path = context.arg("path");
        if (path != null) {
            const points = path!.split(";");
            for (let i = 0; i < points.length; i++) {
                const c = points[i].split(",");
                this.path.push(parseFloat(c[0]));
                this.path.push(parseFloat(c[1]));
                this.path.push(parseFloat(c[2]));
            }
        }
        const angles = context.arg("angles");
        if (angles != null) {
            const a = angles!.split(",");
            for (let i = 0; i < a.length; i++) this.angles.push(parseFloat(a[i]));
        }
        this.hold = num(context, "hold", 0.5);
        this.stopAt = num(context, "stopAt", -1);
        this.pauseAt = num(context, "pauseAt", -1);
        this.resumeAt = num(context, "resumeAt", -1);
        const fftSize = <i32>num(context, "analyser", 0);
        if (fftSize > 0) this.analyser = new THREE.AudioAnalyser(audio, fftSize);
        this.audio = audio;
        this.pose();
        const osc = this.oscillator;
        if (osc != null) osc.start();
        else audio.play();
        return true;
    }

    pose(): void {
        const step = <i32>Math.floor(this.time / this.hold);
        const n = this.path.length / 3;
        if (n > 0) {
            const k = min<i32>(step, n - 1) * 3;
            this.holder.position.set(this.path[k], this.path[k + 1], this.path[k + 2]);
        }
        if (this.angles.length > 0) {
            this.holder.rotation.y = this.angles[min<i32>(step, this.angles.length - 1)] * Math.PI / 180;
        }
    }

    override animate(seconds: f64): void {
        const before = this.time;
        this.time += seconds;
        const t = this.time;
        this.pose();
        const audio = this.audio!;
        if (this.stopAt >= 0 && before < this.stopAt && t >= this.stopAt) {
            const osc = this.oscillator;
            if (osc != null) osc.stop();
            else audio.stop();
            console.log("check: stop at " + t.toString());
        }
        if (this.pauseAt >= 0 && before < this.pauseAt && t >= this.pauseAt) {
            audio.pause();
            console.log("check: pause at " + t.toString());
        }
        if (this.resumeAt >= 0 && before < this.resumeAt && t >= this.resumeAt) {
            audio.play();
            console.log("check: resume at " + t.toString());
        }
        this.listener.update();
        const analyser = this.analyser;
        if (analyser != null && t >= this.nextLog) {
            this.nextLog += 0.5;
            const data = analyser.getFrequencyData();
            let peak = 0;
            for (let i = 1; i < data.length; i++) if (data[i] > data[peak]) peak = i;
            const binHz = this.listener.context.sampleRate / <f64>analyser.analyser.fftSize;
            console.log("check: analyser peak bin " + peak.toString() + " (" + (<f64>peak * binHz).toString() + " Hz) level " +
                data[peak].toString() + " average " + analyser.getAverageFrequency().toString());
        }
    }
}
