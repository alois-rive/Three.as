// three.js MaterialLoader: a material from three.js's JSON (Material.toJSON),
// with its maps looked up in `textures` (by uuid; setTextures).
//
// `load(name)` reads the JSON from the BlobAsset `name`; `loadAsync(url)`
// also fetches an https: url (see FileLoader). `parse(json)` takes the JSON
// text or its parsed `Dynamic`.

import { Context } from "rive/host";
import { Dynamic, DynamicKind } from "rive/dynamic";
import { Promise } from "rive/promise";
import { Loader } from "./Loader";
import { LoadingManager } from "./LoadingManager";
import { LoaderUtils } from "./LoaderUtils";
import { fetchBytes } from "./FileLoader";
import { JSON, jget, jhas, jnum, jint, jbool, jstr, jnumbers, asStr } from "../core/JSON";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { MeshLambertMaterial } from "../materials/MeshLambertMaterial";
import { MeshPhongMaterial } from "../materials/MeshPhongMaterial";
import { MeshStandardMaterial } from "../materials/MeshStandardMaterial";
import { MeshPhysicalMaterial } from "../materials/MeshPhysicalMaterial";
import { MeshToonMaterial } from "../materials/MeshToonMaterial";
import { MeshMatcapMaterial } from "../materials/MeshMatcapMaterial";
import { MeshNormalMaterial } from "../materials/MeshNormalMaterial";
import { MeshDepthMaterial } from "../materials/MeshDepthMaterial";
import { MeshDistanceMaterial } from "../materials/MeshDistanceMaterial";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { LineDashedMaterial } from "../materials/LineDashedMaterial";
import { PointsMaterial } from "../materials/PointsMaterial";
import { SpriteMaterial } from "../materials/SpriteMaterial";
import { ShadowMaterial } from "../materials/ShadowMaterial";
import { ShaderMaterial, RawShaderMaterial, Uniform } from "../materials/ShaderMaterial";
import { Texture } from "../textures/Texture";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Vector4 } from "../math/Vector4";
import { Matrix4 } from "../math/Matrix4";

export class MaterialLoader extends Loader {
    /// The textures maps refer to, by uuid.
    textures: Map<string, Texture> = new Map<string, Texture>();
    /// Problems met by the last parse (missing textures, unknown types).
    warnings: Array<string> = [];

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    setTextures(value: Map<string, Texture>): MaterialLoader {
        this.textures = value;
        return this;
    }

    /// The material in the BlobAsset `name` (JSON text), or null.
    load(name: string): Material? {
        const context = this.context;
        const full = LoaderUtils.resolveURL(name, this.path);
        const bytes = context != null ? context.blob(full) : null;
        if (bytes == null) {
            this.warn("no blob asset named '" + full + "'");
            return null;
        }
        return this.parse<string>(String.UTF8.decode(bytes!));
    }

    /// The material at `url` (an https: url, else a blob asset).
    loadAsync(url: string): Promise<Material> {
        return loadMaterialAsync(this, url);
    }

    /// A material from three.js's JSON: the text (a string) or its parsed
    /// `Dynamic`. Null when the text is not JSON.
    parse<T>(json: T): Material? {
        let data: Dynamic? = null;
        if (isString<T>()) {
            data = JSON.parse(json as string);
            if (data == null) {
                this.warn("not JSON: " + JSON.lastError);
                return null;
            }
        } else {
            data = json as Dynamic;
        }
        return this.parseMaterial(data);
    }

    /// A material of three.js's class `type` (MeshStandardMaterial ...);
    /// a MeshBasicMaterial for a type not ported.
    createMaterialFromType(type: string): Material {
        return MaterialLoader.createMaterialFromType(type);
    }

