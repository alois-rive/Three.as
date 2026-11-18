// three.js PointLight: light from a point, falling off as
// 1 / distance^decay, cut off smoothly at `distance` (0: no cut off).

import { Light } from "./Light";
import { PointLightShadow } from "./LightShadow";

export class PointLight extends Light {
    readonly isPointLight: bool = true;
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
}
