// three.js examples/jsm/geometries/TextGeometry.js: extruded text. Its
// parameters are ExtrudeGeometry's plus `font` (a FontLoader Font or a
// RiveFont) and `size`, with three.js's defaults (depth 50, bevel off,
// bevelThickness 10, bevelSize 8).

import { ExtrudeGeometry, ExtrudeGeometryOptions } from "../../geometries/ExtrudeGeometry";
import { Font } from "../loaders/FontLoader";

export class TextGeometryParameters extends ExtrudeGeometryOptions {
    font: Font? = null;
    size: f64 = 100;

    constructor() {
        super();
        this.depth = 50;
        this.bevelEnabled = false;
        this.bevelThickness = 10;
        this.bevelSize = 8;
    }
}

export class TextGeometry extends ExtrudeGeometry {
    constructor(text: string, parameters: TextGeometryParameters? = null) {
        const p = parameters != null ? parameters! : new TextGeometryParameters();
        const font = p.font;
        super(font != null ? font.generateShapes(text, p.size) : [], p);
        this.type = "TextGeometry";
    }
}
