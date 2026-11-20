// three.js's GLTFExporter addon (r170): writes a scene, or objects, as glTF
// 2.0: a .glb (bytes) or a .gltf (JSON text, its buffer and images as
// base64 data: URIs).
//
//     const result = new GLTFExporter().parse(scene, { binary: true });
//     // result.glb: the .glb bytes; with binary false, result.json is the
//     // .gltf text. result.gltf is the document as a Dynamic either way.
//
// No callbacks: `parse(input, options)` returns at once (three.js's
// `parse(input, onDone, onError, options)`), `parseAsync` returns a Rive
// Promise. `input` is an Object3D (a Scene, or any object) or an
// Array<Object3D>.
//
// Written as three.js writes them: the node hierarchy (TRS or matrix,
// userData as extras), meshes (every attribute, custom ones as _NAME;
// morph targets as relative POSITION / NORMAL with weights and names;
// geometry groups with a material each; lines and points), materials
// (pbrMetallicRoughness, emissive, normal, occlusion, alpha mode, double
// sided) and the plugins three.js registers by default: KHR_lights_punctual,
// KHR_materials_unlit, transmission, volume, ior, specular, clearcoat,
// dispersion, iridescence, sheen, anisotropy, emissive_strength,
// EXT_materials_bump and EXT_mesh_gpu_instancing; textures with their
// samplers and KHR_texture_transform, cameras, skins and animations (morph
// target tracks merged per mesh). Images are PNGs encoded here (stored, not
// compressed) from the pixels a texture holds: DataTextures in RGBA8, which
// GLTFLoader's textures are once decoded; a texture with no pixels but a
// data: url source is written from that url. Rive images, canvases,
// artboards, render targets and compressed textures cannot be read back
// and are left out, with a warning.

import { Promise } from "rive/promise";
import { Dynamic, DynamicKind } from "rive/dynamic";
import { JSON, emptyObject, cloneDynamic, isEmptyTable, jget, asStr } from "../../core/JSON";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Uint32BufferAttribute } from "../../core/BufferAttribute";
import { Scene } from "../../scenes/Scene";
import { Mesh } from "../../objects/Mesh";
import { SkinnedMesh } from "../../objects/SkinnedMesh";
import { InstancedMesh } from "../../objects/InstancedMesh";
import { Line, LineSegments, LineLoop } from "../../objects/Line";
import { Points } from "../../objects/Points";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { Light } from "../../lights/Light";
import { DirectionalLight } from "../../lights/DirectionalLight";
import { PointLight } from "../../lights/PointLight";
import { SpotLight } from "../../lights/SpotLight";
import { Material } from "../../materials/Material";
import { MeshStandardMaterial } from "../../materials/MeshStandardMaterial";
import { MeshPhysicalMaterial } from "../../materials/MeshPhysicalMaterial";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { MeshLambertMaterial } from "../../materials/MeshLambertMaterial";
import { MeshPhongMaterial } from "../../materials/MeshPhongMaterial";
import { MeshToonMaterial } from "../../materials/MeshToonMaterial";
import { MeshMatcapMaterial } from "../../materials/MeshMatcapMaterial";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { PointsMaterial } from "../../materials/PointsMaterial";
import { SpriteMaterial } from "../../materials/SpriteMaterial";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { Source } from "../../textures/Source";
import { CompressedTexture } from "../../textures/CompressedTexture";
import { AnimationClip } from "../../animation/AnimationClip";
import { KeyframeTrack, InterpolateGLTFCubicSpline } from "../../animation/KeyframeTrack";
import { PropertyBinding } from "../../animation/PropertyBinding";
import { Matrix4 } from "../../math/Matrix4";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Quaternion } from "../../math/Quaternion";
import { Color } from "../../math/Color";
import { base64Decode } from "../loaders/GLTFLoader";
import {
    DoubleSide, InterpolateDiscrete, InterpolateLinear, NoColorSpace, SRGBColorSpace, RGBAFormat,
    NearestFilter, NearestMipmapNearestFilter, NearestMipmapLinearFilter, LinearFilter, LinearMipmapNearestFilter,
    LinearMipmapLinearFilter, ClampToEdgeWrapping, RepeatWrapping, MirroredRepeatWrapping,
} from "../../constants";

// ----------------------------------------------------------------- options, result

/// three.js's options object: `{ binary: true, animations: [clip] }`.
export class GLTFExporterOptions {
    /// Write a .glb (`result.glb`) rather than .gltf JSON (`result.json`).
    binary: bool = false;
    /// Write position, quaternion and scale rather than the matrix (forced
    /// on when there are animations).
    trs: bool = false;
    /// Leave out invisible objects.
    onlyVisible: bool = true;
    /// Images larger than this are scaled down to it.
    maxTextureSize: f64 = Infinity;
    /// Clips to write, bound to the first input.
    animations: Array<AnimationClip> = [];
    /// Write userData.gltfExtensions as extensions.
    includeCustomExtensions: bool = false;
}

/// What parse returns (three.js hands it to onDone).
export class GLTFExporterResult {
    /// The .glb bytes, with `binary`; null otherwise.
    glb: ArrayBuffer? = null;
    /// The glTF JSON as text: the .gltf file without `binary` (its buffer and
    /// images as data: URIs), the .glb's JSON chunk with it.
    json: string = "";
    /// The glTF JSON as a Dynamic (three.js's onDone(json) object).
    gltf: Dynamic = Dynamic.newTable();
    /// What could not be written (three.js's console warnings).
    warnings: Array<string> = [];
}

/// A writer plugin (three.js's plugin objects): override the hooks it
/// needs. `writer` is the GLTFWriter of the parse in progress.
export class GLTFExporterPlugin {
    name: string = "";
    writer: GLTFWriter? = null;

    beforeParse(input: Array<Object3D>): void {}
    writeNode(object: Object3D, nodeDef: Dynamic): void {}
    writeMesh(mesh: Object3D, meshDef: Dynamic): void {}
    /// three.js's writeMaterialAsync.
    writeMaterial(material: Material, materialDef: Dynamic): void {}
    writeTexture(map: Texture, textureDef: Dynamic): void {}
    afterParse(input: Array<Object3D>): void {}
}

// ----------------------------------------------------------------- exporter

export class GLTFExporter {
    /// The plugins run, in order (three.js keeps their factories).
    pluginCallbacks: Array<GLTFExporterPlugin> = [];

    /// three.js's GLTFExporter.Utils.
    static Utils: GLTFExporterUtils = new GLTFExporterUtils();

    constructor() {
        this.register(new GLTFLightExtension());
        this.register(new GLTFMaterialsUnlitExtension());
        this.register(new GLTFMaterialsTransmissionExtension());
        this.register(new GLTFMaterialsVolumeExtension());
        this.register(new GLTFMaterialsIorExtension());
        this.register(new GLTFMaterialsSpecularExtension());
        this.register(new GLTFMaterialsClearcoatExtension());
        this.register(new GLTFMaterialsDispersionExtension());
        this.register(new GLTFMaterialsIridescenceExtension());
        this.register(new GLTFMaterialsSheenExtension());
        this.register(new GLTFMaterialsAnisotropyExtension());
        this.register(new GLTFMaterialsEmissiveStrengthExtension());
        this.register(new GLTFMaterialsBumpExtension());
        this.register(new GLTFMeshGpuInstancing());
    }

    register(plugin: GLTFExporterPlugin): GLTFExporter {
        if (this.pluginCallbacks.indexOf(plugin) < 0) this.pluginCallbacks.push(plugin);
        return this;
    }

    unregister(plugin: GLTFExporterPlugin): GLTFExporter {
        const i = this.pluginCallbacks.indexOf(plugin);
        if (i >= 0) this.pluginCallbacks.splice(i, 1);
        return this;
    }

    /// Writes `input`: an Object3D (a Scene, or an object put in a scene
    /// named "AuxScene") or an Array<Object3D>.
    parse<T>(input: T, options: GLTFExporterOptions = new GLTFExporterOptions()): GLTFExporterResult {
        const writer = new GLTFWriter();
        for (let i = 0; i < this.pluginCallbacks.length; i++) this.pluginCallbacks[i].writer = writer;
        writer.setPlugins(this.pluginCallbacks);
        const result = writer.write(inputList(input), options);
        for (let i = 0; i < this.pluginCallbacks.length; i++) this.pluginCallbacks[i].writer = null;
        return result;
    }

    /// As parse, as a Rive Promise (settled at once: images encode here).
    parseAsync<T>(input: T, options: GLTFExporterOptions = new GLTFExporterOptions()): Promise<GLTFExporterResult> {
        return Promise.resolve<GLTFExporterResult>(this.parse(input, options));
    }
}

function inputList<T>(input: T): Array<Object3D> {
    const out: Array<Object3D> = [];
    if (input instanceof Object3D) {
        out.push(input as Object3D);
    } else if (input instanceof Array<Object3D>) {
        const a = input as Array<Object3D>;
        for (let i = 0; i < a.length; i++) out.push(a[i]);
    }
    return out;
}

// ----------------------------------------------------------------- constants

const POINTS = 0x0000;
const LINES = 0x0001;
const LINE_LOOP = 0x0002;
const LINE_STRIP = 0x0003;
const TRIANGLES = 0x0004;

const BYTE = 0x1400;
const UNSIGNED_BYTE = 0x1401;
const SHORT = 0x1402;
const UNSIGNED_SHORT = 0x1403;
const INT = 0x1404;
const UNSIGNED_INT = 0x1405;
const FLOAT = 0x1406;

const ARRAY_BUFFER = 0x8892;
const ELEMENT_ARRAY_BUFFER = 0x8893;

/// THREE_TO_WEBGL for filters and wrapping; -1 when unknown.
function threeToWebGL(value: i32): i32 {
    if (value == NearestFilter) return 0x2600;
    if (value == LinearFilter) return 0x2601;
    if (value == NearestMipmapNearestFilter) return 0x2700;
    if (value == LinearMipmapNearestFilter) return 0x2701;
    if (value == NearestMipmapLinearFilter) return 0x2702;
    if (value == LinearMipmapLinearFilter) return 0x2703;
    if (value == ClampToEdgeWrapping) return 33071;
    if (value == RepeatWrapping) return 10497;
    if (value == MirroredRepeatWrapping) return 33648;
    return -1;
}

/// PATH_PROPERTIES: the glTF path of an animated property, or "".
function pathProperty(name: string): string {
    if (name == "scale") return "scale";
    if (name == "position") return "translation";
    if (name == "quaternion") return "rotation";
    if (name == "morphTargetInfluences") return "weights";
    return "";
}

const GLB_HEADER_BYTES = 12;
const GLB_HEADER_MAGIC: u32 = 0x46546C67;
const GLB_VERSION: u32 = 2;
const GLB_CHUNK_PREFIX_BYTES = 8;
const GLB_CHUNK_TYPE_JSON: u32 = 0x4E4F534A;
const GLB_CHUNK_TYPE_BIN: u32 = 0x004E4942;

// ----------------------------------------------------------------- utilities

function isIdentityMatrix(matrix: Matrix4): bool {
    const e = matrix.elements;
    for (let i = 0; i < 16; i++) {
        const want: f32 = (i % 5) == 0 ? 1 : 0;
        if (e[i] != want) return false;
    }
    return true;
}

/// Rounded up to a multiple of 4.
function getPaddedBufferSize(bufferSize: i32): i32 {
    return (bufferSize + 3) & ~3;
}

/// `bytes` padded to a multiple of 4 with `paddingByte`.
function getPaddedArrayBuffer(bytes: Uint8Array, paddingByte: u8 = 0): Uint8Array {
    const paddedLength = getPaddedBufferSize(bytes.length);
    if (paddedLength == bytes.length) return bytes;
    const array = new Uint8Array(paddedLength);
    array.set(bytes, 0);
    for (let i = bytes.length; i < paddedLength; i++) array[i] = paddingByte;
    return array;
}

/// An f32 as the shortest number that reads back as it ("0.1", not
/// "0.10000000149011612").
function f32Number(v: f32): f64 {
    return parseFloat(v.toString());
}

