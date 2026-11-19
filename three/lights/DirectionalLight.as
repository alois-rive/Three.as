// three.js DirectionalLight: parallel light from `position` towards
// `target`'s position (the origin by default). Intensity is irradiance, as
// three.js's physically based lighting (no PI scaling).

import { Light } from "./Light";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";
import { Object3D } from "../core/Object3D";
import { DirectionalLightShadow } from "./LightShadow";

export class DirectionalLight extends Light {
    readonly isDirectionalLight: bool = true;

    /// The target is written as its uuid, as three.js (ObjectLoader binds
    /// it when the target is in the scene, else makes a new one).
    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("shadow", this.shadow.toJSON());
        object.set("target", Dynamic.fromString(this.target.uuid));
    }
    /// The light points at this object's world position. Add it to the
    /// scene to move it with a parent.
    target: Object3D = new Object3D();
    shadow: DirectionalLightShadow = new DirectionalLightShadow();
    /// Rive-only, set by the CSM addon: the view depth range this light
    /// lights (a cascade), far 0 for everywhere.
    cascadeNear: f64 = 0;
    cascadeFar: f64 = 0;

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1) {
        super(color, intensity);
        this.type = "DirectionalLight";
        this.position.copy(Object3D.DEFAULT_UP);
        this.updateMatrix();
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof DirectionalLight) {
            const s = source as DirectionalLight;
            this.target = s.target.clone(true);
            this.shadow.copy(s.shadow);
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new DirectionalLight().copy(this, recursive);
    }
}
