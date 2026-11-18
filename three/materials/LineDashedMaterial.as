// three.js LineDashedMaterial: dashes along "lineDistance" (call
// computeLineDistances() on the line first).

import { LineBasicMaterial, LineBasicMaterialParameters } from "./LineBasicMaterial";
import { MaterialUniforms, KIND_LINE_DASHED } from "./MaterialUniforms";

export class LineDashedMaterialParameters extends LineBasicMaterialParameters {
    scale: f64 = 1;
    dashSize: f64 = 3;
    gapSize: f64 = 1;
}

export class LineDashedMaterial extends LineBasicMaterial {
    readonly isLineDashedMaterial: bool = true;
    scale: f64 = 1;
    dashSize: f64 = 3;
    gapSize: f64 = 1;

    constructor(parameters: LineDashedMaterialParameters? = null) {
        super(null);
        this.type = "LineDashedMaterial";
        if (parameters != null) {
            this.setLineValues(parameters);
            this.scale = parameters.scale;
            this.dashSize = parameters.dashSize;
            this.gapSize = parameters.gapSize;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_LINE_DASHED;
        u.dashSize = this.dashSize;
        u.gapSize = this.gapSize;
        u.dashScale = this.scale;
    }
}