    static createMaterialFromType(type: string): Material {
        if (type == "ShadowMaterial") return new ShadowMaterial();
        if (type == "SpriteMaterial") return new SpriteMaterial();
        if (type == "RawShaderMaterial") return new RawShaderMaterial();
        if (type == "ShaderMaterial") return new ShaderMaterial();
        if (type == "PointsMaterial") return new PointsMaterial();
        if (type == "MeshPhysicalMaterial") return new MeshPhysicalMaterial();
        if (type == "MeshStandardMaterial") return new MeshStandardMaterial();
        if (type == "MeshPhongMaterial") return new MeshPhongMaterial();
        if (type == "MeshToonMaterial") return new MeshToonMaterial();
        if (type == "MeshNormalMaterial") return new MeshNormalMaterial();
        if (type == "MeshLambertMaterial") return new MeshLambertMaterial();
        if (type == "MeshDepthMaterial") return new MeshDepthMaterial();
        if (type == "MeshDistanceMaterial") return new MeshDistanceMaterial();
        if (type == "MeshBasicMaterial") return new MeshBasicMaterial();
        if (type == "MeshMatcapMaterial") return new MeshMatcapMaterial();
        if (type == "LineDashedMaterial") return new LineDashedMaterial();
        if (type == "LineBasicMaterial") return new LineBasicMaterial();
        if (type == "Material") return new Material();
        return new MeshBasicMaterial();
    }

