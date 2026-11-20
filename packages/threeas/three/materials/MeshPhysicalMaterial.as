// three.js MeshPhysicalMaterial (subset): MeshStandardMaterial plus
// clearcoat, sheen, ior and specular intensity/colour. Transmission,
// iridescence, anisotropy and the extra maps are not ported yet.

import { Texture } from "../textures/Texture";
import { Vector2 } from "../math/Vector2";
import { Material } from "./Material";
import { MeshStandardMaterial, MeshStandardMaterialParameters } from "./MeshStandardMaterial";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, setNumbers } from "../core/JSON";
import {
    MaterialUniforms, KIND_PHYSICAL, ROLE_CLEARCOAT, ROLE_CLEARCOAT_NORMAL, ROLE_CLEARCOAT_ROUGHNESS, ROLE_SHEEN_COLOR, ROLE_SHEEN_ROUGHNESS, ROLE_SPECULAR_COLOR, ROLE_SPECULAR_INTENSITY, ROLE_TRANSMISSION, ROLE_THICKNESS, ROLE_IRIDESCENCE, ROLE_IRIDESCENCE_THICKNESS, ROLE_ANISOTROPY,
} from "./MaterialUniforms";
import { Color } from "../math/Color";

export class MeshPhysicalMaterialParameters extends MeshStandardMaterialParameters {
    clearcoat: f64 = 0;
    clearcoatRoughness: f64 = 0;
    sheen: f64 = 0;
    sheenColor: u32 = 0x000000;
    sheenRoughness: f64 = 1;
    ior: f64 = 1.5;
    specularIntensity: f64 = 1;
    specularColor: u32 = 0xFFFFFF;
    clearcoatMap: Texture? = null;
    clearcoatRoughnessMap: Texture? = null;
    clearcoatNormalMap: Texture? = null;
    clearcoatNormalScale: Vector2 = new Vector2(1, 1);
    sheenColorMap: Texture? = null;
    sheenRoughnessMap: Texture? = null;
    specularIntensityMap: Texture? = null;
    specularColorMap: Texture? = null;
    transmission: f64 = 0;
    transmissionMap: Texture? = null;
    thickness: f64 = 0;
    thicknessMap: Texture? = null;
    attenuationDistance: f64 = Infinity;
    attenuationColor: u32 = 0xFFFFFF;
    dispersion: f64 = 0;
    iridescence: f64 = 0;
    iridescenceMap: Texture? = null;
    iridescenceIOR: f64 = 1.3;
    iridescenceThicknessRange: Array<f64> = [100, 400];
    iridescenceThicknessMap: Texture? = null;
    anisotropy: f64 = 0;
    anisotropyRotation: f64 = 0;
    anisotropyMap: Texture? = null;
}