function pushIndex(array: Dynamic, value: Dynamic?): i32 {
    const index = <i32>Dynamic.length(array);
    array.push(value);
    return index;
}

/// The array at `key` of `parent`, made when missing.
function childArray(parent: Dynamic, key: string): Dynamic {
    const c = jget(parent, key);
    if (c != null && c.kind == DynamicKind.table) return c;
    const t = Dynamic.newTable();
    parent.set(key, t);
    return t;
}

/// The object at `key` of `parent`, made when missing (and given a member
/// at once: an empty table is written as `[]`).
function childObject(parent: Dynamic, key: string): Dynamic {
    const c = jget(parent, key);
    if (c != null && c.kind == DynamicKind.table) return c;
    const t = Dynamic.newTable();
    parent.set(key, t);
    return t;
}

/// `def`, or a table written `{}` when it is empty (JSON.stringify writes
/// an empty table as `[]`): for definitions that may have no member.
function asObject(def: Dynamic): Dynamic {
    return isEmptyTable(def) ? emptyObject() : def;
}

function colorArray(c: Color): Dynamic {
    return Dynamic.fromNumbers([c.r, c.g, c.b]);
}

function num(value: f64): Dynamic {
    return Dynamic.fromNumber(value);
}

/// Vertex data read as numbers: a float attribute or an index.
class AccessorSource {
    itemSize: i32 = 1;
    count: i32 = 0;
    normalized: bool = false;
    f32: Float32Array? = null;
    u32: Uint32Array? = null;

    static ofAttribute(attribute: BufferAttribute): AccessorSource {
        const s = new AccessorSource();
        s.itemSize = attribute.itemSize;
        s.count = attribute.count;
        s.normalized = attribute.normalized;
        s.f32 = attribute.array;
        return s;
    }

    static ofIndex(index: Uint32BufferAttribute): AccessorSource {
        const s = new AccessorSource();
        s.count = index.count;
        s.u32 = index.array;
        return s;
    }

    get(i: i32): f64 {
        const f = this.f32;
        if (f != null) return <f64>f[i];
        return <f64>this.u32![i];
    }
}

/// The geometry and materials of a Mesh, Line or Points.
class MeshParts {
    geometry: BufferGeometry? = null;
    materials: Array<Material> = [];
    isMultiMaterial: bool = false;
    mode: i32 = TRIANGLES;
}

function meshParts(object: Object3D): MeshParts {
    const p = new MeshParts();
    if (object instanceof Mesh) {
        const m = object as Mesh;
        p.geometry = m.geometry;
        p.isMultiMaterial = m.materials.length > 0;
        if (p.isMultiMaterial) {
            for (let i = 0; i < m.materials.length; i++) p.materials.push(m.materials[i]);
            p.mode = TRIANGLES;
        } else {
            p.materials.push(m.material);
            p.mode = m.material.wireframe ? LINES : TRIANGLES;
        }
    } else if (object instanceof Line) {
        const l = object as Line;
        p.geometry = l.geometry;
        p.materials.push(l.material);
        p.mode = object instanceof LineSegments ? LINES : object instanceof LineLoop ? LINE_LOOP : LINE_STRIP;
    } else if (object instanceof Points) {
        const pts = object as Points;
        p.geometry = pts.geometry;
        p.materials.push(pts.material);
        p.mode = POINTS;
    }
    return p;
}

/// The members of a material three.js reads by duck typing (null when the
/// class has none).
class MaterialMembers {
    color: Color? = null;
    emissive: Color? = null;
    map: Texture? = null;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2? = null;
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    metalnessMap: Texture? = null;
    roughnessMap: Texture? = null;
}

function materialMembers(material: Material): MaterialMembers {
    const o = new MaterialMembers();
    if (material instanceof MeshStandardMaterial) {
        const m = material as MeshStandardMaterial;
        o.color = m.color; o.emissive = m.emissive; o.map = m.map; o.emissiveMap = m.emissiveMap;
        o.normalMap = m.normalMap; o.normalScale = m.normalScale; o.aoMap = m.aoMap;
        o.aoMapIntensity = m.aoMapIntensity; o.metalnessMap = m.metalnessMap; o.roughnessMap = m.roughnessMap;
    } else if (material instanceof MeshBasicMaterial) {
        const m = material as MeshBasicMaterial;
        o.color = m.color; o.map = m.map; o.aoMap = m.aoMap; o.aoMapIntensity = m.aoMapIntensity;
    } else if (material instanceof MeshLambertMaterial) {
        const m = material as MeshLambertMaterial;
        o.color = m.color; o.emissive = m.emissive; o.map = m.map; o.emissiveMap = m.emissiveMap;
        o.normalMap = m.normalMap; o.normalScale = m.normalScale; o.aoMap = m.aoMap; o.aoMapIntensity = m.aoMapIntensity;
    } else if (material instanceof MeshPhongMaterial) {
        const m = material as MeshPhongMaterial;
        o.color = m.color; o.emissive = m.emissive; o.map = m.map; o.emissiveMap = m.emissiveMap;
        o.normalMap = m.normalMap; o.normalScale = m.normalScale; o.aoMap = m.aoMap; o.aoMapIntensity = m.aoMapIntensity;
    } else if (material instanceof MeshToonMaterial) {
        const m = material as MeshToonMaterial;
        o.color = m.color; o.emissive = m.emissive; o.map = m.map; o.emissiveMap = m.emissiveMap;
        o.normalMap = m.normalMap; o.normalScale = m.normalScale; o.aoMap = m.aoMap; o.aoMapIntensity = m.aoMapIntensity;
    } else if (material instanceof MeshMatcapMaterial) {
        const m = material as MeshMatcapMaterial;
        o.color = m.color; o.map = m.map; o.normalMap = m.normalMap; o.normalScale = m.normalScale;
    } else if (material instanceof LineBasicMaterial) {
        const m = material as LineBasicMaterial;
        o.color = m.color; o.map = m.map;
    } else if (material instanceof PointsMaterial) {
        const m = material as PointsMaterial;
        o.color = m.color; o.map = m.map;
    } else if (material instanceof SpriteMaterial) {
        const m = material as SpriteMaterial;
        o.color = m.color; o.map = m.map;
    }
    return o;
}

/// An image written, by what it was read from.
class CachedImage {
    data: ArrayBufferView? = null;
    source: Source? = null;
    key: string = "";
    index: i32 = -1;
}

// ----------------------------------------------------------------- writer

/// three.js's GLTFWriter: builds the glTF JSON and the binary buffer. One
/// per parse; plugins reach it through `plugin.writer`.
export class GLTFWriter {
    plugins: Array<GLTFExporterPlugin> = [];
    options: GLTFExporterOptions = new GLTFExporterOptions();
    buffers: Array<Uint8Array> = [];
    byteOffset: i32 = 0;
    /// Node index by object id.
    nodeMap: Map<i32, i32> = new Map<i32, i32>();
    skins: Array<SkinnedMesh> = [];
    /// Extension names in first-use order (three.js's objects of `true`).
    extensionsUsed: Map<string, bool> = new Map<string, bool>();
    extensionsRequired: Map<string, bool> = new Map<string, bool>();
    json: Dynamic;
    warnings: Array<string> = [];

    // Caches (three.js's `cache`): attributes by uid (getUID), meshes by
    // geometry and materials, materials and textures by id.
    private uidAttributes: Array<BufferAttribute> = [];
    private uidIndices: Array<Uint32BufferAttribute> = [];
    private uidValues: Array<i32> = [];
    private uidIndexValues: Array<i32> = [];
    private uid: i32 = 0;
    private cacheMeshes: Map<string, i32> = new Map<string, i32>();
    private cacheAttributes: Map<string, i32> = new Map<string, i32>();
    private normalizedSources: Array<BufferAttribute> = [];
    private normalizedAttributes: Array<BufferAttribute> = [];
    private cacheMaterials: Map<i32, i32> = new Map<i32, i32>();
    private cacheTextures: Map<i32, i32> = new Map<i32, i32>();
    private cacheImages: Array<CachedImage> = [];

    constructor() {
        const json = Dynamic.newTable();
        const asset = Dynamic.newTable();
        asset.set("version", Dynamic.fromString("2.0"));
        asset.set("generator", Dynamic.fromString("THREE.GLTFExporter r170 (ThreeAS)"));
        json.set("asset", asset);
        this.json = json;
    }

    setPlugins(plugins: Array<GLTFExporterPlugin>): void {
        this.plugins = plugins;
    }

    /// three.js's console.warn, collected (each message once).
    warn(message: string): void {
        if (this.warnings.indexOf(message) < 0) this.warnings.push(message);
    }

    /// three.js's writeAsync: the document and its binary.
    write(input: Array<Object3D>, given: GLTFExporterOptions): GLTFExporterResult {
        // A copy, as three.js's Object.assign (the caller's stays as it is).
        const options = new GLTFExporterOptions();
        options.binary = given.binary;
        options.trs = given.trs;
        options.onlyVisible = given.onlyVisible;
        options.maxTextureSize = given.maxTextureSize;
        options.animations = given.animations;
        options.includeCustomExtensions = given.includeCustomExtensions;
        this.options = options;
        if (options.animations.length > 0) {
            // Only TRS properties, and not matrices, may be targeted by animation.
            options.trs = true;
        }
        this.processInput(input);
        const json = this.json;

        // Merge buffers.
        let total = 0;
        for (let i = 0; i < this.buffers.length; i++) total += this.buffers[i].length;
        const blob = new Uint8Array(total);
        let at = 0;
        for (let i = 0; i < this.buffers.length; i++) {
            blob.set(this.buffers[i], at);
            at += this.buffers[i].length;
        }

        // Declare extensions.
        const used = this.extensionsUsed.keys();
        if (used.length > 0) {
            const list = Dynamic.newTable();
            for (let i = 0; i < used.length; i++) list.push(Dynamic.fromString(used[i]));
            json.set("extensionsUsed", list);
        }
        const required = this.extensionsRequired.keys();
        if (required.length > 0) {
            const list = Dynamic.newTable();
            for (let i = 0; i < required.length; i++) list.push(Dynamic.fromString(required[i]));
            json.set("extensionsRequired", list);
        }

        // Update byteLength of the single buffer.
        const buffers = jget(json, "buffers");
        const buffer0 = buffers != null ? Dynamic.at(buffers, 0) : null;
        if (buffer0 != null) buffer0.set("byteLength", num(<f64>blob.length));

        const result = new GLTFExporterResult();
        result.gltf = json;
        result.warnings = this.warnings;

        if (!options.binary) {
            if (buffer0 != null) buffer0.set("uri", Dynamic.fromString("data:application/octet-stream;base64," + base64Encode(blob)));
            result.json = JSON.stringify(json);
            return result;
        }

        // GLB: header, JSON chunk (padded with spaces), binary chunk (zeros).
        const text = JSON.stringify(json);
        result.json = text;
        const jsonChunk = getPaddedArrayBuffer(Uint8Array.wrap(String.UTF8.encode(text)), 0x20);
        const binaryChunk = getPaddedArrayBuffer(blob);
        const hasBinary = binaryChunk.length > 0;
        const totalByteLength = GLB_HEADER_BYTES + GLB_CHUNK_PREFIX_BYTES + jsonChunk.length
            + (hasBinary ? GLB_CHUNK_PREFIX_BYTES + binaryChunk.length : 0);
        const glb = new Uint8Array(totalByteLength);
        const view = new DataView(glb.buffer);
        view.setUint32(0, GLB_HEADER_MAGIC, true);
        view.setUint32(4, GLB_VERSION, true);
        view.setUint32(8, <u32>totalByteLength, true);
        view.setUint32(12, <u32>jsonChunk.length, true);
        view.setUint32(16, GLB_CHUNK_TYPE_JSON, true);
        glb.set(jsonChunk, 20);
        if (hasBinary) {
            const o = 20 + jsonChunk.length;
            view.setUint32(o, <u32>binaryChunk.length, true);
            view.setUint32(o + 4, GLB_CHUNK_TYPE_BIN, true);
            glb.set(binaryChunk, o + GLB_CHUNK_PREFIX_BYTES);
        }
        result.glb = glb.buffer;
        return result;
    }

