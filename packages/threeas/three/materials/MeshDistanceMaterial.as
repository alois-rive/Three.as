// three.js MeshDistanceMaterial: the distance from `referencePosition`,
// mapped from [nearDistance, farDistance] to [0, 1], as grey (three.js
// packs it in RGBA for point light shadows; the renderer's own shadows do
// not need it).

import { Material, MaterialParameters } from "./Material";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";
import { MaterialUniforms, KIND_DISTANCE, SLOT_MAP, SLOT_ALPHA, ROLE_DISPLACEMENT } from "./MaterialUniforms";
import { Vector3 } from "../math/Vector3";
import { Texture } from "../textures/Texture";

export class MeshDistanceMaterialParameters extends MaterialParameters {
    map: Texture? = null;
    alphaMap: Texture? = null;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    referencePosition: Vector3 = new Vector3();
    nearDistance: f64 = 1;
    farDistance: f64 = 1000;

    constructor() {
        super();
        this.fog = false;
    }
}

export class MeshDistanceMaterial extends Material {
    readonly isMeshDistanceMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        if (this.mapToJSON(data, "displacementMap", this.displacementMap, meta)) {
            setNumber(data, "displacementScale", this.displacementScale);
            setNumber(data, "displacementBias", this.displacementBias);
        }
    }
    map: Texture? = null;
    alphaMap: Texture? = null;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    referencePosition: Vector3 = new Vector3();
    nearDistance: f64 = 1;
    farDistance: f64 = 1000;

    constructor(parameters: MeshDistanceMaterialParameters? = null) {
        super();
        this.type = "MeshDistanceMaterial";
        this.fog = false;
        if (parameters != null) {
            this.setValues(parameters);
            this.map = parameters.map;
            this.alphaMap = parameters.alphaMap;
            this.displacementMap = parameters.displacementMap;
            this.displacementScale = parameters.displacementScale;
            this.displacementBias = parameters.displacementBias;
            this.referencePosition.copy(parameters.referencePosition);
            this.nearDistance = parameters.nearDistance;
            this.farDistance = parameters.farDistance;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_DISTANCE;
        u.fog = false;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
        u.roles[ROLE_DISPLACEMENT] = this.displacementMap;
        u.displacementScale = this.displacementScale;
        u.displacementBias = this.displacementBias;
        u.referenceX = this.referencePosition.x;
        u.referenceY = this.referencePosition.y;
        u.referenceZ = this.referencePosition.z;
        u.nearDistance = this.nearDistance;
        u.farDistance = this.farDistance;
    }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof MeshDistanceMaterial) {
            const s = source as MeshDistanceMaterial;
            this.map = s.map;
            this.alphaMap = s.alphaMap;
            this.displacementMap = s.displacementMap;
            this.displacementScale = s.displacementScale;
            this.displacementBias = s.displacementBias;
            this.referencePosition.copy(s.referencePosition);
            this.nearDistance = s.nearDistance;
            this.farDistance = s.farDistance;
        }
        return this;
    }

    override clone(): Material {
        return new MeshDistanceMaterial().copy(this);
    }
}
