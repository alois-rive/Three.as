// three.js AmbientLight: lights every surface equally.

import { Light } from "./Light";

export class AmbientLight extends Light {
    readonly isAmbientLight: bool = true;

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1) {
        super(color, intensity);
        this.type = "AmbientLight";
    }
}