    /// Writes `userData` as `extras` (and, with includeCustomExtensions,
    /// its `gltfExtensions` as extensions). three.js takes the object.
    serializeUserData(userData: Dynamic?, objectDef: Dynamic): void {
        if (isEmptyTable(userData)) return;
        const json = cloneDynamic(userData)!;
        if (json.kind != DynamicKind.table) return;
        const gltfExtensions = jget(json, "gltfExtensions");
        if (this.options.includeCustomExtensions && gltfExtensions != null && gltfExtensions.kind == DynamicKind.table) {
            const extensions = childObject(objectDef, "extensions");
            const map = Dynamic.asMap(gltfExtensions);
            const names = map.keys();
            for (let i = 0; i < names.length; i++) {
                const value = map.get(names[i]);
                if (value == null) continue;
                extensions.set(names[i], value);
                this.extensionsUsed.set(names[i], true);
            }
            json.set("gltfExtensions", null);
        }
        if (!isEmptyTable(json)) objectDef.set("extras", json);
    }

    /// An id for an attribute; its relative (morph target) copy has another.
    getUID(attribute: BufferAttribute, isRelativeCopy: bool = false): i32 {
        let i = this.uidAttributes.indexOf(attribute);
        if (i < 0) {
            i = this.uidAttributes.length;
            this.uidAttributes.push(attribute);
            this.uidValues.push(this.uid);
            this.uid += 2;
        }
        return this.uidValues[i] + (isRelativeCopy ? 0 : 1);
    }

    private getIndexUID(index: Uint32BufferAttribute): i32 {
        let i = this.uidIndices.indexOf(index);
        if (i < 0) {
            i = this.uidIndices.length;
            this.uidIndices.push(index);
            this.uidIndexValues.push(this.uid);
            this.uid += 2;
        }
        return this.uidIndexValues[i];
    }

    /// Whether every normal is unit length (within glTF-validator's 0.0005).
    isNormalizedNormalAttribute(normal: BufferAttribute): bool {
        if (this.normalizedSources.indexOf(normal) >= 0) return false;
        for (let i = 0; i < normal.count; i++) {
            const x = normal.getX(i), y = normal.getY(i), z = normal.getZ(i);
            if (Math.abs(Math.sqrt(x * x + y * y + z * z) - 1.0) > 0.0005) return false;
        }
        return true;
    }

    /// A unit-length copy of `normal` ((1, 0, 0) for zero normals), once.
    createNormalizedNormalAttribute(normal: BufferAttribute): BufferAttribute {
        const i = this.normalizedSources.indexOf(normal);
        if (i >= 0) return this.normalizedAttributes[i];
        const attribute = normal.clone();
        for (let k = 0; k < attribute.count; k++) {
            const x = attribute.getX(k), y = attribute.getY(k), z = attribute.getZ(k);
            if (x == 0 && y == 0 && z == 0) {
                attribute.setXYZ(k, 1, 0, 0);
            } else {
                const l = Math.sqrt(x * x + y * y + z * z);
                attribute.setXYZ(k, x / l, y / l, z / l);
            }
        }
        this.normalizedSources.push(normal);
        this.normalizedAttributes.push(attribute);
        return attribute;
    }

    /// KHR_texture_transform for a texture's offset, rotation and repeat.
    applyTextureTransform(mapDef: Dynamic, texture: Texture): void {
        let didTransform = false;
        const transformDef = Dynamic.newTable();
        if (texture.offset.x != 0 || texture.offset.y != 0) {
            transformDef.set("offset", Dynamic.fromNumbers([texture.offset.x, texture.offset.y]));
            didTransform = true;
        }
        if (texture.rotation != 0) {
            transformDef.set("rotation", num(texture.rotation));
            didTransform = true;
        }
        if (texture.repeat.x != 1 || texture.repeat.y != 1) {
            transformDef.set("scale", Dynamic.fromNumbers([texture.repeat.x, texture.repeat.y]));
            didTransform = true;
        }
        if (didTransform) {
            childObject(mapDef, "extensions").set("KHR_texture_transform", transformDef);
            this.extensionsUsed.set("KHR_texture_transform", true);
        }
    }

    /// A textureInfo, { index, texCoord, extensions }, or null when the
    /// texture has no image to write. three.js builds these inline.
    textureInfo(map: Texture?, texCoord: bool = true): Dynamic? {
        if (map == null) return null;
        const index = this.processTexture(map);
        if (index < 0) return null;
        const def = Dynamic.newTable();
        def.set("index", num(<f64>index));
        if (texCoord) def.set("texCoord", num(<f64>map.channel));
        this.applyTextureTransform(def, map);
        return def;
    }

    /// One texture with metalness in blue and roughness in green, as glTF
    /// packs them (the same texture when both maps are one).
    buildMetalRoughTexture(metalnessMap: Texture?, roughnessMap: Texture?): Texture? {
        if (metalnessMap === roughnessMap) return metalnessMap;
        const reference = metalnessMap != null ? metalnessMap : roughnessMap;
        if (reference == null) return null;
        const metalness = rgba8Of(metalnessMap);
        const roughness = rgba8Of(roughnessMap);
        if ((metalnessMap != null && metalness == null) || (roughnessMap != null && roughness == null)) {
            this.warn("THREE.GLTFExporter: metalnessMap and roughnessMap differ and have no pixels to merge: "
                + "the " + (metalnessMap != null ? "metalnessMap" : "roughnessMap") + " is written alone.");
            return reference;
        }
        const width = max<u32>(metalness != null ? metalness.dataWidth : 0, roughness != null ? roughness.dataWidth : 0);
        const height = max<u32>(metalness != null ? metalness.dataHeight : 0, roughness != null ? roughness.dataHeight : 0);
        const composite = new Uint8Array(<i32>(width * height * 4));
        for (let i = 0; i < composite.length; i += 4) {
            composite[i] = 0x00; composite[i + 1] = 0xff; composite[i + 2] = 0xff; composite[i + 3] = 0xff;
        }
        if (metalness != null) copyChannel(metalness, metalnessMap!.colorSpace == SRGBColorSpace, 2, composite, width, height);
        if (roughness != null) copyChannel(roughness, roughnessMap!.colorSpace == SRGBColorSpace, 1, composite, width, height);
        const texture = new DataTexture(composite, width, height);
        copySampling(reference, texture);
        texture.flipY = false;
        texture.premultiplyAlpha = false;
        texture.colorSpace = NoColorSpace;
        texture.channel = reference.channel;
        if (metalnessMap != null && roughnessMap != null && metalnessMap.channel != roughnessMap.channel) {
            this.warn("THREE.GLTFExporter: UV channels for metalnessMap and roughnessMap textures must match.");
        }
        this.warn("THREE.GLTFExporter: Merged metalnessMap and roughnessMap textures.");
        return texture;
    }

    // ------------------------------------------------------------ buffers

    /// Appends to the one buffer; returns its index (0).
    processBuffer(buffer: Uint8Array): i32 {
        const json = this.json;
        if (jget(json, "buffers") == null) {
            const buffers = Dynamic.newTable();
            const b = Dynamic.newTable();
            b.set("byteLength", num(0));
            buffers.push(b);
            json.set("buffers", buffers);
        }
        this.buffers.push(buffer);
        return 0;
    }

    /// A bufferView of `count` elements of `attribute` from `start`, in
    /// `componentType`; `target` 0 for none. Returns its index.
    private processBufferView(attribute: AccessorSource, componentType: i32, start: i32, count: i32,
                              target: i32): i32 {
        const bufferViews = childArray(this.json, "bufferViews");
        let componentSize = 4;
        if (componentType == BYTE || componentType == UNSIGNED_BYTE) componentSize = 1;
        else if (componentType == SHORT || componentType == UNSIGNED_SHORT) componentSize = 2;
        let byteStride = attribute.itemSize * componentSize;
        if (target == ARRAY_BUFFER) {
            // Each element of a vertex attribute MUST be aligned to 4-byte
            // boundaries inside a bufferView.
            byteStride = getPaddedBufferSize(byteStride);
        }
        const byteLength = getPaddedBufferSize(count * byteStride);
        const bytes = new Uint8Array(byteLength);
        const dataView = new DataView(bytes.buffer);
        let offset = 0;
        for (let i = start; i < start + count; i++) {
            for (let a = 0; a < attribute.itemSize; a++) {
                const value = attribute.get(i * attribute.itemSize + a);
                if (componentType == FLOAT) dataView.setFloat32(offset, <f32>value, true);
                else if (componentType == INT) dataView.setInt32(offset, <i32>value, true);
                else if (componentType == UNSIGNED_INT) dataView.setUint32(offset, <u32>value, true);
                else if (componentType == SHORT) dataView.setInt16(offset, <i16>value, true);
                else if (componentType == UNSIGNED_SHORT) dataView.setUint16(offset, <u16>value, true);
                else if (componentType == BYTE) dataView.setInt8(offset, <i8>value);
                else if (componentType == UNSIGNED_BYTE) dataView.setUint8(offset, <u8>value);
                offset += componentSize;
            }
            if ((offset % byteStride) != 0) offset += byteStride - (offset % byteStride);
        }
        const bufferViewDef = Dynamic.newTable();
        bufferViewDef.set("buffer", num(<f64>this.processBuffer(bytes)));
        bufferViewDef.set("byteOffset", num(<f64>this.byteOffset));
        bufferViewDef.set("byteLength", num(<f64>byteLength));
        if (target != 0) bufferViewDef.set("target", num(<f64>target));
        // Only define byteStride for vertex attributes.
        if (target == ARRAY_BUFFER) bufferViewDef.set("byteStride", num(<f64>byteStride));
        this.byteOffset += byteLength;
        return pushIndex(bufferViews, bufferViewDef);
    }

    /// A bufferView holding an encoded image.
    processBufferViewImage(bytes: Uint8Array): i32 {
        const bufferViews = childArray(this.json, "bufferViews");
        const buffer = getPaddedArrayBuffer(bytes);
        const bufferViewDef = Dynamic.newTable();
        bufferViewDef.set("buffer", num(<f64>this.processBuffer(buffer)));
        bufferViewDef.set("byteOffset", num(<f64>this.byteOffset));
        bufferViewDef.set("byteLength", num(<f64>bytes.length));
        this.byteOffset += buffer.length;
        return pushIndex(bufferViews, bufferViewDef);
    }

    /// An accessor for `attribute` (FLOAT): `count` elements from `start`
    /// (-1: to the end). With a `geometry`, its bufferView targets
    /// ARRAY_BUFFER. Returns the accessor's index, or -1 when there is
    /// nothing to write (three.js's null).
    processAccessor(attribute: BufferAttribute, geometry: BufferGeometry? = null, start: i32 = 0,
                    count: i32 = -1): i32 {
        return this.processAccessorSource(AccessorSource.ofAttribute(attribute), FLOAT,
            geometry != null ? ARRAY_BUFFER : 0, start, count);
    }

    /// An accessor for an index (UNSIGNED_SHORT when every index fits, else
    /// UNSIGNED_INT), targeting ELEMENT_ARRAY_BUFFER.
    processIndexAccessor(index: Uint32BufferAttribute, start: i32 = 0, count: i32 = -1): i32 {
        const a = index.array;
        let maxIndex: u32 = 0;
        for (let i = 0; i < a.length; i++) if (a[i] > maxIndex) maxIndex = a[i];
        const componentType = maxIndex < 65535 ? UNSIGNED_SHORT : UNSIGNED_INT;
        return this.processAccessorSource(AccessorSource.ofIndex(index), componentType, ELEMENT_ARRAY_BUFFER,
            start, count);
    }

