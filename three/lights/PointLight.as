// three.js PointLight: light from a point, falling off as
// 1 / distance^decay, cut off smoothly at `distance` (0: no cut off).

import { Object3D } from "../core/Object3D";
import { Light } from "./Light";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";
import { PointLightShadow } from "./LightShadow";

export class PointLight extends Light {
    readonly isPointLight: bool = true;

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("distance", Dynamic.fromNumber(this.distance));
        object.set("decay", Dynamic.fromNumber(this.decay));
        object.set("shadow", this.shadow.toJSON());
    }
    distance: f64;
    decay: f64;
    shadow: PointLightShadow = new PointLightShadow();

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1, distance: f64 = 0, decay: f64 = 2) {
        super(color, intensity);
        this.type = "PointLight";
        this.distance = distance;
        this.decay = decay;
    }

    /// Luminous power in lumens (intensity x 4 PI).
    get power(): f64 { return this.intensity * 4 * Math.PI; }
    set power(value: f64) { this.intensity = value / (4 * Math.PI); }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof PointLight) {
            const s = source as PointLight;
            this.distance = s.distance;
            this.decay = s.decay;
            this.shadow.copy(s.shadow);
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new PointLight().copy(this, recursive);
    }
}