    private parseMaterial(json: Dynamic?): Material {
        this.warnings = [];
        const type = jstr(json, "type", "MeshBasicMaterial");
        const material = this.createMaterialFromType(type);
        if (material.type != type && type != "Material") this.warn("material type '" + type + "' is not ported: a MeshBasicMaterial stands in");
        if (jhas(json, "uuid")) material.uuid = jstr(json, "uuid", "");
        material.name = jstr(json, "name", material.name);

        // Shared state.
        material.fog = jbool(json, "fog", material.fog);
        material.flatShading = jbool(json, "flatShading", material.flatShading);
        material.blending = jint(json, "blending", material.blending);
        material.side = jint(json, "side", material.side);
        material.shadowSide = jint(json, "shadowSide", material.shadowSide);
        material.opacity = jnum(json, "opacity", material.opacity);
        material.transparent = jbool(json, "transparent", material.transparent);
        material.alphaTest = jnum(json, "alphaTest", material.alphaTest);
        material.alphaHash = jbool(json, "alphaHash", material.alphaHash);
        material.depthFunc = jint(json, "depthFunc", material.depthFunc);
        material.depthTest = jbool(json, "depthTest", material.depthTest);
        material.depthWrite = jbool(json, "depthWrite", material.depthWrite);
        material.colorWrite = jbool(json, "colorWrite", material.colorWrite);
        material.stencilWrite = jbool(json, "stencilWrite", material.stencilWrite);
        material.stencilWriteMask = jint(json, "stencilWriteMask", material.stencilWriteMask);
        material.stencilFunc = jint(json, "stencilFunc", material.stencilFunc);
        material.stencilRef = jint(json, "stencilRef", material.stencilRef);
        material.stencilFuncMask = jint(json, "stencilFuncMask", material.stencilFuncMask);
        material.stencilFail = jint(json, "stencilFail", material.stencilFail);
        material.stencilZFail = jint(json, "stencilZFail", material.stencilZFail);
        material.stencilZPass = jint(json, "stencilZPass", material.stencilZPass);
        material.wireframe = jbool(json, "wireframe", material.wireframe);
        material.polygonOffset = jbool(json, "polygonOffset", material.polygonOffset);
        material.polygonOffsetFactor = jnum(json, "polygonOffsetFactor", material.polygonOffsetFactor);
        material.polygonOffsetUnits = jnum(json, "polygonOffsetUnits", material.polygonOffsetUnits);
        material.alphaToCoverage = jbool(json, "alphaToCoverage", material.alphaToCoverage);
        material.visible = jbool(json, "visible", material.visible);
        material.toneMapped = jbool(json, "toneMapped", material.toneMapped);
        const vc = jget(json, "vertexColors");
        if (vc != null) {
            material.vertexColors = vc.kind == DynamicKind.string ? Dynamic.asString(vc) == "true" : jbool(json, "vertexColors", false);
        }
        const userData = jget(json, "userData");
        if (userData != null) material.userData = userData!;

        // Per class (three.js sets whichever members the material has).
        if (material instanceof MeshBasicMaterial) {
            const m = material as MeshBasicMaterial;
            readColor(m.color, json, "color");
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.aoMap = this.tex(json, "aoMap", m.aoMap);
            m.aoMapIntensity = jnum(json, "aoMapIntensity", m.aoMapIntensity);
            m.lightMap = this.tex(json, "lightMap", m.lightMap);
            m.lightMapIntensity = jnum(json, "lightMapIntensity", m.lightMapIntensity);
            m.specularMap = this.tex(json, "specularMap", m.specularMap);
            m.envMap = this.tex(json, "envMap", m.envMap);
            m.combine = jint(json, "combine", m.combine);
            m.reflectivity = jnum(json, "reflectivity", m.reflectivity);
            m.refractionRatio = jnum(json, "refractionRatio", m.refractionRatio);
        } else if (material instanceof MeshLambertMaterial) {
            const m = material as MeshLambertMaterial;
            readColor(m.color, json, "color");
            readColor(m.emissive, json, "emissive");
            m.emissiveIntensity = jnum(json, "emissiveIntensity", m.emissiveIntensity);
            m.map = this.tex(json, "map", m.map);
            m.emissiveMap = this.tex(json, "emissiveMap", m.emissiveMap);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.aoMap = this.tex(json, "aoMap", m.aoMap);
            m.aoMapIntensity = jnum(json, "aoMapIntensity", m.aoMapIntensity);
            m.lightMap = this.tex(json, "lightMap", m.lightMap);
            m.lightMapIntensity = jnum(json, "lightMapIntensity", m.lightMapIntensity);
            m.normalMap = this.tex(json, "normalMap", m.normalMap);
            m.normalMapType = jint(json, "normalMapType", m.normalMapType);
            readNormalScale(m.normalScale, json, "normalScale");
            m.bumpMap = this.tex(json, "bumpMap", m.bumpMap);
            m.bumpScale = jnum(json, "bumpScale", m.bumpScale);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
            m.specularMap = this.tex(json, "specularMap", m.specularMap);
            m.envMap = this.tex(json, "envMap", m.envMap);
            m.combine = jint(json, "combine", m.combine);
            m.reflectivity = jnum(json, "reflectivity", m.reflectivity);
            m.refractionRatio = jnum(json, "refractionRatio", m.refractionRatio);
        } else if (material instanceof MeshPhongMaterial) {
            const m = material as MeshPhongMaterial;
            readColor(m.color, json, "color");
            readColor(m.emissive, json, "emissive");
            readColor(m.specular, json, "specular");
            m.shininess = jnum(json, "shininess", m.shininess);
            m.emissiveIntensity = jnum(json, "emissiveIntensity", m.emissiveIntensity);
            m.map = this.tex(json, "map", m.map);
            m.emissiveMap = this.tex(json, "emissiveMap", m.emissiveMap);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.aoMap = this.tex(json, "aoMap", m.aoMap);
            m.aoMapIntensity = jnum(json, "aoMapIntensity", m.aoMapIntensity);
            m.lightMap = this.tex(json, "lightMap", m.lightMap);
            m.lightMapIntensity = jnum(json, "lightMapIntensity", m.lightMapIntensity);
            m.normalMap = this.tex(json, "normalMap", m.normalMap);
            m.normalMapType = jint(json, "normalMapType", m.normalMapType);
            readNormalScale(m.normalScale, json, "normalScale");
            m.bumpMap = this.tex(json, "bumpMap", m.bumpMap);
            m.bumpScale = jnum(json, "bumpScale", m.bumpScale);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
            m.specularMap = this.tex(json, "specularMap", m.specularMap);
            m.envMap = this.tex(json, "envMap", m.envMap);
            m.combine = jint(json, "combine", m.combine);
            m.reflectivity = jnum(json, "reflectivity", m.reflectivity);
            m.refractionRatio = jnum(json, "refractionRatio", m.refractionRatio);
        } else if (material instanceof MeshStandardMaterial) {
            const m = material as MeshStandardMaterial;
            readColor(m.color, json, "color");
            m.roughness = jnum(json, "roughness", m.roughness);
            m.metalness = jnum(json, "metalness", m.metalness);
            readColor(m.emissive, json, "emissive");
            m.emissiveIntensity = jnum(json, "emissiveIntensity", m.emissiveIntensity);
            m.map = this.tex(json, "map", m.map);
            m.emissiveMap = this.tex(json, "emissiveMap", m.emissiveMap);
            m.roughnessMap = this.tex(json, "roughnessMap", m.roughnessMap);
            m.metalnessMap = this.tex(json, "metalnessMap", m.metalnessMap);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.aoMap = this.tex(json, "aoMap", m.aoMap);
            m.aoMapIntensity = jnum(json, "aoMapIntensity", m.aoMapIntensity);
            m.lightMap = this.tex(json, "lightMap", m.lightMap);
            m.lightMapIntensity = jnum(json, "lightMapIntensity", m.lightMapIntensity);
            m.normalMap = this.tex(json, "normalMap", m.normalMap);
            m.normalMapType = jint(json, "normalMapType", m.normalMapType);
            readNormalScale(m.normalScale, json, "normalScale");
            m.bumpMap = this.tex(json, "bumpMap", m.bumpMap);
            m.bumpScale = jnum(json, "bumpScale", m.bumpScale);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
            m.envMap = this.tex(json, "envMap", m.envMap);
            m.envMapIntensity = jnum(json, "envMapIntensity", m.envMapIntensity);
            if (material instanceof MeshPhysicalMaterial) {
                const p = material as MeshPhysicalMaterial;
                p.sheen = jnum(json, "sheen", p.sheen);
                readColor(p.sheenColor, json, "sheenColor");
                p.sheenRoughness = jnum(json, "sheenRoughness", p.sheenRoughness);
                p.sheenColorMap = this.tex(json, "sheenColorMap", p.sheenColorMap);
                p.sheenRoughnessMap = this.tex(json, "sheenRoughnessMap", p.sheenRoughnessMap);
                p.specularIntensity = jnum(json, "specularIntensity", p.specularIntensity);
                readColor(p.specularColor, json, "specularColor");
                p.specularIntensityMap = this.tex(json, "specularIntensityMap", p.specularIntensityMap);
                p.specularColorMap = this.tex(json, "specularColorMap", p.specularColorMap);
                p.ior = jnum(json, "ior", p.ior);
                p.clearcoat = jnum(json, "clearcoat", p.clearcoat);
                p.clearcoatRoughness = jnum(json, "clearcoatRoughness", p.clearcoatRoughness);
                p.clearcoatMap = this.tex(json, "clearcoatMap", p.clearcoatMap);
                p.clearcoatRoughnessMap = this.tex(json, "clearcoatRoughnessMap", p.clearcoatRoughnessMap);
                p.clearcoatNormalMap = this.tex(json, "clearcoatNormalMap", p.clearcoatNormalMap);
                readVector2(p.clearcoatNormalScale, json, "clearcoatNormalScale");
                p.dispersion = jnum(json, "dispersion", p.dispersion);
                p.iridescence = jnum(json, "iridescence", p.iridescence);
                p.iridescenceIOR = jnum(json, "iridescenceIOR", p.iridescenceIOR);
                const range = jnumbers(json, "iridescenceThicknessRange");
                if (range != null && range.length >= 2) p.iridescenceThicknessRange = [range[0], range[1]];
                p.iridescenceMap = this.tex(json, "iridescenceMap", p.iridescenceMap);
                p.iridescenceThicknessMap = this.tex(json, "iridescenceThicknessMap", p.iridescenceThicknessMap);
                p.anisotropy = jnum(json, "anisotropy", p.anisotropy);
                p.anisotropyRotation = jnum(json, "anisotropyRotation", p.anisotropyRotation);
                p.anisotropyMap = this.tex(json, "anisotropyMap", p.anisotropyMap);
                p.transmission = jnum(json, "transmission", p.transmission);
                p.transmissionMap = this.tex(json, "transmissionMap", p.transmissionMap);
                p.thickness = jnum(json, "thickness", p.thickness);
                p.thicknessMap = this.tex(json, "thicknessMap", p.thicknessMap);
                p.attenuationDistance = jnum(json, "attenuationDistance", p.attenuationDistance);
                readColor(p.attenuationColor, json, "attenuationColor");
            }
        } else if (material instanceof MeshToonMaterial) {
            const m = material as MeshToonMaterial;
            readColor(m.color, json, "color");
            readColor(m.emissive, json, "emissive");
            m.emissiveIntensity = jnum(json, "emissiveIntensity", m.emissiveIntensity);
            m.map = this.tex(json, "map", m.map);
            m.gradientMap = this.tex(json, "gradientMap", m.gradientMap);
            m.emissiveMap = this.tex(json, "emissiveMap", m.emissiveMap);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.aoMap = this.tex(json, "aoMap", m.aoMap);
            m.aoMapIntensity = jnum(json, "aoMapIntensity", m.aoMapIntensity);
            m.lightMap = this.tex(json, "lightMap", m.lightMap);
            m.lightMapIntensity = jnum(json, "lightMapIntensity", m.lightMapIntensity);
            m.normalMap = this.tex(json, "normalMap", m.normalMap);
            m.normalMapType = jint(json, "normalMapType", m.normalMapType);
            readNormalScale(m.normalScale, json, "normalScale");
            m.bumpMap = this.tex(json, "bumpMap", m.bumpMap);
            m.bumpScale = jnum(json, "bumpScale", m.bumpScale);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
        } else if (material instanceof MeshMatcapMaterial) {
            const m = material as MeshMatcapMaterial;
            readColor(m.color, json, "color");
            m.matcap = this.tex(json, "matcap", m.matcap);
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.normalMap = this.tex(json, "normalMap", m.normalMap);
            m.normalMapType = jint(json, "normalMapType", m.normalMapType);
            readNormalScale(m.normalScale, json, "normalScale");
            m.bumpMap = this.tex(json, "bumpMap", m.bumpMap);
            m.bumpScale = jnum(json, "bumpScale", m.bumpScale);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
        } else if (material instanceof MeshNormalMaterial) {
            const m = material as MeshNormalMaterial;
            m.normalMap = this.tex(json, "normalMap", m.normalMap);
            m.normalMapType = jint(json, "normalMapType", m.normalMapType);
            readNormalScale(m.normalScale, json, "normalScale");
            m.bumpMap = this.tex(json, "bumpMap", m.bumpMap);
            m.bumpScale = jnum(json, "bumpScale", m.bumpScale);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
        } else if (material instanceof MeshDepthMaterial) {
            const m = material as MeshDepthMaterial;
            m.depthPacking = jint(json, "depthPacking", m.depthPacking);
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
        } else if (material instanceof MeshDistanceMaterial) {
            const m = material as MeshDistanceMaterial;
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.displacementMap = this.tex(json, "displacementMap", m.displacementMap);
            m.displacementScale = jnum(json, "displacementScale", m.displacementScale);
            m.displacementBias = jnum(json, "displacementBias", m.displacementBias);
        } else if (material instanceof LineBasicMaterial) {
            const m = material as LineBasicMaterial;
            readColor(m.color, json, "color");
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.linewidth = jnum(json, "linewidth", m.linewidth);
            if (material instanceof LineDashedMaterial) {
                const d = material as LineDashedMaterial;
                d.dashSize = jnum(json, "dashSize", d.dashSize);
                d.gapSize = jnum(json, "gapSize", d.gapSize);
                d.scale = jnum(json, "scale", d.scale);
            }
        } else if (material instanceof PointsMaterial) {
            const m = material as PointsMaterial;
            readColor(m.color, json, "color");
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.size = jnum(json, "size", m.size);
            m.sizeAttenuation = jbool(json, "sizeAttenuation", m.sizeAttenuation);
        } else if (material instanceof SpriteMaterial) {
            const m = material as SpriteMaterial;
            readColor(m.color, json, "color");
            m.map = this.tex(json, "map", m.map);
            m.alphaMap = this.tex(json, "alphaMap", m.alphaMap);
            m.rotation = jnum(json, "rotation", m.rotation);
            m.sizeAttenuation = jbool(json, "sizeAttenuation", m.sizeAttenuation);
        } else if (material instanceof ShadowMaterial) {
            readColor((material as ShadowMaterial).color, json, "color");
        } else if (material instanceof ShaderMaterial) {
            this.parseShaderMaterial(material as ShaderMaterial, json);
        }
        return material;
    }