    private processAccessorSource(attribute: AccessorSource, componentType: i32, target: i32, start: i32,
                                  count: i32): i32 {
        if (count < 0) count = attribute.count - start;
        count = min<i32>(count, attribute.count - start);
        // Skip creating an accessor if the attribute doesn't have data to export.
        if (count <= 0) return -1;
        const itemSize = attribute.itemSize;
        const minValues = new Array<f64>(itemSize);
        const maxValues = new Array<f64>(itemSize);
        for (let a = 0; a < itemSize; a++) {
            minValues[a] = Infinity;
            maxValues[a] = -Infinity;
        }
        for (let i = start; i < start + count; i++) {
            for (let a = 0; a < itemSize; a++) {
                const value = attribute.get(i * itemSize + a);
                if (value < minValues[a]) minValues[a] = value;
                if (value > maxValues[a]) maxValues[a] = value;
            }
        }
        const bufferView = this.processBufferView(attribute, componentType, start, count, target);
        const accessorDef = Dynamic.newTable();
        accessorDef.set("bufferView", num(<f64>bufferView));
        accessorDef.set("componentType", num(<f64>componentType));
        accessorDef.set("count", num(<f64>count));
        accessorDef.set("max", Dynamic.fromNumbers(maxValues));
        accessorDef.set("min", Dynamic.fromNumbers(minValues));
        accessorDef.set("type", Dynamic.fromString(accessorType(itemSize)));
        if (attribute.normalized) accessorDef.set("normalized", Dynamic.fromBool(true));
        return pushIndex(childArray(this.json, "accessors"), accessorDef);
    }

    // ------------------------------------------------------------ images, textures

    /// The image of `map`, as a PNG made from its pixels (flipped when
    /// `flipY`) or the bytes of its data: url; -1 when it has neither.
    processImage(map: Texture, format: i32, flipY: bool, mimeType: string = "image/png"): i32 {
        const dt = map instanceof DataTexture ? map as DataTexture : null;
        const pixels = dt != null && dt.dataWidth > 0 && dt.dataHeight > 0 ? dt.data : null;
        const key = mimeType + ":flipY/" + (flipY ? "true" : "false");
        for (let i = 0; i < this.cacheImages.length; i++) {
            const c = this.cacheImages[i];
            if (c.key != key) continue;
            if (pixels != null ? c.data === pixels : c.source === map.source) return c.index;
        }
        const options = this.options;
        const imageDef = Dynamic.newTable();
        if (dt != null && pixels != null) {
            if (format != RGBAFormat || !(pixels instanceof Uint8Array)
                || pixels.byteLength < <i32>(dt.dataWidth * dt.dataHeight * 4)) {
                this.warn("GLTFExporter: Only RGBAFormat is supported (8 bits a channel).");
                return -1;
            }
            let width = <i32>dt.dataWidth, height = <i32>dt.dataHeight;
            let data = pixels as Uint8Array;
            if (<f64>width > options.maxTextureSize || <f64>height > options.maxTextureSize) {
                this.warn("GLTFExporter: Image size is bigger than maxTextureSize");
                const w = <i32>Math.min(<f64>width, options.maxTextureSize);
                const h = <i32>Math.min(<f64>height, options.maxTextureSize);
                data = resample(data, width, height, max<i32>(w, 1), max<i32>(h, 1));
                width = max<i32>(w, 1);
                height = max<i32>(h, 1);
            }
            imageDef.set("mimeType", Dynamic.fromString("image/png"));
            const png = encodePNG(data, width, height, flipY, dt.premultiplyAlpha);
            this.writeImageBytes(imageDef, png, "image/png");
        } else if (map.source.url.startsWith("data:")) {
            const url = map.source.url;
            const comma = url.indexOf(",");
            const header = comma > 5 ? url.substring(5, comma) : "";
            const semicolon = header.indexOf(";");
            const type = semicolon >= 0 ? header.substring(0, semicolon) : header;
            if (comma < 0 || !header.endsWith(";base64")) {
                this.warn("THREE.GLTFExporter: only base64 data: urls are written.");
                return -1;
            }
            imageDef.set("mimeType", Dynamic.fromString(type.length > 0 ? type : "image/png"));
            if (options.binary) {
                imageDef.set("bufferView", num(<f64>this.processBufferViewImage(base64Decode(url, comma + 1))));
            } else {
                imageDef.set("uri", Dynamic.fromString(url));
            }
        } else {
            if (map instanceof CompressedTexture) {
                this.warn("THREE.GLTFExporter: compressed textures are not written (no decompression).");
            } else {
                this.warn("THREE.GLTFExporter: textures without pixels in memory (Rive images, canvases, "
                    + "artboards, render targets, images not decoded yet) are not written.");
            }
            return -1;
        }
        const index = pushIndex(childArray(this.json, "images"), imageDef);
        const cached = new CachedImage();
        cached.data = pixels;
        cached.source = map.source;
        cached.key = key;
        cached.index = index;
        this.cacheImages.push(cached);
        return index;
    }

    private writeImageBytes(imageDef: Dynamic, bytes: Uint8Array, mimeType: string): void {
        if (this.options.binary) {
            imageDef.set("bufferView", num(<f64>this.processBufferViewImage(bytes)));
        } else {
            imageDef.set("uri", Dynamic.fromString("data:" + mimeType + ";base64," + base64Encode(bytes)));
        }
    }

    processSampler(map: Texture): i32 {
        const samplerDef = Dynamic.newTable();
        const magFilter = threeToWebGL(map.magFilter), minFilter = threeToWebGL(map.minFilter);
        const wrapS = threeToWebGL(map.wrapS), wrapT = threeToWebGL(map.wrapT);
        if (magFilter >= 0) samplerDef.set("magFilter", num(<f64>magFilter));
        if (minFilter >= 0) samplerDef.set("minFilter", num(<f64>minFilter));
        if (wrapS >= 0) samplerDef.set("wrapS", num(<f64>wrapS));
        if (wrapT >= 0) samplerDef.set("wrapT", num(<f64>wrapT));
        return pushIndex(childArray(this.json, "samplers"), samplerDef);
    }

    /// The texture's index (three.js's processTextureAsync); -1 when its
    /// image cannot be written.
    processTexture(map: Texture): i32 {
        if (this.cacheTextures.has(map.id)) return this.cacheTextures.get(map.id);
        let mimeType = asStr(jget(map.userData, "mimeType"));
        if (mimeType.length == 0 || mimeType == "image/webp") mimeType = "image/png";
        const source = this.processImage(map, map.format, map.flipY, mimeType);
        if (source < 0) {
            this.cacheTextures.set(map.id, -1);
            return -1;
        }
        const textureDef = Dynamic.newTable();
        textureDef.set("sampler", num(<f64>this.processSampler(map)));
        textureDef.set("source", num(<f64>source));
        if (map.name.length > 0) textureDef.set("name", Dynamic.fromString(map.name));
        for (let i = 0; i < this.plugins.length; i++) this.plugins[i].writeTexture(map, textureDef);
        const index = pushIndex(childArray(this.json, "textures"), textureDef);
        this.cacheTextures.set(map.id, index);
        return index;
    }

    // ------------------------------------------------------------ materials

    /// The material's index (three.js's processMaterialAsync); -1 for
    /// ShaderMaterials.
    processMaterial(material: Material): i32 {
        if (this.cacheMaterials.has(material.id)) return this.cacheMaterials.get(material.id);
        if (material instanceof ShaderMaterial) {
            this.warn("GLTFExporter: THREE.ShaderMaterial not supported.");
            return -1;
        }
        const materialDef = Dynamic.newTable();
        const pbr = Dynamic.newTable();
        materialDef.set("pbrMetallicRoughness", pbr);
        if (!(material instanceof MeshStandardMaterial) && !(material instanceof MeshBasicMaterial)) {
            this.warn("GLTFExporter: Use MeshStandardMaterial or MeshBasicMaterial for best results.");
        }
        const m = materialMembers(material);

        // pbrMetallicRoughness.baseColorFactor
        const c = m.color;
        const r = c != null ? c.r : 1, g = c != null ? c.g : 1, b = c != null ? c.b : 1;
        if (r != 1 || g != 1 || b != 1 || material.opacity != 1) {
            pbr.set("baseColorFactor", Dynamic.fromNumbers([r, g, b, material.opacity]));
        }
        if (material instanceof MeshStandardMaterial) {
            const s = material as MeshStandardMaterial;
            pbr.set("metallicFactor", num(s.metalness));
            pbr.set("roughnessFactor", num(s.roughness));
        } else {
            pbr.set("metallicFactor", num(0));
            pbr.set("roughnessFactor", num(1));
        }

        // pbrMetallicRoughness.metallicRoughnessTexture
        if (m.metalnessMap != null || m.roughnessMap != null) {
            const metalRoughTexture = this.buildMetalRoughTexture(m.metalnessMap, m.roughnessMap);
            const metalRoughMapDef = this.textureInfo(metalRoughTexture);
            if (metalRoughMapDef != null) pbr.set("metallicRoughnessTexture", metalRoughMapDef);
        }

        // pbrMetallicRoughness.baseColorTexture
        const baseColorMapDef = this.textureInfo(m.map);
        if (baseColorMapDef != null) pbr.set("baseColorTexture", baseColorMapDef);

        const emissive = m.emissive;
        if (emissive != null) {
            if (Math.max(emissive.r, Math.max(emissive.g, emissive.b)) > 0) {
                materialDef.set("emissiveFactor", colorArray(emissive));
            }
            const emissiveMapDef = this.textureInfo(m.emissiveMap);
            if (emissiveMapDef != null) materialDef.set("emissiveTexture", emissiveMapDef);
        }

        // normalTexture
        const normalMap = m.normalMap;
        if (normalMap != null) {
            const index = this.processTexture(normalMap);
            if (index >= 0) {
                const normalMapDef = Dynamic.newTable();
                normalMapDef.set("index", num(<f64>index));
                normalMapDef.set("texCoord", num(<f64>normalMap.channel));
                const normalScale = m.normalScale;
                if (normalScale != null && normalScale.x != 1) {
                    // glTF normal scale is univariate. Ignore `y`, which may be flipped.
                    normalMapDef.set("scale", num(normalScale.x));
                }
                this.applyTextureTransform(normalMapDef, normalMap);
                materialDef.set("normalTexture", normalMapDef);
            }
        }

        // occlusionTexture
        const aoMap = m.aoMap;
        if (aoMap != null) {
            const index = this.processTexture(aoMap);
            if (index >= 0) {
                const occlusionMapDef = Dynamic.newTable();
                occlusionMapDef.set("index", num(<f64>index));
                occlusionMapDef.set("texCoord", num(<f64>aoMap.channel));
                if (m.aoMapIntensity != 1.0) occlusionMapDef.set("strength", num(m.aoMapIntensity));
                this.applyTextureTransform(occlusionMapDef, aoMap);
                materialDef.set("occlusionTexture", occlusionMapDef);
            }
        }

        // alphaMode
        if (material.transparent) {
            materialDef.set("alphaMode", Dynamic.fromString("BLEND"));
        } else if (material.alphaTest > 0.0) {
            materialDef.set("alphaMode", Dynamic.fromString("MASK"));
            materialDef.set("alphaCutoff", num(material.alphaTest));
        }

        // doubleSided
        if (material.side == DoubleSide) materialDef.set("doubleSided", Dynamic.fromBool(true));
        if (material.name != "") materialDef.set("name", Dynamic.fromString(material.name));

        this.serializeUserData(material.userData, materialDef);

        for (let i = 0; i < this.plugins.length; i++) this.plugins[i].writeMaterial(material, materialDef);

        const index = pushIndex(childArray(this.json, "materials"), materialDef);
        this.cacheMaterials.set(material.id, index);
        return index;
    }

    // ------------------------------------------------------------ meshes

