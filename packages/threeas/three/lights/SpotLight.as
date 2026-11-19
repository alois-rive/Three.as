// three.js SpotLight: a point light limited to a cone from `position`
// towards `target`. `angle` is the cone's half angle (at most PI / 2);
// `penumbra` (0 to 1) softens its edge.

import { Light } from "./Light";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";
import { Object3D } from "../core/Object3D";
import { SpotLightShadow } from "./LightShadow";

export class SpotLight extends Light {
    readonly isSpotLight: bool = true;

    /// The target is written as its uuid, as three.js (ObjectLoader binds
    /// it when the target is in the scene, else makes a new one).
    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("distance", Dynamic.fromNumber(this.distance));
        object.set("angle", Dynamic.fromNumber(this.angle));
        object.set("decay", Dynamic.fromNumber(this.decay));
        object.set("penumbra", Dynamic.fromNumber(this.penumbra));
        object.set("shadow", this.shadow.toJSON());
        object.set("target", Dynamic.fromString(this.target.uuid));
    }
    target: Object3D = new Object3D();
    distance: f64;
    angle: f64;
    penumbra: f64;
    decay: f64;
    shadow: SpotLightShadow = new SpotLightShadow();

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1, distance: f64 = 0, angle: f64 = Math.PI / 3,
                penumbra: f64 = 0, decay: f64 = 2) {
        super(color, intensity);
        this.type = "SpotLight";
        this.position.copy(Object3D.DEFAULT_UP);
        this.updateMatrix();
        this.distance = distance;
        this.angle = angle;
        this.penumbra = penumbra;
        this.decay = decay;
    }

    /// Luminous power in lumens (intensity x PI).
    get power(): f64 { return this.intensity * Math.PI; }
    set power(value: f64) { this.intensity = value / Math.PI; }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof SpotLight) {
            const s = source as SpotLight;
            this.distance = s.distance;
            this.angle = s.angle;
            this.penumbra = s.penumbra;
            this.decay = s.decay;
            this.target = s.target.clone(true);
            this.shadow.copy(s.shadow);
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new SpotLight().copy(this, recursive);
    }
}
