// three.js Fog (linear) and FogExp2. Both extend FogBase, which stands in
// for three.js's `Fog | FogExp2` type of `scene.fog`. Fog depth is the
// view-space depth, as three.js.

import { Color } from "../math/Color";
import { Dynamic } from "rive/dynamic";

export abstract class FogBase {
    name: string = "";
    color: Color;

    constructor(color: u32) {
        this.color = Color.fromHex(color);
    }

    /// three.js's JSON: { type, name, color, near, far } or { type, name,
    /// color, density }.
    abstract toJSON(): Dynamic;
}

export class Fog extends FogBase {
    readonly isFog: bool = true;
    near: f64;
    far: f64;

    constructor(color: u32, near: f64 = 1, far: f64 = 1000) {
        super(color);
        this.near = near;
        this.far = far;
    }

    override toJSON(): Dynamic {
        const data = Dynamic.newTable();
        data.set("type", Dynamic.fromString("Fog"));
        data.set("name", Dynamic.fromString(this.name));
        data.set("color", Dynamic.fromNumber(<f64>this.color.getHex()));
        data.set("near", Dynamic.fromNumber(this.near));
        data.set("far", Dynamic.fromNumber(this.far));
        return data;
    }

    clone(): Fog {
        const f = new Fog(0, this.near, this.far);
        f.color.copy(this.color);
        return f;
    }
}

export class FogExp2 extends FogBase {
    readonly isFogExp2: bool = true;
    density: f64;

    constructor(color: u32, density: f64 = 0.00025) {
        super(color);
        this.density = density;
    }

    override toJSON(): Dynamic {
        const data = Dynamic.newTable();
        data.set("type", Dynamic.fromString("FogExp2"));
        data.set("name", Dynamic.fromString(this.name));
        data.set("color", Dynamic.fromNumber(<f64>this.color.getHex()));
        data.set("density", Dynamic.fromNumber(this.density));
        return data;
    }

    clone(): FogExp2 {
        const f = new FogExp2(0, this.density);
        f.color.copy(this.color);
        return f;
    }
}