    /// The mesh's index (three.js's processMeshAsync), for a Mesh, Line or
    /// Points; -1 when there is nothing to write.
    processMesh(mesh: Object3D): i32 {
        const parts = meshParts(mesh);
        if (parts.geometry == null) return -1;
        const geometry = parts.geometry!;
        const materials = parts.materials;
        const isMultiMaterial = parts.isMultiMaterial;

        let meshCacheKey = geometry.id.toString();
        for (let i = 0; i < materials.length; i++) meshCacheKey += ":" + materials[i].id.toString();
        if (this.cacheMeshes.has(meshCacheKey)) return this.cacheMeshes.get(meshCacheKey);

        const mode = parts.mode;
        const meshDef = Dynamic.newTable();
        const attributes = Dynamic.newTable();
        const primitives = Dynamic.newTable();
        const targets = Dynamic.newTable();

        const originalNormal = geometry.getAttribute("normal");
        let normal: BufferAttribute? = originalNormal;
        if (originalNormal != null && !this.isNormalizedNormalAttribute(originalNormal)) {
            this.warn("THREE.GLTFExporter: Creating normalized normal attribute from the non-normalized one.");
            normal = this.createNormalizedNormalAttribute(originalNormal);
        }

        // For every attribute create an accessor.
        const names = geometry.attributes.keys();
        let attributeCount = 0;
        for (let n = 0; n < names.length; n++) {
            const threeName = names[n];
            // Ignore morph target attributes, which are exported later.
            if (threeName.startsWith("morph")) continue;
            let attribute = geometry.attributes.get(threeName);
            if (threeName == "normal" && normal != null) attribute = normal;
            let attributeName = gltfAttributeName(threeName);
            // Prefix all geometry attributes except the ones specifically
            // listed in the spec; non-spec attributes are considered custom.
            if (!isValidVertexAttribute(attributeName)) attributeName = "_" + attributeName;

            const uidKey = this.getUID(attribute).toString();
            if (this.cacheAttributes.has(uidKey)) {
                attributes.set(attributeName, num(<f64>this.cacheAttributes.get(uidKey)));
                attributeCount++;
                continue;
            }
            // JOINTS_0 must be UNSIGNED_BYTE or UNSIGNED_SHORT (attributes
            // are floats here: always converted).
            let accessor: i32;
            if (attributeName == "JOINTS_0") {
                accessor = this.processAccessorSource(AccessorSource.ofAttribute(attribute), UNSIGNED_SHORT,
                    ARRAY_BUFFER, 0, -1);
            } else {
                accessor = this.processAccessor(attribute, geometry);
            }
            if (accessor >= 0) {
                attributes.set(attributeName, num(<f64>accessor));
                attributeCount++;
                this.cacheAttributes.set(uidKey, accessor);
            }
        }

        // Skip if no exportable attributes found.
        if (attributeCount == 0) return -1;

        // Morph targets
        if (mesh instanceof Mesh && (mesh as Mesh).morphTargetInfluences.length > 0) {
            const m = mesh as Mesh;
            const weights: Array<f64> = [];
            const targetNames = Dynamic.newTable();
            const reverseDictionary = new Map<i32, string>();
            const dictionaryKeys = m.morphTargetDictionary.keys();
            for (let k = 0; k < dictionaryKeys.length; k++) {
                reverseDictionary.set(m.morphTargetDictionary.get(dictionaryKeys[k]), dictionaryKeys[k]);
            }
            const morphNames = geometry.morphAttributes.keys();
            for (let i = 0; i < m.morphTargetInfluences.length; ++i) {
                const target = Dynamic.newTable();
                let warned = false;
                for (let k = 0; k < morphNames.length; k++) {
                    const attributeName = morphNames[k];
                    // glTF 2.0 morph supports only POSITION/NORMAL/TANGENT.
                    // Three.js doesn't support TANGENT yet.
                    if (attributeName != "position" && attributeName != "normal") {
                        if (!warned) {
                            this.warn("GLTFExporter: Only POSITION and NORMAL morph are supported.");
                            warned = true;
                        }
                        continue;
                    }
                    const list = geometry.morphAttributes.get(attributeName);
                    if (i >= list.length) continue;
                    const attribute = list[i];
                    const gltfName = attributeName.toUpperCase();
                    // Three.js morph attribute has absolute values while the
                    // one of glTF has relative values.
                    const baseAttribute = geometry.getAttribute(attributeName);
                    const uidKey = this.getUID(attribute, true).toString();
                    if (this.cacheAttributes.has(uidKey)) {
                        target.set(gltfName, num(<f64>this.cacheAttributes.get(uidKey)));
                        continue;
                    }
                    // Clones attribute not to override.
                    const relativeAttribute = attribute.clone();
                    if (!geometry.morphTargetsRelative && baseAttribute != null) {
                        const a = relativeAttribute.array, base = baseAttribute.array;
                        const n = min<i32>(a.length, base.length);
                        for (let j = 0; j < n; j++) a[j] = a[j] - base[j];
                    }
                    const accessor = this.processAccessor(relativeAttribute, geometry);
                    if (accessor >= 0) {
                        target.set(gltfName, num(<f64>accessor));
                        this.cacheAttributes.set(uidKey, accessor);
                    }
                }
                targets.push(target);
                weights.push(m.morphTargetInfluences[i]);
                if (dictionaryKeys.length > 0) {
                    targetNames.push(Dynamic.fromString(reverseDictionary.has(i) ? reverseDictionary.get(i) : i.toString()));
                }
            }
            meshDef.set("weights", Dynamic.fromNumbers(weights));
            if (Dynamic.length(targetNames) > 0) {
                const extras = Dynamic.newTable();
                extras.set("targetNames", targetNames);
                meshDef.set("extras", extras);
            }
        }

        if (isMultiMaterial && geometry.groups.length == 0) return -1;

        let index = geometry.index;
        if (isMultiMaterial && index == null) {
            // Forced indices, as three.js (on a copy: the geometry is left as is).
            const position = geometry.getAttribute("position");
            const count = position != null ? position.count : 0;
            const indices = new Array<i32>(count);
            for (let i = 0; i < count; i++) indices[i] = i;
            index = new Uint32BufferAttribute(indices);
        }

        const groupCount = isMultiMaterial ? geometry.groups.length : 1;
        for (let i = 0; i < groupCount; i++) {
            const primitive = Dynamic.newTable();
            primitive.set("mode", num(<f64>mode));
            primitive.set("attributes", attributes);
            this.serializeUserData(geometry.userData, primitive);
            if (Dynamic.length(targets) > 0) primitive.set("targets", targets);

            let materialIndex = 0;
            if (index != null) {
                let cacheKey = this.getIndexUID(index).toString();
                let start = 0, count = -1;
                if (isMultiMaterial) {
                    const group = geometry.groups[i];
                    start = group.start;
                    count = group.count;
                    materialIndex = group.materialIndex;
                    cacheKey += ":" + start.toString() + ":" + count.toString();
                }
                let indices: i32;
                if (this.cacheAttributes.has(cacheKey)) {
                    indices = this.cacheAttributes.get(cacheKey);
                } else {
                    indices = this.processIndexAccessor(index, start, count);
                    this.cacheAttributes.set(cacheKey, indices);
                }
                if (indices >= 0) primitive.set("indices", num(<f64>indices));
            }

            if (materialIndex >= 0 && materialIndex < materials.length) {
                const material = this.processMaterial(materials[materialIndex]);
                if (material >= 0) primitive.set("material", num(<f64>material));
            }
            primitives.push(primitive);
        }

        meshDef.set("primitives", primitives);

        for (let i = 0; i < this.plugins.length; i++) this.plugins[i].writeMesh(mesh, meshDef);

        const meshIndex = pushIndex(childArray(this.json, "meshes"), meshDef);
        this.cacheMeshes.set(meshCacheKey, meshIndex);
        return meshIndex;
    }

    // ------------------------------------------------------------ cameras

    processCamera(camera: Camera): i32 {
        const cameraDef = Dynamic.newTable();
        if (camera instanceof OrthographicCamera) {
            const o = camera as OrthographicCamera;
            cameraDef.set("type", Dynamic.fromString("orthographic"));
            const def = Dynamic.newTable();
            def.set("xmag", num((o.right - o.left) / 2));
            def.set("ymag", num((o.top - o.bottom) / 2));
            def.set("zfar", num(o.far <= 0 ? 0.001 : o.far));
            def.set("znear", num(o.near < 0 ? 0 : o.near));
            cameraDef.set("orthographic", def);
        } else {
            cameraDef.set("type", Dynamic.fromString("perspective"));
            const def = Dynamic.newTable();
            if (camera instanceof PerspectiveCamera) {
                const p = camera as PerspectiveCamera;
                def.set("aspectRatio", num(p.aspect));
                def.set("yfov", num(p.fov * Math.PI / 180));
                def.set("zfar", num(p.far <= 0 ? 0.001 : p.far));
                def.set("znear", num(p.near < 0 ? 0 : p.near));
            }
            cameraDef.set("perspective", def);
        }
        if (camera.name != "") cameraDef.set("name", Dynamic.fromString(camera.name));
        return pushIndex(childArray(this.json, "cameras"), cameraDef);
    }

    // ------------------------------------------------------------ animations, skins

    /// Writes `clip` as a glTF animation of the nodes under `root`; its
    /// index, or -1.
    processAnimation(clip: AnimationClip, root: Object3D): i32 {
        const animations = childArray(this.json, "animations");
        clip = GLTFExporter.Utils.mergeMorphTargetTracks(cloneClip(clip), root, this);
        const tracks = clip.tracks;
        const channels = Dynamic.newTable();
        const samplers = Dynamic.newTable();
        for (let i = 0; i < tracks.length; ++i) {
            const track = tracks[i];
            const trackBinding = PropertyBinding.parseTrackName(track.name);
            let trackNode = PropertyBinding.findNode(root, trackBinding.nodeName);
            const trackProperty = pathProperty(trackBinding.propertyName);
            if (trackBinding.objectName == "bones") {
                if (trackNode != null && trackNode instanceof SkinnedMesh && (trackNode as SkinnedMesh).skeleton != null) {
                    trackNode = (trackNode as SkinnedMesh).skeleton!.getBoneByName(trackBinding.objectIndex);
                } else {
                    trackNode = null;
                }
            }
            if (trackNode == null || trackProperty == "" || !this.nodeMap.has(trackNode.id)
                || (trackProperty == "weights" && !(trackNode instanceof Mesh))) {
                this.warn("THREE.GLTFExporter: Could not export animation track \"" + track.name + "\".");
                continue;
            }
            const inputItemSize = 1;
            let outputItemSize = track.times.length > 0 ? track.values.length / track.times.length : 0;
            if (trackProperty == "weights") {
                outputItemSize /= max<i32>(1, (trackNode as Mesh).morphTargetInfluences.length);
            }
            let interpolation: string;
            // @TODO export CubicInterpolant(InterpolateSmooth) as CUBICSPLINE
            if (track.getInterpolation() == InterpolateGLTFCubicSpline) {
                interpolation = "CUBICSPLINE";
                // itemSize of CUBICSPLINE keyframe is 9 (VEC3 * 3: inTangent,
                // splineVertex, and outTangent) but needs to be stored as VEC3.
                outputItemSize /= 3;
            } else if (track.getInterpolation() == InterpolateDiscrete) {
                interpolation = "STEP";
            } else {
                interpolation = "LINEAR";
            }
            if (outputItemSize <= 0) {
                this.warn("THREE.GLTFExporter: Could not export animation track \"" + track.name + "\".");
                continue;
            }
            const samplerDef = Dynamic.newTable();
            samplerDef.set("input", num(<f64>this.processAccessor(new BufferAttribute(track.times, inputItemSize))));
            samplerDef.set("output", num(<f64>this.processAccessor(new BufferAttribute(track.values, outputItemSize))));
            samplerDef.set("interpolation", Dynamic.fromString(interpolation));
            const sampler = pushIndex(samplers, samplerDef);
            const target = Dynamic.newTable();
            target.set("node", num(<f64>this.nodeMap.get(trackNode.id)));
            target.set("path", Dynamic.fromString(trackProperty));
            const channel = Dynamic.newTable();
            channel.set("sampler", num(<f64>sampler));
            channel.set("target", target);
            channels.push(channel);
        }
        const animation = Dynamic.newTable();
        animation.set("name", Dynamic.fromString(clip.name != "" ? clip.name : "clip_" + (<i32>Dynamic.length(animations)).toString()));
        animation.set("samplers", samplers);
        animation.set("channels", channels);
        return pushIndex(animations, animation);
    }

