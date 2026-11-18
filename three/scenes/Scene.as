// three.js Scene: the root of what a renderer draws.

import { Object3D } from "../core/Object3D";
import { Color } from "../math/Color";

export class Scene extends Object3D {
    readonly isScene: bool = true;
    /// The colour behind everything, or null for the renderer's clear
    /// colour. (three.js also takes a texture here; that comes in M2.)
    background: Color? = null;
    backgroundIntensity: f64 = 1;

    constructor() {
        super();
        this.type = "Scene";
    }
}
