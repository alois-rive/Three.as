// three.js LineBasicMaterial: an unlit line colour. `linewidth` is kept
// for compatibility and ignored (one pixel), as on most three.js platforms.

import { Material, MaterialParameters } from "./Material";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";
import { MaterialUniforms, KIND_BASIC, SLOT_MAP, SLOT_ALPHA } from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class LineBasicMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    linewidth: f64 = 1;
    linecap: string = "round";
    linejoin: string = "round";
    map: Texture? = null;
    alphaMap: Texture? = null;
}

export class LineBasicMaterial extends Material {
    readonly isLineBasicMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        this.colorToJSON(data, "color", this.color);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        if (this.linewidth != 1) setNumber(data, "linewidth", this.linewidth);
    }
    color: Color = new Color();
    linewidth: f64 = 1;
    linecap: string = "round";
    linejoin: string = "round";
    map: Texture? = null;
    alphaMap: Texture? = null;

    constructor(parameters: LineBasicMaterialParameters? = null) {
        super();
        this.type = "LineBasicMaterial";
        if (parameters != null) this.setLineValues(parameters);
    }

    protected setLineValues(p: LineBasicMaterialParameters): void {
        this.setValues(p);
        this.color.setHex(p.color);
        this.linewidth = p.linewidth;
        this.linecap = p.linecap;
        this.linejoin = p.linejoin;
        this.map = p.map;
        this.alphaMap = p.alphaMap;
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_BASIC;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
    }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof LineBasicMaterial) {
            const s = source as LineBasicMaterial;
            this.color.copy(s.color);
            this.linewidth = s.linewidth;
            this.linecap = s.linecap;
            this.linejoin = s.linejoin;
            this.map = s.map;
            this.alphaMap = s.alphaMap;
        }
        return this;
    }

    override clone(): Material {
        return new LineBasicMaterial().copy(this);
    }
}