    processSkin(object: SkinnedMesh): i32 {
        if (!this.nodeMap.has(object.id)) return -1;
        const node = Dynamic.at(jget(this.json, "nodes"), this.nodeMap.get(object.id));
        const skeleton = object.skeleton;
        if (skeleton == null || node == null) return -1;
        if (skeleton.bones.length == 0) return -1;
        const rootJoint = skeleton.bones[0];
        const joints = Dynamic.newTable();
        const inverseBindMatrices = new Float32Array(skeleton.bones.length * 16);
        const temporaryBoneInverse = new Matrix4();
        for (let i = 0; i < skeleton.bones.length; ++i) {
            const bone = skeleton.bones[i];
            joints.push(this.nodeMap.has(bone.id) ? num(<f64>this.nodeMap.get(bone.id)) : null);
            if (i < skeleton.boneInverses.length) temporaryBoneInverse.copy(skeleton.boneInverses[i]);
            else temporaryBoneInverse.identity();
            temporaryBoneInverse.multiply(object.bindMatrix);
            const e = temporaryBoneInverse.elements;
            for (let k = 0; k < 16; k++) inverseBindMatrices[i * 16 + k] = e[k];
        }
        const skinDef = Dynamic.newTable();
        skinDef.set("inverseBindMatrices", num(<f64>this.processAccessor(new BufferAttribute(inverseBindMatrices, 16))));
        skinDef.set("joints", joints);
        if (this.nodeMap.has(rootJoint.id)) skinDef.set("skeleton", num(<f64>this.nodeMap.get(rootJoint.id)));
        const skinIndex = pushIndex(childArray(this.json, "skins"), skinDef);
        node.set("skin", num(<f64>skinIndex));
        return skinIndex;
    }

    // ------------------------------------------------------------ nodes, scenes

    /// The node's index (three.js's processNodeAsync).
    processNode(object: Object3D): i32 {
        const options = this.options;
        const nodeDef = Dynamic.newTable();
        if (options.trs) {
            const q = object.quaternion, p = object.position, s = object.scale;
            if (q.x != 0 || q.y != 0 || q.z != 0 || q.w != 1) nodeDef.set("rotation", Dynamic.fromNumbers([q.x, q.y, q.z, q.w]));
            if (p.x != 0 || p.y != 0 || p.z != 0) nodeDef.set("translation", Dynamic.fromNumbers([p.x, p.y, p.z]));
            if (s.x != 1 || s.y != 1 || s.z != 1) nodeDef.set("scale", Dynamic.fromNumbers([s.x, s.y, s.z]));
        } else {
            if (object.matrixAutoUpdate) object.updateMatrix();
            if (!isIdentityMatrix(object.matrix)) {
                const e = object.matrix.elements;
                const values = new Array<f64>(16);
                for (let i = 0; i < 16; i++) values[i] = f32Number(e[i]);
                nodeDef.set("matrix", Dynamic.fromNumbers(values));
            }
        }
        // We don't export empty strings name because it represents no-name in Three.js.
        if (object.name != "") nodeDef.set("name", Dynamic.fromString(object.name));
        this.serializeUserData(object.userData, nodeDef);

        if (object instanceof Mesh || object instanceof Line || object instanceof Points) {
            const meshIndex = this.processMesh(object);
            if (meshIndex >= 0) nodeDef.set("mesh", num(<f64>meshIndex));
        } else if (object instanceof Camera) {
            nodeDef.set("camera", num(<f64>this.processCamera(object as Camera)));
        }

        if (object instanceof SkinnedMesh) this.skins.push(object as SkinnedMesh);

        if (object.children.length > 0) {
            const children = Dynamic.newTable();
            for (let i = 0; i < object.children.length; i++) {
                const c = object.children[i];
                if (c.visible || !options.onlyVisible) {
                    const nodeIndex = this.processNode(c);
                    if (nodeIndex >= 0) children.push(num(<f64>nodeIndex));
                }
            }
            if (Dynamic.length(children) > 0) nodeDef.set("children", children);
        }

        for (let i = 0; i < this.plugins.length; i++) this.plugins[i].writeNode(object, nodeDef);

        const nodeIndex = pushIndex(childArray(this.json, "nodes"), asObject(nodeDef));
        this.nodeMap.set(object.id, nodeIndex);
        return nodeIndex;
    }

    processScene(scene: Object3D): void {
        const json = this.json;
        const options = this.options;
        if (jget(json, "scenes") == null) {
            json.set("scenes", Dynamic.newTable());
            json.set("scene", num(0));
        }
        const sceneDef = Dynamic.newTable();
        if (scene.name != "") sceneDef.set("name", Dynamic.fromString(scene.name));
        const scenes = childArray(json, "scenes");
        const sceneIndex = pushIndex(scenes, sceneDef);
        const nodes = Dynamic.newTable();
        for (let i = 0; i < scene.children.length; i++) {
            const c = scene.children[i];
            if (c.visible || !options.onlyVisible) {
                const nodeIndex = this.processNode(c);
                if (nodeIndex >= 0) nodes.push(num(<f64>nodeIndex));
            }
        }
        if (Dynamic.length(nodes) > 0) sceneDef.set("nodes", nodes);
        this.serializeUserData(scene.userData, sceneDef);
        scenes.setAt(sceneIndex, asObject(sceneDef));
    }

    /// Objects without a scene go in one named "AuxScene" (their parents
    /// are left as they are).
    processObjects(objects: Array<Object3D>): void {
        const scene = new Scene();
        scene.name = "AuxScene";
        for (let i = 0; i < objects.length; i++) {
            // We push directly to children instead of calling `add` to
            // prevent modifying the .parent and break its original scene
            // and hierarchy.
            scene.children.push(objects[i]);
        }
        this.processScene(scene);
        scene.children = [];
    }

    processInput(input: Array<Object3D>): void {
        const options = this.options;
        for (let i = 0; i < this.plugins.length; i++) this.plugins[i].beforeParse(input);
        const objectsWithoutScene: Array<Object3D> = [];
        for (let i = 0; i < input.length; i++) {
            if (input[i] instanceof Scene) this.processScene(input[i]);
            else objectsWithoutScene.push(input[i]);
        }
        if (objectsWithoutScene.length > 0) this.processObjects(objectsWithoutScene);
        for (let i = 0; i < this.skins.length; ++i) this.processSkin(this.skins[i]);
        if (input.length > 0) {
            for (let i = 0; i < options.animations.length; ++i) this.processAnimation(options.animations[i], input[0]);
        }
        for (let i = 0; i < this.plugins.length; i++) this.plugins[i].afterParse(input);
    }
}

function accessorType(itemSize: i32): string {
    if (itemSize == 2) return "VEC2";
    if (itemSize == 3) return "VEC3";
    if (itemSize == 4) return "VEC4";
    if (itemSize == 9) return "MAT3";
    if (itemSize == 16) return "MAT4";
    return "SCALAR";
}

/// nameConversion, else the name in capitals.
function gltfAttributeName(name: string): string {
    if (name == "uv") return "TEXCOORD_0";
    if (name == "uv1") return "TEXCOORD_1";
    if (name == "uv2") return "TEXCOORD_2";
    if (name == "uv3") return "TEXCOORD_3";
    if (name == "color") return "COLOR_0";
    if (name == "skinWeight") return "WEIGHTS_0";
    if (name == "skinIndex") return "JOINTS_0";
    return name.toUpperCase();
}

/// /^(POSITION|NORMAL|TANGENT|TEXCOORD_\d+|COLOR_\d+|JOINTS_\d+|WEIGHTS_\d+)$/
function isValidVertexAttribute(name: string): bool {
    if (name == "POSITION" || name == "NORMAL" || name == "TANGENT") return true;
    const prefixes: StaticArray<string> = ["TEXCOORD_", "COLOR_", "JOINTS_", "WEIGHTS_"];
    for (let p = 0; p < prefixes.length; p++) {
        const prefix = prefixes[p];
        if (!name.startsWith(prefix) || name.length == prefix.length) continue;
        let digits = true;
        for (let i = prefix.length; i < name.length; i++) {
            const c = name.charCodeAt(i);
            if (c < 48 || c > 57) digits = false;
        }
        if (digits) return true;
    }
    return false;
}

/// A DataTexture's RGBA8 pixels, or null.
function rgba8Of(map: Texture?): DataTexture? {
    if (map == null || !(map instanceof DataTexture)) return null;
    const dt = map as DataTexture;
    if (dt.format != RGBAFormat || !(dt.data instanceof Uint8Array) || dt.dataWidth == 0 || dt.dataHeight == 0) return null;
    if (dt.data.byteLength < <i32>(dt.dataWidth * dt.dataHeight * 4)) return null;
    return dt;
}

/// Channel `channel` of `source`, scaled (nearest) to width x height,
/// honouring `source.flipY` and `source.premultiplyAlpha`, and converted
/// from sRGB when `srgb`, into `composite`.
function copyChannel(source: DataTexture, srgb: bool, channel: i32, composite: Uint8Array, width: u32, height: u32): void {
    const data = source.data as Uint8Array;
    const sw = <i32>source.dataWidth, sh = <i32>source.dataHeight;
    const flipY = source.flipY;
    const premul = source.premultiplyAlpha;
    for (let y = 0; y < <i32>height; y++) {
        let sy = min<i32>(sh - 1, <i32>(<f64>y * <f64>sh / <f64>height));
        if (flipY) sy = sh - 1 - sy;
        for (let x = 0; x < <i32>width; x++) {
            const sx = min<i32>(sw - 1, <i32>(<f64>x * <f64>sw / <f64>width));
            const idx = (sy * sw + sx) * 4;
            let raw = <u32>data[idx + channel];
            if (premul) {
                const a = <u32>data[idx + 3];
                if (a > 0 && a < 255) raw = min<u32>(255, (raw * 255 + a / 2) / a);
            }
            let c = <f64>raw / 255.0;
            if (srgb) c = c < 0.04045 ? c * 0.0773993808 : Math.pow(c * 0.9478672986 + 0.0521327014, 2.4);
            composite[(y * <i32>width + x) * 4 + channel] = <u8>min<i32>(255, <i32>Math.round(c * 255.0));
        }
    }
}

/// Wrapping, filters, uv transform and channel of `from` (three.js clones
/// the texture).
function copySampling(from: Texture, to: Texture): void {
    to.name = from.name;
    to.wrapS = from.wrapS;
    to.wrapT = from.wrapT;
    to.magFilter = from.magFilter;
    to.minFilter = from.minFilter;
    to.offset.copy(from.offset);
    to.repeat.copy(from.repeat);
    to.center.copy(from.center);
    to.rotation = from.rotation;
    to.channel = from.channel;
}

/// RGBA8 pixels scaled (nearest) to w x h.
function resample(data: Uint8Array, width: i32, height: i32, w: i32, h: i32): Uint8Array {
    const out = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
        const sy = min<i32>(height - 1, <i32>(<f64>y * <f64>height / <f64>h));
        for (let x = 0; x < w; x++) {
            const sx = min<i32>(width - 1, <i32>(<f64>x * <f64>width / <f64>w));
            const s = (sy * width + sx) * 4, o = (y * w + x) * 4;
            out[o] = data[s]; out[o + 1] = data[s + 1]; out[o + 2] = data[s + 2]; out[o + 3] = data[s + 3];
        }
    }
    return out;
}

function cloneTrack(track: KeyframeTrack): KeyframeTrack {
    const t = new KeyframeTrack(track.name, [], [], track.interpolation);
    t.times = track.times.slice();
    t.values = track.values.slice();
    t.ValueTypeName = track.ValueTypeName;
    return t;
}

function cloneClip(clip: AnimationClip): AnimationClip {
    const tracks: Array<KeyframeTrack> = [];
    for (let i = 0; i < clip.tracks.length; i++) tracks.push(cloneTrack(clip.tracks[i]));
    return new AnimationClip(clip.name, clip.duration, tracks, clip.blendMode);
}

// ----------------------------------------------------------------- utils

