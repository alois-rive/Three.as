// three.js PointsMaterial: square points of `size` pixels (scaled by
// distance with sizeAttenuation on a perspective camera), times `map`.

import { Material, MaterialParameters } from "./Material";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, setBool } from "../core/JSON";
import { MaterialUniforms, KIND_BASIC, SLOT_MAP, SLOT_ALPHA } from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class PointsMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    size: f64 = 1;
    sizeAttenuation: bool = true;
    map: Texture? = null;
    alphaMap: Texture? = null;
}

export class PointsMaterial extends Material {
    readonly isPointsMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        this.colorToJSON(data, "color", this.color);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        setNumber(data, "size", this.size);
        setBool(data, "sizeAttenuation", this.sizeAttenuation);
    }
    color: Color = new Color();
    size: f64 = 1;
    sizeAttenuation: bool = true;
    map: Texture? = null;
    alphaMap: Texture? = null;

    constructor(parameters: PointsMaterialParameters? = null) {
        super();
        this.type = "PointsMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.size = parameters.size;
            this.sizeAttenuation = parameters.sizeAttenuation;
            this.map = parameters.map;
            this.alphaMap = parameters.alphaMap;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_BASIC;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.size = this.size;
        u.sizeAttenuation = this.sizeAttenuation;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
    }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof PointsMaterial) {
            const s = source as PointsMaterial;
            this.color.copy(s.color);
            this.size = s.size;
            this.sizeAttenuation = s.sizeAttenuation;
            this.map = s.map;
            this.alphaMap = s.alphaMap;
        }
        return this;
    }

    override clone(): Material {
        return new PointsMaterial().copy(this);
    }
}