export class MeshPhysicalMaterial extends MeshStandardMaterial {
    readonly isMeshPhysicalMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        setNumber(data, "sheen", this.sheen);
        this.colorToJSON(data, "sheenColor", this.sheenColor);
        setNumber(data, "sheenRoughness", this.sheenRoughness);
        this.mapToJSON(data, "sheenColorMap", this.sheenColorMap, meta);
        this.mapToJSON(data, "sheenRoughnessMap", this.sheenRoughnessMap, meta);
        setNumber(data, "specularIntensity", this.specularIntensity);
        this.colorToJSON(data, "specularColor", this.specularColor);
        this.mapToJSON(data, "specularIntensityMap", this.specularIntensityMap, meta);
        this.mapToJSON(data, "specularColorMap", this.specularColorMap, meta);
        setNumber(data, "ior", this.ior);
        setNumber(data, "clearcoat", this.clearcoat);
        setNumber(data, "clearcoatRoughness", this.clearcoatRoughness);
        this.mapToJSON(data, "clearcoatMap", this.clearcoatMap, meta);
        this.mapToJSON(data, "clearcoatRoughnessMap", this.clearcoatRoughnessMap, meta);
        if (this.mapToJSON(data, "clearcoatNormalMap", this.clearcoatNormalMap, meta)) {
            setNumbers(data, "clearcoatNormalScale", [this.clearcoatNormalScale.x, this.clearcoatNormalScale.y]);
        }
        setNumber(data, "dispersion", this.dispersion);
        setNumber(data, "iridescence", this.iridescence);
        setNumber(data, "iridescenceIOR", this.iridescenceIOR);
        setNumbers(data, "iridescenceThicknessRange", this.iridescenceThicknessRange);
        this.mapToJSON(data, "iridescenceMap", this.iridescenceMap, meta);
        this.mapToJSON(data, "iridescenceThicknessMap", this.iridescenceThicknessMap, meta);
        setNumber(data, "anisotropy", this.anisotropy);
        setNumber(data, "anisotropyRotation", this.anisotropyRotation);
        this.mapToJSON(data, "anisotropyMap", this.anisotropyMap, meta);
        setNumber(data, "transmission", this.transmission);
        this.mapToJSON(data, "transmissionMap", this.transmissionMap, meta);
        setNumber(data, "thickness", this.thickness);
        this.mapToJSON(data, "thicknessMap", this.thicknessMap, meta);
        if (this.attenuationDistance != Infinity) setNumber(data, "attenuationDistance", this.attenuationDistance);
        this.colorToJSON(data, "attenuationColor", this.attenuationColor);
    }
    clearcoat: f64 = 0;
    clearcoatRoughness: f64 = 0;
    sheen: f64 = 0;
    sheenColor: Color = new Color(0, 0, 0);
    sheenRoughness: f64 = 1;
    ior: f64 = 1.5;
    specularIntensity: f64 = 1;
    specularColor: Color = new Color(1, 1, 1);

    clearcoatMap: Texture? = null;
    clearcoatRoughnessMap: Texture? = null;
    clearcoatNormalMap: Texture? = null;
    clearcoatNormalScale: Vector2 = new Vector2(1, 1);
    sheenColorMap: Texture? = null;
    sheenRoughnessMap: Texture? = null;
    specularIntensityMap: Texture? = null;
    specularColorMap: Texture? = null;

    transmission: f64 = 0;
    transmissionMap: Texture? = null;
    thickness: f64 = 0;
    thicknessMap: Texture? = null;
    attenuationDistance: f64 = Infinity;
    attenuationColor: Color = new Color(1, 1, 1);
    dispersion: f64 = 0;
    iridescence: f64 = 0;
    iridescenceMap: Texture? = null;
    iridescenceIOR: f64 = 1.3;
    iridescenceThicknessRange: Array<f64> = [100, 400];
    iridescenceThicknessMap: Texture? = null;
    anisotropy: f64 = 0;
    anisotropyRotation: f64 = 0;
    anisotropyMap: Texture? = null;

    constructor(parameters: MeshPhysicalMaterialParameters? = null) {
        super(null);
        this.type = "MeshPhysicalMaterial";
        if (parameters != null) {
            this.setStandardValues(parameters);
            this.transmission = parameters.transmission;
            this.transmissionMap = parameters.transmissionMap;
            this.thickness = parameters.thickness;
            this.thicknessMap = parameters.thicknessMap;
            this.attenuationDistance = parameters.attenuationDistance;
            this.attenuationColor.setHex(parameters.attenuationColor);
            this.dispersion = parameters.dispersion;
            this.iridescence = parameters.iridescence;
            this.iridescenceMap = parameters.iridescenceMap;
            this.iridescenceIOR = parameters.iridescenceIOR;
            this.iridescenceThicknessRange = parameters.iridescenceThicknessRange.slice();
            this.iridescenceThicknessMap = parameters.iridescenceThicknessMap;
            this.anisotropy = parameters.anisotropy;
            this.anisotropyRotation = parameters.anisotropyRotation;
            this.anisotropyMap = parameters.anisotropyMap;
            this.clearcoatMap = parameters.clearcoatMap;
            this.clearcoatRoughnessMap = parameters.clearcoatRoughnessMap;
            this.clearcoatNormalMap = parameters.clearcoatNormalMap;
            this.clearcoatNormalScale.copy(parameters.clearcoatNormalScale);
            this.sheenColorMap = parameters.sheenColorMap;
            this.sheenRoughnessMap = parameters.sheenRoughnessMap;
            this.specularIntensityMap = parameters.specularIntensityMap;
            this.specularColorMap = parameters.specularColorMap;
            this.clearcoat = parameters.clearcoat;
            this.clearcoatRoughness = parameters.clearcoatRoughness;
            this.sheen = parameters.sheen;
            this.sheenColor.setHex(parameters.sheenColor);
            this.sheenRoughness = parameters.sheenRoughness;
            this.ior = parameters.ior;
            this.specularIntensity = parameters.specularIntensity;
            this.specularColor.setHex(parameters.specularColor);
        }
    }

    /// The F0 reflectivity in [0, 1], tied to ior as three.js.
    get reflectivity(): f64 {
        const x = (this.ior - 1) / (this.ior + 1);
        return Math.max(0, Math.min(1, 2.5 * x));
    }

    set reflectivity(value: f64) {
        const r = Math.max(0, Math.min(1, value));
        this.ior = (1 + 0.4 * r) / (1 - 0.4 * r);
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_PHYSICAL;
        u.clearcoat = this.clearcoat;
        u.clearcoatRoughness = this.clearcoatRoughness;
        u.sheen = this.sheen;
        u.sheenR = this.sheenColor.r; u.sheenG = this.sheenColor.g; u.sheenB = this.sheenColor.b;
        u.sheenRoughness = this.sheenRoughness;
        u.ior = this.ior;
        u.specularIntensity = this.specularIntensity;
        u.specularColorR = this.specularColor.r; u.specularColorG = this.specularColor.g;
        u.specularColorB = this.specularColor.b;
        u.roles[ROLE_CLEARCOAT] = this.clearcoatMap;
        u.roles[ROLE_CLEARCOAT_ROUGHNESS] = this.clearcoatRoughnessMap;
        u.roles[ROLE_CLEARCOAT_NORMAL] = this.clearcoatNormalMap;
        u.clearcoatNormalScaleX = this.clearcoatNormalScale.x; u.clearcoatNormalScaleY = this.clearcoatNormalScale.y;
        u.roles[ROLE_SHEEN_COLOR] = this.sheenColorMap;
        u.roles[ROLE_SHEEN_ROUGHNESS] = this.sheenRoughnessMap;
        u.roles[ROLE_SPECULAR_INTENSITY] = this.specularIntensityMap;
        u.roles[ROLE_SPECULAR_COLOR] = this.specularColorMap;
        u.transmission = this.transmission;
        u.thickness = this.thickness;
        u.attenuationDistance = this.attenuationDistance;
        u.attenuationR = this.attenuationColor.r; u.attenuationG = this.attenuationColor.g;
        u.attenuationB = this.attenuationColor.b;
        u.dispersion = this.dispersion;
        u.iridescence = this.iridescence;
        u.iridescenceIOR = this.iridescenceIOR;
        const range = this.iridescenceThicknessRange;
        u.iridescenceThicknessMin = range.length > 0 ? range[0] : 100;
        u.iridescenceThicknessMax = range.length > 1 ? range[1] : 400;
        u.anisotropy = this.anisotropy;
        u.anisotropyRotation = this.anisotropyRotation;
        u.roles[ROLE_TRANSMISSION] = this.transmissionMap;
        u.roles[ROLE_THICKNESS] = this.thicknessMap;
        u.roles[ROLE_IRIDESCENCE] = this.iridescenceMap;
        u.roles[ROLE_IRIDESCENCE_THICKNESS] = this.iridescenceThicknessMap;
        u.roles[ROLE_ANISOTROPY] = this.anisotropyMap;
    }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof MeshPhysicalMaterial) {
            const s = source as MeshPhysicalMaterial;
            this.clearcoat = s.clearcoat;
            this.clearcoatRoughness = s.clearcoatRoughness;
            this.sheen = s.sheen;
            this.sheenColor.copy(s.sheenColor);
            this.sheenRoughness = s.sheenRoughness;
            this.ior = s.ior;
            this.specularIntensity = s.specularIntensity;
            this.specularColor.copy(s.specularColor);
            this.clearcoatMap = s.clearcoatMap;
            this.clearcoatRoughnessMap = s.clearcoatRoughnessMap;
            this.clearcoatNormalMap = s.clearcoatNormalMap;
            this.clearcoatNormalScale.copy(s.clearcoatNormalScale);
            this.sheenColorMap = s.sheenColorMap;
            this.sheenRoughnessMap = s.sheenRoughnessMap;
            this.specularIntensityMap = s.specularIntensityMap;
            this.specularColorMap = s.specularColorMap;
            this.transmission = s.transmission;
            this.transmissionMap = s.transmissionMap;
            this.thickness = s.thickness;
            this.thicknessMap = s.thicknessMap;
            this.attenuationDistance = s.attenuationDistance;
            this.attenuationColor.copy(s.attenuationColor);
            this.dispersion = s.dispersion;
            this.iridescence = s.iridescence;
            this.iridescenceMap = s.iridescenceMap;
            this.iridescenceIOR = s.iridescenceIOR;
            this.iridescenceThicknessRange = s.iridescenceThicknessRange.slice();
            this.iridescenceThicknessMap = s.iridescenceThicknessMap;
            this.anisotropy = s.anisotropy;
            this.anisotropyRotation = s.anisotropyRotation;
            this.anisotropyMap = s.anisotropyMap;
        }
        return this;
    }

    override clone(): Material {
        return new MeshPhysicalMaterial().copy(this);
    }
}