/// three.js's GLTFExporter.Utils.
export class GLTFExporterUtils {
    /// Adds a key at `time` (the track's value there) unless one is within
    /// 1 ms; returns the key's index.
    insertKeyframe(track: KeyframeTrack, time: f64): i32 {
        if (!isFinite(time)) return -1;
        const tolerance = 0.001;   // 1ms
        const valueSize = track.getValueSize();
        const n = track.times.length;
        for (let i = 0; i < n; i++) {
            if (Math.abs(<f64>track.times[i] - time) < tolerance) return i;
        }
        let index = n;
        for (let i = 0; i < n; i++) {
            if (<f64>track.times[i] > time) {
                index = i;
                break;
            }
        }
        const times = new Float32Array(n + 1);
        const values = new Float32Array(track.values.length + valueSize);
        const value = new Float64Array(max<i32>(valueSize, 1));
        if (n > 0) {
            track.evaluate(time, value);
            if (index > 0) {
                times.set(track.times.subarray(0, index), 0);
                values.set(track.values.subarray(0, index * valueSize), 0);
            }
            if (index < n) {
                times.set(track.times.subarray(index), index + 1);
                values.set(track.values.subarray(index * valueSize), (index + 1) * valueSize);
            }
        }
        times[index] = <f32>time;
        for (let k = 0; k < valueSize; k++) values[index * valueSize + k] = <f32>value[k];
        track.times = times;
        track.values = values;
        return index;
    }

    /// Per-target morph tracks ("mesh.morphTargetInfluences[name or i]")
    /// merged into one weights track per mesh, as glTF animates them;
    /// `clip` is changed and returned. Warnings go to `writer` when given
    /// (three.js throws on CUBICSPLINE and unknown target names: such
    /// tracks are skipped here).
    mergeMorphTargetTracks(clip: AnimationClip, root: Object3D, writer: GLTFWriter? = null): AnimationClip {
        const tracks: Array<KeyframeTrack> = [];
        const mergedTracks = new Map<string, KeyframeTrack>();
        const sourceTracks = clip.tracks;
        for (let i = 0; i < sourceTracks.length; ++i) {
            let sourceTrack = sourceTracks[i];
            const sourceTrackBinding = PropertyBinding.parseTrackName(sourceTrack.name);
            const sourceTrackNode = PropertyBinding.findNode(root, sourceTrackBinding.nodeName);
            if (sourceTrackBinding.propertyName != "morphTargetInfluences" || sourceTrackBinding.propertyIndex == "") {
                // Tracks that don't affect morph targets, or that affect all
                // morph targets together, can be left as-is.
                tracks.push(sourceTrack);
                continue;
            }
            const interpolation = sourceTrack.getInterpolation();
            if (interpolation != InterpolateDiscrete && interpolation != InterpolateLinear) {
                if (interpolation == InterpolateGLTFCubicSpline) {
                    // This should never happen, because glTF morph target
                    // animations affect all targets already.
                    warnTo(writer, "THREE.GLTFExporter: Cannot merge tracks with glTF CUBICSPLINE interpolation.");
                    continue;
                }
                warnTo(writer, "THREE.GLTFExporter: Morph target interpolation mode not yet supported. Using LINEAR instead.");
                sourceTrack = cloneTrack(sourceTrack);
                sourceTrack.setInterpolation(InterpolateLinear);
            }
            if (sourceTrackNode == null || !(sourceTrackNode instanceof Mesh)) {
                tracks.push(sourceTrack);   // reported by processAnimation
                continue;
            }
            const mesh = sourceTrackNode as Mesh;
            const targetCount = mesh.morphTargetInfluences.length;
            const name = sourceTrackBinding.propertyIndex;
            let targetIndex = -1;
            if (mesh.morphTargetDictionary.has(name)) targetIndex = mesh.morphTargetDictionary.get(name);
            else if (isIndex(name)) targetIndex = I32.parseInt(name);
            if (targetIndex < 0 || targetIndex >= targetCount) {
                warnTo(writer, "THREE.GLTFExporter: Morph target name not found: " + name);
                continue;
            }
            const key = mesh.uuid;
            // If this is the first time we've seen this object, create a new
            // track to store merged keyframe data for each morph target.
            if (!mergedTracks.has(key)) {
                const mergedTrack = cloneTrack(sourceTrack);
                const values = new Float32Array(targetCount * mergedTrack.times.length);
                for (let j = 0; j < mergedTrack.times.length; j++) {
                    values[j * targetCount + targetIndex] = mergedTrack.values[j];
                }
                // We need to take into consideration the intended target node
                // of our original un-merged morphTarget animation.
                mergedTrack.name = sourceTrackBinding.nodeName + ".morphTargetInfluences";
                mergedTrack.values = values;
                mergedTracks.set(key, mergedTrack);
                tracks.push(mergedTrack);
                continue;
            }
            const mergedTrack = mergedTracks.get(key);
            const value = new Float64Array(1);
            // For every existing keyframe of the merged track, write a
            // (possibly interpolated) value from the source track.
            for (let j = 0; j < mergedTrack.times.length; j++) {
                sourceTrack.evaluate(<f64>mergedTrack.times[j], value);
                mergedTrack.values[j * targetCount + targetIndex] = <f32>value[0];
            }
            // For every existing keyframe of the source track, write a
            // (possibly new) keyframe to the merged track. Values from the
            // previous loop may be written again, but keyframes are
            // de-duplicated.
            for (let j = 0; j < sourceTrack.times.length; j++) {
                const keyframeIndex = this.insertKeyframe(mergedTrack, <f64>sourceTrack.times[j]);
                if (keyframeIndex >= 0) mergedTrack.values[keyframeIndex * targetCount + targetIndex] = sourceTrack.values[j];
            }
        }
        clip.tracks = tracks;
        return clip;
    }
}

function warnTo(writer: GLTFWriter?, message: string): void {
    if (writer != null) writer.warn(message);
}

function isIndex(s: string): bool {
    if (s.length == 0) return false;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) return false;
    }
    return true;
}

// ----------------------------------------------------------------- plugins

/// KHR_lights_punctual.
class GLTFLightExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_lights_punctual";
    }

    override writeNode(object: Object3D, nodeDef: Dynamic): void {
        if (!(object instanceof Light)) return;
        const writer = this.writer!;
        const light = object as Light;
        if (!(light instanceof DirectionalLight) && !(light instanceof PointLight) && !(light instanceof SpotLight)) {
            writer.warn("THREE.GLTFExporter: Only directional, point, and spot lights are supported.");
            return;
        }
        const json = writer.json;
        const lightDef = Dynamic.newTable();
        if (light.name != "") lightDef.set("name", Dynamic.fromString(light.name));
        lightDef.set("color", colorArray(light.color));
        lightDef.set("intensity", num(light.intensity));
        let decay: f64 = 2;
        let target: Object3D? = null;
        if (light instanceof DirectionalLight) {
            lightDef.set("type", Dynamic.fromString("directional"));
            target = (light as DirectionalLight).target;
        } else if (light instanceof PointLight) {
            const p = light as PointLight;
            lightDef.set("type", Dynamic.fromString("point"));
            if (p.distance > 0) lightDef.set("range", num(p.distance));
            decay = p.decay;
        } else {
            const s = light as SpotLight;
            lightDef.set("type", Dynamic.fromString("spot"));
            if (s.distance > 0) lightDef.set("range", num(s.distance));
            const spot = Dynamic.newTable();
            spot.set("innerConeAngle", num((1.0 - s.penumbra) * s.angle));
            spot.set("outerConeAngle", num(s.angle));
            lightDef.set("spot", spot);
            decay = s.decay;
            target = s.target;
        }
        if (decay != 2) {
            writer.warn("THREE.GLTFExporter: Light decay may be lost. glTF is physically-based, "
                + "and expects light.decay=2.");
        }
        if (target != null && (target.parent !== light || target.position.x != 0 || target.position.y != 0
            || target.position.z != -1)) {
            writer.warn("THREE.GLTFExporter: Light direction may be lost. For best results, "
                + "make light.target a child of the light with position 0,0,-1.");
        }
        if (!writer.extensionsUsed.has(this.name)) {
            const lightsDef = Dynamic.newTable();
            lightsDef.set("lights", Dynamic.newTable());
            childObject(json, "extensions").set(this.name, lightsDef);
            writer.extensionsUsed.set(this.name, true);
        }
        const lights = childArray(childObject(childObject(json, "extensions"), this.name), "lights");
        const index = pushIndex(lights, lightDef);
        const ref = Dynamic.newTable();
        ref.set("light", num(<f64>index));
        childObject(nodeDef, "extensions").set(this.name, ref);
    }
}

/// KHR_materials_unlit, for MeshBasicMaterial.
class GLTFMaterialsUnlitExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_unlit";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshBasicMaterial)) return;
        const writer = this.writer!;
        childObject(materialDef, "extensions").set(this.name, emptyObject());
        writer.extensionsUsed.set(this.name, true);
        const pbr = childObject(materialDef, "pbrMetallicRoughness");
        pbr.set("metallicFactor", num(0.0));
        pbr.set("roughnessFactor", num(0.9));
    }
}

/// Sets materialDef.extensions[name] and marks it used.
function setMaterialExtension(writer: GLTFWriter, materialDef: Dynamic, name: string, extensionDef: Dynamic): void {
    childObject(materialDef, "extensions").set(name, extensionDef);
    writer.extensionsUsed.set(name, true);
}

/// KHR_materials_clearcoat.
class GLTFMaterialsClearcoatExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_clearcoat";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.clearcoat == 0) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("clearcoatFactor", num(m.clearcoat));
        const clearcoatMapDef = writer.textureInfo(m.clearcoatMap);
        if (clearcoatMapDef != null) extensionDef.set("clearcoatTexture", clearcoatMapDef);
        extensionDef.set("clearcoatRoughnessFactor", num(m.clearcoatRoughness));
        const clearcoatRoughnessMapDef = writer.textureInfo(m.clearcoatRoughnessMap);
        if (clearcoatRoughnessMapDef != null) extensionDef.set("clearcoatRoughnessTexture", clearcoatRoughnessMapDef);
        const normalMap = m.clearcoatNormalMap;
        if (normalMap != null) {
            const index = writer.processTexture(normalMap);
            if (index >= 0) {
                const clearcoatNormalMapDef = Dynamic.newTable();
                clearcoatNormalMapDef.set("index", num(<f64>index));
                clearcoatNormalMapDef.set("texCoord", num(<f64>normalMap.channel));
                if (m.clearcoatNormalScale.x != 1) clearcoatNormalMapDef.set("scale", num(m.clearcoatNormalScale.x));
                writer.applyTextureTransform(clearcoatNormalMapDef, normalMap);
                extensionDef.set("clearcoatNormalTexture", clearcoatNormalMapDef);
            }
        }
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_dispersion.
class GLTFMaterialsDispersionExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_dispersion";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.dispersion == 0) return;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("dispersion", num(m.dispersion));
        setMaterialExtension(this.writer!, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_iridescence.
class GLTFMaterialsIridescenceExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_iridescence";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.iridescence == 0) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("iridescenceFactor", num(m.iridescence));
        const iridescenceMapDef = writer.textureInfo(m.iridescenceMap);
        if (iridescenceMapDef != null) extensionDef.set("iridescenceTexture", iridescenceMapDef);
        extensionDef.set("iridescenceIor", num(m.iridescenceIOR));
        extensionDef.set("iridescenceThicknessMinimum", num(m.iridescenceThicknessRange[0]));
        extensionDef.set("iridescenceThicknessMaximum", num(m.iridescenceThicknessRange[1]));
        const thicknessMapDef = writer.textureInfo(m.iridescenceThicknessMap);
        if (thicknessMapDef != null) extensionDef.set("iridescenceThicknessTexture", thicknessMapDef);
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_transmission.
class GLTFMaterialsTransmissionExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_transmission";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.transmission == 0) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("transmissionFactor", num(m.transmission));
        const transmissionMapDef = writer.textureInfo(m.transmissionMap);
        if (transmissionMapDef != null) extensionDef.set("transmissionTexture", transmissionMapDef);
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_volume (with transmission).
class GLTFMaterialsVolumeExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_volume";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.transmission == 0) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("thicknessFactor", num(m.thickness));
        const thicknessMapDef = writer.textureInfo(m.thicknessMap);
        if (thicknessMapDef != null) extensionDef.set("thicknessTexture", thicknessMapDef);
        if (m.attenuationDistance != Infinity) extensionDef.set("attenuationDistance", num(m.attenuationDistance));
        extensionDef.set("attenuationColor", colorArray(m.attenuationColor));
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_ior.
class GLTFMaterialsIorExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_ior";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.ior == 1.5) return;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("ior", num(m.ior));
        setMaterialExtension(this.writer!, materialDef, this.name, extensionDef);
    }
}

