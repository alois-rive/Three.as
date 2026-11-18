// three.js RectAreaLight: a width x height rectangle emitting from its
// front (-Z), lighting MeshStandardMaterial and MeshPhysicalMaterial with
// linearly transformed cosines, as three.js. Casts no shadows. (three.js
// needs RectAreaLightUniformsLib.init(); the tables are built in here.)

import { Light } from "./Light";

export class RectAreaLight extends Light {
    readonly isRectAreaLight: bool = true;
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
}
