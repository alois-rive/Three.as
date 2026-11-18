// three.js Light: a colour and an intensity. Lights face their -Z.

import { Object3D } from "../core/Object3D";
import { Color } from "../math/Color";

export class Light extends Object3D {
    readonly isLight: bool = true;
    color: Color;
    intensity: f64;

    /// `color` is an sRGB hex (or a Rive Color).
    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1) {
        super();
        this.type = "Light";
        this.color = Color.fromHex(color);
        this.intensity = intensity;
    }

    override facesNegativeZ(): bool { return true; }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof Light) {
            const s = source as Light;
            this.color.copy(s.color);
            this.intensity = s.intensity;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Light().copy(this, recursive);
    }
}