const DEFAULT_SPECULAR_COLOR = new Color(1, 1, 1);

/// KHR_materials_specular.
class GLTFMaterialsSpecularExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_specular";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.specularIntensity == 1.0 && m.specularColor.equals(DEFAULT_SPECULAR_COLOR)
            && m.specularIntensityMap == null && m.specularColorMap == null) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        const specularIntensityMapDef = writer.textureInfo(m.specularIntensityMap);
        if (specularIntensityMapDef != null) extensionDef.set("specularTexture", specularIntensityMapDef);
        const specularColorMapDef = writer.textureInfo(m.specularColorMap);
        if (specularColorMapDef != null) extensionDef.set("specularColorTexture", specularColorMapDef);
        extensionDef.set("specularFactor", num(m.specularIntensity));
        extensionDef.set("specularColorFactor", colorArray(m.specularColor));
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_sheen.
class GLTFMaterialsSheenExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_sheen";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.sheen == 0.0) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        const sheenRoughnessMapDef = writer.textureInfo(m.sheenRoughnessMap);
        if (sheenRoughnessMapDef != null) extensionDef.set("sheenRoughnessTexture", sheenRoughnessMapDef);
        const sheenColorMapDef = writer.textureInfo(m.sheenColorMap);
        if (sheenColorMapDef != null) extensionDef.set("sheenColorTexture", sheenColorMapDef);
        extensionDef.set("sheenRoughnessFactor", num(m.sheenRoughness));
        extensionDef.set("sheenColorFactor", colorArray(m.sheenColor));
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_anisotropy.
class GLTFMaterialsAnisotropyExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_anisotropy";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshPhysicalMaterial)) return;
        const m = material as MeshPhysicalMaterial;
        if (m.anisotropy == 0.0) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        const anisotropyMapDef = writer.textureInfo(m.anisotropyMap, false);
        if (anisotropyMapDef != null) extensionDef.set("anisotropyTexture", anisotropyMapDef);
        extensionDef.set("anisotropyStrength", num(m.anisotropy));
        extensionDef.set("anisotropyRotation", num(m.anisotropyRotation));
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// KHR_materials_emissive_strength.
class GLTFMaterialsEmissiveStrengthExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "KHR_materials_emissive_strength";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshStandardMaterial)) return;
        const m = material as MeshStandardMaterial;
        if (m.emissiveIntensity == 1.0) return;
        const extensionDef = Dynamic.newTable();
        extensionDef.set("emissiveStrength", num(m.emissiveIntensity));
        setMaterialExtension(this.writer!, materialDef, this.name, extensionDef);
    }
}

/// EXT_materials_bump.
class GLTFMaterialsBumpExtension extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "EXT_materials_bump";
    }

    override writeMaterial(material: Material, materialDef: Dynamic): void {
        if (!(material instanceof MeshStandardMaterial)) return;
        const m = material as MeshStandardMaterial;
        if (m.bumpScale == 1 && m.bumpMap == null) return;
        const writer = this.writer!;
        const extensionDef = Dynamic.newTable();
        const bumpMapDef = writer.textureInfo(m.bumpMap);
        if (bumpMapDef != null) extensionDef.set("bumpTexture", bumpMapDef);
        extensionDef.set("bumpFactor", num(m.bumpScale));
        setMaterialExtension(writer, materialDef, this.name, extensionDef);
    }
}

/// EXT_mesh_gpu_instancing, for InstancedMesh.
class GLTFMeshGpuInstancing extends GLTFExporterPlugin {
    constructor() {
        super();
        this.name = "EXT_mesh_gpu_instancing";
    }

    override writeNode(object: Object3D, nodeDef: Dynamic): void {
        if (!(object instanceof InstancedMesh)) return;
        const writer = this.writer!;
        const mesh = object as InstancedMesh;
        const translationAttr = new Float32Array(mesh.count * 3);
        const rotationAttr = new Float32Array(mesh.count * 4);
        const scaleAttr = new Float32Array(mesh.count * 3);
        const matrix = new Matrix4();
        const position = new Vector3();
        const quaternion = new Quaternion();
        const scale = new Vector3();
        for (let i = 0; i < mesh.count; i++) {
            mesh.getMatrixAt(i, matrix);
            matrix.decompose(position, quaternion, scale);
            translationAttr[i * 3] = <f32>position.x;
            translationAttr[i * 3 + 1] = <f32>position.y;
            translationAttr[i * 3 + 2] = <f32>position.z;
            rotationAttr[i * 4] = <f32>quaternion.x;
            rotationAttr[i * 4 + 1] = <f32>quaternion.y;
            rotationAttr[i * 4 + 2] = <f32>quaternion.z;
            rotationAttr[i * 4 + 3] = <f32>quaternion.w;
            scaleAttr[i * 3] = <f32>scale.x;
            scaleAttr[i * 3 + 1] = <f32>scale.y;
            scaleAttr[i * 3 + 2] = <f32>scale.z;
        }
        const attributes = Dynamic.newTable();
        attributes.set("TRANSLATION", num(<f64>writer.processAccessor(new BufferAttribute(translationAttr, 3))));
        attributes.set("ROTATION", num(<f64>writer.processAccessor(new BufferAttribute(rotationAttr, 4))));
        attributes.set("SCALE", num(<f64>writer.processAccessor(new BufferAttribute(scaleAttr, 3))));
        const instanceColor = mesh.instanceColor;
        if (instanceColor != null) {
            // The drawn instances' colours (three.js writes the whole attribute).
            attributes.set("_COLOR_0", num(<f64>writer.processAccessor(instanceColor, null, 0, mesh.count)));
        }
        const extension = Dynamic.newTable();
        extension.set("attributes", attributes);
        childObject(nodeDef, "extensions").set(this.name, extension);
        writer.extensionsUsed.set(this.name, true);
        writer.extensionsRequired.set(this.name, true);
    }
}

// ----------------------------------------------------------------- PNG, base64

let crcTable: StaticArray<u32>? = null;

function crc32(b: Uint8Array, start: i32, end: i32): u32 {
    let table = crcTable;
    if (table == null) {
        const t = new StaticArray<u32>(256);
        for (let n: u32 = 0; n < 256; n++) {
            let c = n;
            for (let k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
            t[n] = c;
        }
        crcTable = t;
        table = t;
    }
    let c: u32 = 0xFFFFFFFF;
    for (let i = start; i < end; i++) c = table[(c ^ <u32>b[i]) & 255] ^ (c >>> 8);
    return c ^ 0xFFFFFFFF;
}

function writeU32BE(b: Uint8Array, o: i32, v: u32): void {
    b[o] = <u8>(v >>> 24);
    b[o + 1] = <u8>((v >>> 16) & 255);
    b[o + 2] = <u8>((v >>> 8) & 255);
    b[o + 3] = <u8>(v & 255);
}

/// Writes a PNG chunk (length, type, data, crc) at `o`; returns the offset
/// after it.
function writeChunk(png: Uint8Array, o: i32, type: u32, data: Uint8Array): i32 {
    writeU32BE(png, o, <u32>data.length);
    writeU32BE(png, o + 4, type);
    png.set(data, o + 8);
    writeU32BE(png, o + 8 + data.length, crc32(png, o + 4, o + 8 + data.length));
    return o + 12 + data.length;
}

/// RGBA8 pixels as a PNG: 8-bit RGBA, no filter, zlib stored blocks (no
/// compression). Rows are written from the last when `flipY`;
/// premultiplied pixels are divided by alpha (PNG is straight alpha).
export function encodePNG(data: Uint8Array, width: i32, height: i32, flipY: bool = false,
                          premultiplied: bool = false): Uint8Array {
    const rowBytes = width * 4 + 1;
    const raw = new Uint8Array(rowBytes * height);
    for (let y = 0; y < height; y++) {
        const src = flipY ? height - 1 - y : y;
        raw[y * rowBytes] = 0;   // filter: none
        for (let x = 0; x < width * 4; x += 4) {
            const s = src * width * 4 + x;
            let r = <u32>data[s], g = <u32>data[s + 1], b = <u32>data[s + 2];
            const a = <u32>data[s + 3];
            if (premultiplied && a > 0 && a < 255) {
                r = min<u32>(255, (r * 255 + a / 2) / a);
                g = min<u32>(255, (g * 255 + a / 2) / a);
                b = min<u32>(255, (b * 255 + a / 2) / a);
            }
            const o = y * rowBytes + 1 + x;
            raw[o] = <u8>r;
            raw[o + 1] = <u8>g;
            raw[o + 2] = <u8>b;
            raw[o + 3] = <u8>a;
        }
    }
    // zlib: header, stored blocks of at most 65535 bytes, adler32.
    const blocks = max<i32>(1, (raw.length + 65534) / 65535);
    const z = new Uint8Array(2 + raw.length + blocks * 5 + 4);
    z[0] = 0x78;
    z[1] = 0x01;
    let zo = 2;
    let pos = 0;
    for (let k = 0; k < blocks; k++) {
        const len = min<i32>(65535, raw.length - pos);
        z[zo++] = k == blocks - 1 ? 1 : 0;   // BFINAL, BTYPE 00 (stored)
        z[zo++] = <u8>(len & 255);
        z[zo++] = <u8>((len >> 8) & 255);
        z[zo++] = <u8>(~len & 255);
        z[zo++] = <u8>((~len >> 8) & 255);
        z.set(raw.subarray(pos, pos + len), zo);
        zo += len;
        pos += len;
    }
    let s1: u32 = 1, s2: u32 = 0;
    for (let i = 0; i < raw.length; i++) {
        s1 += <u32>raw[i];
        if (s1 >= 65521) s1 -= 65521;
        s2 += s1;
        if (s2 >= 65521) s2 -= 65521;
    }
    writeU32BE(z, zo, (s2 << 16) | s1);

    const ihdr = new Uint8Array(13);
    writeU32BE(ihdr, 0, <u32>width);
    writeU32BE(ihdr, 4, <u32>height);
    ihdr[8] = 8;    // bit depth
    ihdr[9] = 6;    // colour type: RGBA
    ihdr[10] = 0;   // compression: deflate
    ihdr[11] = 0;   // filter method
    ihdr[12] = 0;   // no interlace
    const png = new Uint8Array(8 + (12 + 13) + (12 + z.length) + 12);
    const signature: StaticArray<u8> = [137, 80, 78, 71, 13, 10, 26, 10];
    for (let i = 0; i < 8; i++) png[i] = signature[i];
    let o = writeChunk(png, 8, 0x49484452, ihdr);           // IHDR
    o = writeChunk(png, o, 0x49444154, z);                  // IDAT
    writeChunk(png, o, 0x49454E44, new Uint8Array(0));      // IEND
    return png;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Base64 (RFC 4648, padded) of `b`.
export function base64Encode(b: Uint8Array): string {
    const n = b.length;
    const out = new Uint8Array(((n + 2) / 3) * 4);
    let o = 0;
    for (let i = 0; i < n; i += 3) {
        const v = (<u32>b[i] << 16) | (i + 1 < n ? <u32>b[i + 1] << 8 : 0) | (i + 2 < n ? <u32>b[i + 2] : 0);
        out[o++] = <u8>B64.charCodeAt(<i32>((v >>> 18) & 63));
        out[o++] = <u8>B64.charCodeAt(<i32>((v >>> 12) & 63));
        out[o++] = i + 1 < n ? <u8>B64.charCodeAt(<i32>((v >>> 6) & 63)) : 61;
        out[o++] = i + 2 < n ? <u8>B64.charCodeAt(<i32>(v & 63)) : 61;
    }
    return String.UTF8.decode(out.buffer);
}
