// three.js AmbientLight: lights every surface equally.

import { Object3D } from "../core/Object3D";
import { Light } from "./Light";

export class AmbientLight extends Light {
    readonly isAmbientLight: bool = true;

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1) {
        super(color, intensity);
        this.type = "AmbientLight";
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new AmbientLight().copy(this, recursive);
    }
}