    /// Uniforms by their three.js type ("t", "c", "v2", "v3", "v4", "m4",
    /// numbers), `lights`, and the WGSL asset (`shader`); GLSL source
    /// (vertexShader / fragmentShader) cannot run here and is ignored.
    private parseShaderMaterial(m: ShaderMaterial, json: Dynamic?): void {
        m.shader = jstr(json, "shader", m.shader);
        m.vertexEntryPoint = jstr(json, "vertexEntryPoint", m.vertexEntryPoint);
        m.fragmentEntryPoint = jstr(json, "fragmentEntryPoint", m.fragmentEntryPoint);
        m.lights = jbool(json, "lights", m.lights);
        if (m.shader.length == 0 && jhas(json, "fragmentShader")) {
            this.warn("ShaderMaterial '" + m.name + "' has GLSL source only; set its WGSL `shader`");
        }
        const uniforms = jget(json, "uniforms");
        if (uniforms == null || uniforms.kind != DynamicKind.table) return;
        const map = Dynamic.asMap(uniforms);
        const names = map.keys();
        for (let i = 0; i < names.length; i++) {
            const u = map.get(names[i]);
            const type = jstr(u, "type", "");
            const value = jget(u, "value");
            if (type == "t") {
                const texture = this.textureNamed(asStr(value));
                if (texture != null) m.uniforms.set(names[i], new Uniform<Texture>(texture!));
            } else if (type == "c") {
                m.uniforms.set(names[i], new Uniform<Color>(Color.fromHex(<u32>jnum(u, "value", 0))));
            } else if (type == "v2") {
                const a = jnumbers(u, "value");
                if (a != null && a.length >= 2) m.uniforms.set(names[i], new Uniform<Vector2>(new Vector2(a[0], a[1])));
            } else if (type == "v3") {
                const a = jnumbers(u, "value");
                if (a != null && a.length >= 3) m.uniforms.set(names[i], new Uniform<Vector3>(new Vector3(a[0], a[1], a[2])));
            } else if (type == "v4") {
                const a = jnumbers(u, "value");
                if (a != null && a.length >= 4) {
                    m.uniforms.set(names[i], new Uniform<Vector4>(new Vector4(a[0], a[1], a[2], a[3])));
                }
            } else if (type == "m4") {
                const a = jnumbers(u, "value");
                if (a != null && a.length >= 16) m.uniforms.set(names[i], new Uniform<Matrix4>(new Matrix4().fromArray(a!)));
            } else if (value != null && value.kind == DynamicKind.number) {
                m.uniforms.set(names[i], new Uniform<f64>(Dynamic.asNumber(value)));
            } else if (value != null && value.kind == DynamicKind.boolean) {
                m.uniforms.set(names[i], new Uniform<f64>(Dynamic.asBool(value) ? 1 : 0));
            } else {
                this.warn("uniform '" + names[i] + "' of type '" + type + "' is not supported");
            }
        }
    }

