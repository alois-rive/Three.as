// three.js RectAreaLight: a width x height rectangle emitting from its
// front (-Z), lighting MeshStandardMaterial and MeshPhysicalMaterial with
// linearly transformed cosines, as three.js. Casts no shadows. (three.js
// needs RectAreaLightUniformsLib.init(); the tables are built in here.)

import { Object3D } from "../core/Object3D";
import { Light } from "./Light";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";

export class RectAreaLight extends Light {
    readonly isRectAreaLight: bool = true;

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("width", Dynamic.fromNumber(this.width));
        object.set("height", Dynamic.fromNumber(this.height));
    }
    width: f64;
    height: f64;

    constructor(color: u32 = 0xFFFFFF, intensity: f64 = 1, width: f64 = 10, height: f64 = 10) {
        super(color, intensity);
        this.type = "RectAreaLight";
        this.width = width;
        this.height = height;
    }

    /// Luminous power in lumens (intensity x area x PI).
    get power(): f64 { return this.intensity * this.width * this.height * Math.PI; }
    set power(value: f64) { this.intensity = value / (this.width * this.height * Math.PI); }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof RectAreaLight) {
            const s = source as RectAreaLight;
            this.width = s.width;
            this.height = s.height;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new RectAreaLight().copy(this, recursive);
    }
}
