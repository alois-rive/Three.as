// three.js AudioAnalyser: frequency data of what an Audio plays. The audio
// thread sends the Audio's latest samples every block; the FFT runs here
// on getFrequencyData (AnalyserNode, as Web Audio's).

import { Audio } from "./Audio";
import { AnalyserNode } from "./AudioNodes";

export class AudioAnalyser {
    analyser: AnalyserNode;
    data: Uint8Array;
    audio: Audio;

    constructor(audio: Audio, fftSize: i32 = 2048) {
        this.audio = audio;
        this.analyser = audio.context.createAnalyser();
        this.analyser.fftSize = fftSize;
        this.data = new Uint8Array(this.analyser.frequencyBinCount);
        audio.analyser = this.analyser;
        audio.context.analyserSlot(this.analyser);
    }

    getFrequencyData(): Uint8Array {
        this.analyser.getByteFrequencyData(this.data);
        return this.data;
    }

    /// Rive-only: gives the analyser's mixer slot back (at most four per
    /// listener; slots no playing Audio listens through are also reclaimed
    /// when all are taken) and detaches it from the Audio.
    dispose(): void {
        this.audio.context.releaseAnalyser(this.analyser);
        if (this.audio.analyser === this.analyser) this.audio.analyser = null;
    }

    getAverageFrequency(): f64 {
        let value: f64 = 0;
        const data = this.getFrequencyData();
        for (let i = 0; i < data.length; i++) value += <f64>data[i];
        return data.length > 0 ? value / <f64>data.length : 0;
    }
}
