// three.js AnimationClip: named tracks playing together.

import { Dynamic } from "rive/dynamic";
import {
    KeyframeTrack, NumberKeyframeTrack, VectorKeyframeTrack, ColorKeyframeTrack, BooleanKeyframeTrack,
    QuaternionKeyframeTrack,
} from "./KeyframeTrack";
import { NormalAnimationBlendMode } from "../constants";
import { MathUtils } from "../math/MathUtils";
import { jstr, jnum, jint, jarr, jnumbers, jhas } from "../core/JSON";

export class AnimationClip {
    name: string;
    tracks: Array<KeyframeTrack>;
    /// Seconds; -1 computes it from the tracks.
    duration: f64;
    /// NormalAnimationBlendMode or AdditiveAnimationBlendMode (kept and
    /// written to JSON; the mixer blends normally).
    blendMode: i32;
    private _uuid: string = "";

    constructor(name: string = "", duration: f64 = -1, tracks: Array<KeyframeTrack> = [],
                blendMode: i32 = NormalAnimationBlendMode) {
        this.name = name;
        this.tracks = tracks;
        this.duration = duration;
        this.blendMode = blendMode;
        if (duration < 0) this.resetDuration();
    }

    /// A random uuid, made on first use.
    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

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

    /// three.js's JSON: { name, duration, tracks, uuid, blendMode }.
    toJSON(): Dynamic {
        return AnimationClip.toJSON(this);
    }

    static toJSON(clip: AnimationClip): Dynamic {
        const json = Dynamic.newTable();
        json.set("name", Dynamic.fromString(clip.name));
        json.set("duration", Dynamic.fromNumber(clip.duration));
        const tracks = Dynamic.newTable();
        for (let i = 0; i < clip.tracks.length; i++) tracks.push(KeyframeTrack.toJSON(clip.tracks[i]));
        json.set("tracks", tracks);
        json.set("uuid", Dynamic.fromString(clip.uuid));
        json.set("blendMode", Dynamic.fromNumber(<f64>clip.blendMode));
        return json;
    }

    /// A clip from three.js's JSON (times scaled by 1 / `fps` when given).
    /// Tracks of a type not ported (string) are skipped.
    static parse(json: Dynamic?): AnimationClip {
        const tracks: Array<KeyframeTrack> = [];
        const frameTime = 1.0 / jnum(json, "fps", 1.0);
        const jsonTracks = jarr(json, "tracks");
        for (let i = 0; i < jsonTracks.length; i++) {
            const track = parseKeyframeTrack(jsonTracks[i]);
            if (track != null) tracks.push(track.scale(frameTime));
        }
        const clip = new AnimationClip(jstr(json, "name", ""), jnum(json, "duration", -1), tracks,
            jint(json, "blendMode", NormalAnimationBlendMode));
        if (jhas(json, "uuid")) clip.uuid = jstr(json, "uuid", "");
        return clip;
    }
}

/// A track from three.js's JSON, by its `type`; null for string tracks or
/// a track without `times`.
export function parseKeyframeTrack(json: Dynamic?): KeyframeTrack? {
    const type = jstr(json, "type", "").toLowerCase();
    const name = jstr(json, "name", "");
    const times = jnumbers(json, "times");
    const values = jnumbers(json, "values");
    if (times == null || values == null) return null;
    const interpolation = jint(json, "interpolation", -1);
    let track: KeyframeTrack;
    if (type == "scalar" || type == "double" || type == "float" || type == "number" || type == "integer") {
        track = new NumberKeyframeTrack(name, times!, values!);
    } else if (type == "vector" || type == "vector2" || type == "vector3" || type == "vector4") {
        track = new VectorKeyframeTrack(name, times!, values!);
    } else if (type == "color") {
        track = new ColorKeyframeTrack(name, times!, values!);
    } else if (type == "quaternion") {
        track = new QuaternionKeyframeTrack(name, times!, values!);
    } else if (type == "bool" || type == "boolean") {
        track = new BooleanKeyframeTrack(name, times!, values!);
    } else {
        return null;
    }
    if (interpolation >= 0) track.setInterpolation(interpolation);
    return track;
}
