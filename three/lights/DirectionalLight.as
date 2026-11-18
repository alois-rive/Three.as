// three.js DirectionalLight: parallel light from `position` towards
// `target`'s position (the origin by default). Intensity is irradiance, as
// three.js's physically based lighting (no PI scaling).

import { Light } from "./Light";
import { Object3D } from "../core/Object3D";

export class DirectionalLight extends Light {
    readonly isDirectionalLight: bool = true;
    /// The light points at this object's world position. Add it to the
    /// scene to move it with a parent.
    target: Object3D = new Object3D();

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1) {
        super(color, intensity);
        this.type = "DirectionalLight";
        this.position.copy(Object3D.DEFAULT_UP);
        this.updateMatrix();
    }
}
