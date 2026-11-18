// three.js HemisphereLight: sky colour from above, ground colour from
// below, blended by the surface normal. "Above" is its position's direction
// (straight up by default).

import { Light } from "./Light";
import { Object3D } from "../core/Object3D";
import { Color } from "../math/Color";

export class HemisphereLight extends Light {
    readonly isHemisphereLight: bool = true;
    groundColor: Color;

    constructor(skyColor: u32 = 0xFFFFFF, groundColor: u32 = 0xFFFFFF, intensity: f64 = 1) {
        super(skyColor, intensity);
        this.type = "HemisphereLight";
        this.groundColor = Color.fromHex(groundColor);
        this.position.copy(Object3D.DEFAULT_UP);
        this.updateMatrix();
    }
}
