// three.js AnimationClip: named tracks playing together.

import { KeyframeTrack } from "./KeyframeTrack";

export class AnimationClip {
    name: string;
    tracks: Array<KeyframeTrack>;
    /// Seconds; -1 computes it from the tracks.
    duration: f64;

    constructor(name: string = "", duration: f64 = -1, tracks: Array<KeyframeTrack> = []) {
        this.name = name;
        this.tracks = tracks;
        this.duration = duration;
        if (duration < 0) this.resetDuration();
    }

    resetDuration(): AnimationClip {
        let d: f64 = 0;
        for (let i = 0; i < this.tracks.length; i++) {
            const times = this.tracks[i].times;
            if (times.length > 0) d = Math.max(d, <f64>times[times.length - 1]);
        }
        this.duration = d;
        return this;
    }

    static findByName(clips: Array<AnimationClip>, name: string): AnimationClip? {
        for (let i = 0; i < clips.length; i++) if (clips[i].name == name) return clips[i];
        return null;
    }
}