    /// The texture member `key` names, or `current` when it is missing.
    private tex(json: Dynamic?, key: string, current: Texture?): Texture? {
        const v = jget(json, key);
        if (v == null) return current;
        return this.textureNamed(asStr(v));
    }

    private textureNamed(uuid: string): Texture? {
        if (this.textures.has(uuid)) return this.textures.get(uuid);
        this.warn("undefined texture " + uuid);
        return null;
    }

    private warn(message: string): void {
        this.warnings.push(message);
        const context = this.context;
        if (context != null) context.log("three: MaterialLoader: " + message);
    }
}

async function loadMaterialAsync(loader: MaterialLoader, url: string): Promise<Material> {
    const settled = await fetchBytes(loader, url).settled();
    if (!settled.ok) return await Promise.reject<Material>(settled.error);
    const material = loader.parse<string>(String.UTF8.decode(settled.value));
    if (material == null) return await Promise.reject<Material>("not a material JSON: " + url);
    return material!;
}

/// Sets `color` from a hex number member.
function readColor(color: Color, json: Dynamic?, key: string): void {
    if (jhas(json, key)) color.setHex(<u32>jnum(json, key, 0));
}

function readVector2(v: Vector2, json: Dynamic?, key: string): void {
    const a = jnumbers(json, key);
    if (a != null && a.length >= 2) v.set(a[0], a[1]);
}

/// normalScale: [x, y], or one number for both (older files).
function readNormalScale(v: Vector2, json: Dynamic?, key: string): void {
    const value = jget(json, key);
    if (value == null) return;
    if (value.kind == DynamicKind.number) {
        const s = Dynamic.asNumber(value);
        v.set(s, s);
    } else {
        readVector2(v, json, key);
    }
}
