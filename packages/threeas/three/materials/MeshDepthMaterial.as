// three.js MeshDepthMaterial: depth as grey, white near, black far
// (BasicDepthPacking only).

import { Material, MaterialParameters } from "./Material";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";
import {
    MaterialUniforms, KIND_DEPTH, SLOT_MAP, SLOT_ALPHA, ROLE_DISPLACEMENT,
} from "./MaterialUniforms";
import { Texture } from "../textures/Texture";
import { BasicDepthPacking } from "../constants";

export class MeshDepthMaterialParameters extends MaterialParameters {
    depthPacking: i32 = BasicDepthPacking;
    map: Texture? = null;
    alphaMap: Texture? = null;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;

    constructor() {
        super();
        this.fog = false;
    }
}

export class MeshDepthMaterial extends Material {
    readonly isMeshDepthMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        setNumber(data, "depthPacking", <f64>this.depthPacking);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        if (this.mapToJSON(data, "displacementMap", this.displacementMap, meta)) {
            setNumber(data, "displacementScale", this.displacementScale);
            setNumber(data, "displacementBias", this.displacementBias);
        }
    }
    depthPacking: i32 = BasicDepthPacking;
    map: Texture? = null;
    alphaMap: Texture? = null;

    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;

    constructor(parameters: MeshDepthMaterialParameters? = null) {
        super();
        this.type = "MeshDepthMaterial";
        this.fog = false;
        if (parameters != null) {
            this.setValues(parameters);
            this.displacementMap = parameters.displacementMap;
            this.displacementScale = parameters.displacementScale;
            this.displacementBias = parameters.displacementBias;
            this.depthPacking = parameters.depthPacking;
            this.map = parameters.map;
            this.alphaMap = parameters.alphaMap;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_DEPTH;
        u.fog = false;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
        u.roles[ROLE_DISPLACEMENT] = this.displacementMap;
        u.displacementScale = this.displacementScale;
        u.displacementBias = this.displacementBias;
    }

    override displacementMapOf(): Texture? { return this.displacementMap; }
    override mapOf(): Texture? { return this.map; }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof MeshDepthMaterial) {
            const s = source as MeshDepthMaterial;
            this.depthPacking = s.depthPacking;
            this.map = s.map;
            this.alphaMap = s.alphaMap;
            this.displacementMap = s.displacementMap;
            this.displacementScale = s.displacementScale;
            this.displacementBias = s.displacementBias;
        }
        return this;
    }

    override clone(): Material {
        return new MeshDepthMaterial().copy(this);
    }
}
