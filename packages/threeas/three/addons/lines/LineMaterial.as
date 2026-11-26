// three.js examples/jsm/lines/LineMaterial.js: wide lines, `linewidth`
// pixels across, with round caps and optional dashes. Unlit (as three.js);
// vertexColors uses the geometry's setColors. `resolution` is kept for
// three.js code and not needed (the renderer knows its viewport);
// `worldUnits` is not supported.

import { Material, MaterialParameters } from "../../materials/Material";
import { MaterialUniforms, KIND_WIDE_LINE } from "../../materials/MaterialUniforms";
import { Color } from "../../math/Color";
import { Vector2 } from "../../math/Vector2";

export class LineMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    linewidth: f64 = 1;
    dashed: bool = false;
    dashScale: f64 = 1;
    dashSize: f64 = 1;
    gapSize: f64 = 1;
    dashOffset: f64 = 0;
    worldUnits: bool = false;
}

export class LineMaterial extends Material {
    readonly isLineMaterial: bool = true;
    color: Color = new Color();
    linewidth: f64 = 1;
    dashed: bool = false;
    dashScale: f64 = 1;
    dashSize: f64 = 1;
    gapSize: f64 = 1;
    dashOffset: f64 = 0;
    worldUnits: bool = false;
    resolution: Vector2 = new Vector2(1, 1);

    constructor(parameters: LineMaterialParameters? = null) {
        super();
        this.type = "LineMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.linewidth = parameters.linewidth;
            this.dashed = parameters.dashed;
            this.dashScale = parameters.dashScale;
            this.dashSize = parameters.dashSize;
            this.gapSize = parameters.gapSize;
            this.dashOffset = parameters.dashOffset;
            this.worldUnits = parameters.worldUnits;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_WIDE_LINE;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.size = this.linewidth;
        u.dashed = this.dashed;
        u.dashScale = this.dashScale;
        u.dashSize = this.dashSize;
        u.gapSize = this.gapSize;
        u.dashOffset = this.dashOffset;
    }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof LineMaterial) {
            const s = source as LineMaterial;
            this.color.copy(s.color);
            this.linewidth = s.linewidth;
            this.dashed = s.dashed;
            this.dashScale = s.dashScale;
            this.dashSize = s.dashSize;
            this.gapSize = s.gapSize;
            this.dashOffset = s.dashOffset;
            this.worldUnits = s.worldUnits;
            this.resolution.copy(s.resolution);
        }
        return this;
    }

    override clone(): Material {
        return new LineMaterial().copy(this);
    }
}
