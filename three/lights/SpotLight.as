// three.js SpotLight: a point light limited to a cone from `position`
// towards `target`. `angle` is the cone's half angle (at most PI / 2);
// `penumbra` (0 to 1) softens its edge.

import { Light } from "./Light";
import { Object3D } from "../core/Object3D";
import { SpotLightShadow } from "./LightShadow";

export class SpotLight extends Light {
    readonly isSpotLight: bool = true;
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
}
