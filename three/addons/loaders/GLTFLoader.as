// three.js's GLTFLoader addon, for Rive: reads a glTF 2.0 (.glb, or .gltf
// JSON with embedded data: URIs) from a BlobAsset and builds the scene, as
// three.js would.
//
//     const gltf = new GLTFLoader(context).load("robot");   // the BlobAsset's name
//     if (gltf != null) {
//         scene.add(gltf.scene);
//         mixer = new AnimationMixer(gltf.scene);
//         mixer.clipAction(gltf.animations[0]).play();
//     }
//
// Synchronous: the scene is ready on return (no callback); embedded images
// decode asynchronously and their textures fill in a few frames later.
//
// Read: the node hierarchy (TRS or matrix), meshes (triangles, strips, fans,
// lines, points; positions, normals, uvs, colours, skinning, morph targets),
// sparse accessors, PBR materials (KHR_materials_unlit, emissive_strength,
// clearcoat, sheen, ior, specular, transmission, volume, iridescence,
// anisotropy, dispersion; KHR_texture_transform), embedded PNG/JPEG/WebP
// textures (EXT_texture_webp) and samplers, skins, animations (LINEAR, STEP,
// CUBICSPLINE), cameras, KHR_lights_punctual, KHR_mesh_quantization,
// EXT_mesh_gpu_instancing and EXT_meshopt_compression (setMeshoptDecoder).
// Not read: external files, Draco, KTX2 / Basis textures,
// KHR_materials_variants.

import { Context, DecodedImage, ImageDecodeListener } from "rive/host";
import { parseJson } from "rive/json";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { LoaderUtils } from "../../loaders/LoaderUtils";
import { fetchBytes } from "../../loaders/FileLoader";
import { Dynamic } from "rive/dynamic";
import { MeshoptDecoderModule, MeshoptDecoder } from "../libs/meshopt_decoder";
import { InstancedMesh } from "../../objects/InstancedMesh";
import { Vector3 } from "../../math/Vector3";
import { Quaternion } from "../../math/Quaternion";
import { Color } from "../../math/Color";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute } from "../../core/BufferAttribute";
import { Group } from "../../objects/Group";
import { Mesh } from "../../objects/Mesh";
import { SkinnedMesh } from "../../objects/SkinnedMesh";
import { Bone, Skeleton } from "../../objects/Skeleton";
import { Line, LineSegments, LineLoop } from "../../objects/Line";
import { Points } from "../../objects/Points";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { DirectionalLight } from "../../lights/DirectionalLight";
import { PointLight } from "../../lights/PointLight";
import { SpotLight } from "../../lights/SpotLight";
import { Light } from "../../lights/Light";
import { Material } from "../../materials/Material";
import { MeshStandardMaterial } from "../../materials/MeshStandardMaterial";
import { MeshPhysicalMaterial } from "../../materials/MeshPhysicalMaterial";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { PointsMaterial } from "../../materials/PointsMaterial";
import { DataTexture } from "../../textures/DataTexture";
import { Texture } from "../../textures/Texture";
import { Matrix4 } from "../../math/Matrix4";
import { AnimationClip } from "../../animation/AnimationClip";
import {
    KeyframeTrack, NumberKeyframeTrack, VectorKeyframeTrack, QuaternionKeyframeTrack,
    InterpolateGLTFCubicSpline,
} from "../../animation/KeyframeTrack";
import { PropertyBinding } from "../../animation/PropertyBinding";
import {
    DoubleSide, InterpolateDiscrete, InterpolateLinear, SRGBColorSpace, NoColorSpace, RepeatWrapping,
    ClampToEdgeWrapping, MirroredRepeatWrapping, NearestFilter, LinearFilter, NearestMipmapNearestFilter,
    LinearMipmapNearestFilter, NearestMipmapLinearFilter, LinearMipmapLinearFilter,
} from "../../constants";

/// What GLTFLoader.load returns, as three.js's gltf object.
export class GLTF {
    scene: Group = new Group();
    scenes: Array<Group> = [];
    animations: Array<AnimationClip> = [];
    cameras: Array<Camera> = [];
    /// asset.version, asset.generator.
    version: string = "";
    generator: string = "";
}

/// Fills a texture when its image has decoded.
class TextureDecode extends ImageDecodeListener {
    textures: Array<DataTexture> = [];
    context: Context;

    constructor(context: Context) {
        super();
        this.context = context;
    }

    override onImageDecoded(image: DecodedImage): void {
        const data = Uint8Array.wrap(image.data);
        for (let i = 0; i < this.textures.length; i++) {
            const t = this.textures[i];
            t.data = data;
            t.dataWidth = image.width;
            t.dataHeight = image.height;
            t.needsUpdate = true;
        }
    }

    override onImageDecodeFailed(message: string): void {
        this.context.log("three: GLTFLoader: an image failed to decode: " + message);
    }
}

// Images still decoding (kept alive until they report).
const pendingDecodes: Array<TextureDecode> = [];

/// Extensions this loader reads (a file requiring another one fails).
const SUPPORTED_EXTENSIONS: StaticArray<string> = [
    "KHR_materials_unlit", "KHR_materials_emissive_strength", "KHR_materials_clearcoat", "KHR_materials_sheen",
    "KHR_materials_ior", "KHR_materials_specular", "KHR_materials_transmission", "KHR_materials_volume",
    "KHR_materials_iridescence", "KHR_materials_anisotropy", "KHR_materials_dispersion", "KHR_texture_transform",
    "KHR_lights_punctual", "KHR_mesh_quantization", "EXT_texture_webp", "EXT_mesh_gpu_instancing",
    "EXT_meshopt_compression",
];

export class GLTFLoader extends Loader {
    // `context` loads blob assets, decodes images and logs; without one,
    // `parse` still builds the scene (images stay empty, errors go to `error`).
    meshoptDecoder: MeshoptDecoderModule? = null;
    /// Why the last load or parse returned null, or a warning.
    error: string = "";
    /// Warnings of the last parse (unsupported features met).
    warnings: Array<string> = [];

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The decoder for EXT_meshopt_compression (MeshoptDecoder from
    /// three/addons/libs/meshopt_decoder), as three.js.
    setMeshoptDecoder(decoder: MeshoptDecoderModule?): GLTFLoader {
        this.meshoptDecoder = decoder;
        return this;
    }

    /// Loads the BlobAsset called `name` (`path` + name), at once; null (and
    /// a log line) when it is missing or not a glTF this loader reads. A
    /// .gltf's external files resolve to blob assets named after them
    /// without extension ("scene.bin" -> "scene"). Urls need loadAsync.
    load(name: string): GLTF? {
        const context = this.context;
        const full = LoaderUtils.resolveURL(name, this.path);
        if (LoaderUtils.isURL(full)) {
            this.error = "urls load with loadAsync";
            if (context != null) context.log("three: GLTFLoader: " + this.error);
            return null;
        }
        const bytesAsset = context != null ? context.blob(full) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            this.error = "no blob asset named '" + full + "'";
            if (context != null) context.log("three: GLTFLoader: " + this.error);
            return null;
        }
        return this.parse(bytes);
    }

    /// Parses .glb bytes, or .gltf JSON text as bytes (external files as
    /// blob assets, see load).
    parse(data: ArrayBuffer): GLTF? {
        const gd = new GLTFData(data, this.meshoptDecoder);
        if (!gd.readContainer()) {
            this.error = gd.error;
            const context = this.context;
            if (context != null) context.log("three: GLTFLoader: " + this.error);
            return null;
        }
        const context = this.context;
        if (context != null) {
            const buffers = arr(gd.json, "buffers");
            for (let i = 0; i < buffers.length; i++) {
                const uri = str(buffers[i], "uri", "");
                if (uri.length == 0 || uri.startsWith("data:")) continue;
                const bytesAsset = context.blob(assetName(uri));
                const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
                if (bytes != null) gd.external.set(i, Uint8Array.wrap(bytes!));
            }
            const images = arr(gd.json, "images");
            for (let i = 0; i < images.length; i++) {
                const uri = str(images[i], "uri", "");
                if (uri.length == 0 || uri.startsWith("data:")) continue;
                const bytesAsset = context.blob(assetName(uri));
                const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
                if (bytes != null) gd.externalImages.set(i, Uint8Array.wrap(bytes!));
            }
        }
        return this.parseData(gd);
    }

    /// Loads `url`: an https: url (fetched where the host allows the
    /// network, a .gltf's external files from beside it, or from
    /// `resourcePath`), else the blob asset of that name. The decoding
    /// (container, meshopt, accessors) runs in a Rive job off the main lane;
    /// the scene is built when it is done, on a later frame. Progress goes
    /// to the `manager`.
    loadAsync(url: string): Promise<GLTF> {
        return loadInJob(this, url);
    }

    /// As parse, decoding in a job; `path` is where external files resolve.
    parseAsync(data: ArrayBuffer, path: string = ""): Promise<GLTF> {
        return parseInJob(this, data, path);
    }

    /// Builds the scene from bytes already decoded or to decode now.
    parseData(gd: GLTFData): GLTF? {
        const parser = new GLTFParser(this.context, gd);
        const gltf = parser.parse();
        this.error = parser.error;
        const warnings: Array<string> = [];
        for (let i = 0; i < gd.warnings.length; i++) warnings.push(gd.warnings[i]);
        for (let i = 0; i < parser.warnings.length; i++) warnings.push(parser.warnings[i]);
        this.warnings = warnings;
        const context = this.context;
        if (context != null) {
            for (let i = 0; i < gd.warnings.length; i++) context.log("three: GLTFLoader: " + gd.warnings[i]);
            if (gltf == null) context.log("three: GLTFLoader: " + parser.error);
        }
        return gltf;
    }
}

async function loadInJob(loader: GLTFLoader, url: string): Promise<GLTF> {
    const resolved = LoaderUtils.resolveURL(url, loader.path);
    const settled = await fetchBytes(loader, url).settled();
    if (!settled.ok) {
        loader.error = settled.error;
        return await Promise.reject<GLTF>(settled.error);
    }
    const base = loader.resourcePath.length > 0 ? loader.resourcePath
        : LoaderUtils.isURL(resolved) ? LoaderUtils.extractUrlBase(resolved) : "";
    return await parseInJob(loader, settled.value, base);
}

async function parseInJob(loader: GLTFLoader, data: ArrayBuffer, base: string): Promise<GLTF> {
    // External files first (the job cannot fetch).
    const head = new GLTFData(data, null);
    if (!head.readContainer()) {
        loader.error = head.error;
        return await Promise.reject<GLTF>(head.error);
    }
    const externalBuffers: Array<ArrayBuffer> = [];
    const externalIndices: Array<i32> = [];
    const externalImages: Map<i32, Uint8Array> = new Map<i32, Uint8Array>();
    const buffers = arr(head.json, "buffers");
    for (let i = 0; i < buffers.length; i++) {
        const uri = str(buffers[i], "uri", "");
        if (uri.length == 0 || uri.startsWith("data:")) continue;
        const bytes = await externalFile(loader, uri, base);
        if (bytes == null) continue;
        externalBuffers.push(bytes!);
        externalIndices.push(i);
    }
    const images = arr(head.json, "images");
    for (let i = 0; i < images.length; i++) {
        const uri = str(images[i], "uri", "");
        if (uri.length == 0 || uri.startsWith("data:")) continue;
        const bytes = await externalFile(loader, uri, base);
        if (bytes != null) externalImages.set(i, Uint8Array.wrap(bytes!));
    }
    const job = Jobs.run(decodeGLTF, data, loader.meshoptDecoder != null, externalBuffers, externalIndices);
    const decoded = await job.promise();
    if (decoded.error.length > 0) {
        loader.error = decoded.error;
        return await Promise.reject<GLTF>(decoded.error);
    }
    const gd = new GLTFData(data, loader.meshoptDecoder);
    for (let i = 0; i < externalIndices.length; i++) gd.external.set(externalIndices[i], Uint8Array.wrap(externalBuffers[i]));
    gd.externalImages = externalImages;
    gd.decoded = decoded.floats;
    gd.decodedOffsets = decoded.offsets;
    gd.decodedLengths = decoded.lengths;
    const gltf = loader.parseData(gd);
    if (gltf == null) return await Promise.reject<GLTF>(loader.error);
    return gltf!;
}

/// An external file of a glTF: fetched beside it when `base` is a url,
/// else the blob asset named after it; null (logged) when missing.
async function externalFile(loader: GLTFLoader, uri: string, base: string): Promise<ArrayBuffer?> {
    const url = LoaderUtils.isURL(base) ? LoaderUtils.resolveURL(decodeURIComponentLite(uri), base) : assetName(uri);
    const settled = await fetchBytes(loader, url, LoaderUtils.isURL(base) ? "" : loader.path).settled();
    if (!settled.ok) {
        const context = loader.context;
        if (context != null) context.log("three: GLTFLoader: " + settled.error);
        return null;
    }
    return settled.value;
}

/// The blob asset name for a file a glTF references: its file name
/// without folders or extension.
function assetName(uri: string): string {
    let name = uri;
    const slash = name.lastIndexOf("/");
    if (slash >= 0) name = name.substring(slash + 1);
    const dot = name.lastIndexOf(".");
    if (dot > 0) name = name.substring(0, dot);
    return decodeURIComponentLite(name);
}

/// %20 and friends (glTF uris are uri-encoded).
function decodeURIComponentLite(s: string): string {
    if (s.indexOf("%") < 0) return s;
    let out = "";
    let i = 0;
    while (i < s.length) {
        const c = s.charAt(i);
        if (c == "%" && i + 2 < s.length) {
            const hex = parseInt(s.substring(i + 1, i + 3), 16);
            if (!isNaN(hex)) {
                out += String.fromCharCode(<i32>hex);
                i += 3;
                continue;
            }
        }
        out += c;
        i++;
    }
    return out;
}

/// The container, buffers, views and accessors of a glTF: pure code, so a
/// job can decode them (decodeGLTF) while the main lane builds the scene.
export class GLTFData {
    data: ArrayBuffer;
    bytes: Uint8Array;
    error: string = "";
    warnings: Array<string> = [];
    json: Dynamic? = null;
    meshoptDecoder: MeshoptDecoderModule? = null;
    /// The GLB binary chunk (buffer 0 without a uri), when there is one.
    bin: Uint8Array? = null;
    buffers: Map<i32, Uint8Array> = new Map<i32, Uint8Array>();
    views: Map<i32, Uint8Array> = new Map<i32, Uint8Array>();
    /// External files, loaded ahead: buffers and images by index.
    external: Map<i32, Uint8Array> = new Map<i32, Uint8Array>();
    externalImages: Map<i32, Uint8Array> = new Map<i32, Uint8Array>();
    /// Accessors decoded ahead (by a job): floats from offsets[i], lengths[i]
    /// long; offset -1 when not decoded.
    decoded: Float32Array? = null;
    decodedOffsets: Int32Array? = null;
    decodedLengths: Int32Array? = null;

    constructor(data: ArrayBuffer, meshoptDecoder: MeshoptDecoderModule? = null) {
        this.data = data;
        this.bytes = Uint8Array.wrap(data);
        this.meshoptDecoder = meshoptDecoder;
    }

    /// Accessor `index` as floats, decoded ahead or now.
    accessor(index: i32): Float32Array {
        const d = this.decoded;
        const offsets = this.decodedOffsets;
        const lengths = this.decodedLengths;
        if (d != null && offsets != null && lengths != null && index >= 0 && index < offsets.length && offsets[index] >= 0) {
            return d.slice(offsets[index], offsets[index] + lengths[index]);
        }
        return this.floats(index);
    }


    /// A .glb, or .gltf JSON (starting with "{" after any whitespace).
    readContainer(): bool {
        const b = this.bytes;
        let first = 0;
        while (first < b.length && (b[first] == 32 || b[first] == 9 || b[first] == 10 || b[first] == 13
            || b[first] == 0xEF || b[first] == 0xBB || b[first] == 0xBF)) first++;
        if (first < b.length && b[first] == 123) {
            const result = parseJson(String.UTF8.decode(this.data));
            if (!result.ok || result.value == null) {
                this.error = "bad JSON";
                return false;
            }
            this.json = result.value;
            return true;
        }
        return this.readGlb();
    }

    private readGlb(): bool {
        const b = this.bytes;
        if (b.length < 20 || u32At(b, 0) != 0x46546C67) {
            this.error = "not a .glb (binary glTF) nor .gltf JSON";
            return false;
        }
        let offset = 12;
        let jsonText = "";
        while (offset + 8 <= b.length) {
            const length = <i32>u32At(b, offset);
            const type = u32At(b, offset + 4);
            const start = offset + 8;
            if (type == 0x4E4F534A) {
                jsonText = String.UTF8.decode(this.data.slice(start, start + length));
            } else if (type == 0x004E4942) {
                this.bin = b.subarray(start, start + length);
            }
            offset = start + ((length + 3) & ~3);
        }
        const result = parseJson(jsonText);
        if (!result.ok || result.value == null) {
            this.error = "bad JSON chunk";
            return false;
        }
        this.json = result.value;
        return true;
    }

    /// Buffer `index`: the GLB chunk, or a base64 data: URI; null for
    /// external files (not read) and fallback buffers.
    buffer(index: i32): Uint8Array? {
        if (this.buffers.has(index)) return this.buffers.get(index);
        const def = dat(dget(this.json, "buffers"), index);
        if (def == null) return null;
        const uri = str(def, "uri", "");
        let out: Uint8Array? = null;
        if (uri.length == 0) {
            if (index == 0) out = this.bin;
        } else if (uri.startsWith("data:")) {
            out = decodeDataUri(uri);
        } else if (this.external.has(index)) {
            out = this.external.get(index);
        } else if (this.error.length == 0) {
            this.warnings.push("external buffer '" + uri + "' is not supported (embed it, or use a .glb)");
        }
        if (out != null) this.buffers.set(index, out!);
        return out;
    }

    /// The bytes of bufferView `index` (decoded, for meshopt views); empty
    /// when unavailable.
    viewBytes(index: i32): Uint8Array {
        if (this.views.has(index)) return this.views.get(index);
        const v = dat(dget(this.json, "bufferViews"), index);
        let out = new Uint8Array(0);
        const meshopt = dget(dget(v, "extensions"), "EXT_meshopt_compression");
        const decoder = this.meshoptDecoder;
        if (meshopt != null && decoder != null) {
            const source = this.buffer(<i32>num(meshopt, "buffer", 0));
            if (source != null) {
                const offset = <i32>num(meshopt, "byteOffset", 0);
                const compressed = source.subarray(offset, offset + <i32>num(meshopt, "byteLength", 0));
                const count = <i32>num(meshopt, "count", 0);
                const stride = <i32>num(meshopt, "byteStride", 0);
                const decoded = new Uint8Array(count * stride);
                if (decoder.decodeGltfBuffer(decoded, count, stride, compressed, str(meshopt, "mode", ""),
                        str(meshopt, "filter", "NONE"))) {
                    out = decoded;
                } else {
                    this.warnings.push("meshopt: " + decoder.error);
                }
            }
        } else {
            const b = this.buffer(<i32>num(v, "buffer", 0));
            if (b != null) {
                const offset = <i32>num(v, "byteOffset", 0);
                out = b.subarray(offset, offset + <i32>num(v, "byteLength", 0));
            }
        }
        this.views.set(index, out);
        return out;
    }

    viewStride(index: i32): i32 {
        return <i32>num(dat(dget(this.json, "bufferViews"), index), "byteStride", 0);
    }

    /// Accessor `index` as floats (normalized integers scaled to [0, 1] or
    /// [-1, 1]).
    floats(index: i32): Float32Array {
        const accessors = arr(this.json, "accessors");
        if (index < 0 || index >= accessors.length) return new Float32Array(0);
        const a = accessors[index];
        const count = <i32>num(a, "count", 0);
        const n = components(str(a, "type", "SCALAR"));
        const ct = <i32>num(a, "componentType", 5126);
        const normalized = dbool(dget(a, "normalized"));
        const out = new Float32Array(count * n);
        const size = componentSize(ct);
        const bv = <i32>num(a, "bufferView", -1);
        if (bv >= 0) {
            const b = this.viewBytes(bv);
            const vs = this.viewStride(bv);
            const stride = vs > 0 ? vs : size * n;
            const base = <i32>num(a, "byteOffset", 0);
            for (let i = 0; i < count; i++) {
                const at = base + i * stride;
                if (at + size * n > b.length) break;
                for (let c = 0; c < n; c++) out[i * n + c] = <f32>readComponent(b, at + c * size, ct, normalized);
            }
        }
        // Sparse: values replacing some elements (of zeros without a view).
        const sparse = dget(a, "sparse");
        if (sparse != null) {
            const sc = <i32>num(sparse, "count", 0);
            const ind = dget(sparse, "indices");
            const val = dget(sparse, "values");
            const ib = this.viewBytes(<i32>num(ind, "bufferView", -1));
            const ibase = <i32>num(ind, "byteOffset", 0);
            const ict = <i32>num(ind, "componentType", 5125);
            const isize = componentSize(ict);
            const vb = this.viewBytes(<i32>num(val, "bufferView", -1));
            const vbase = <i32>num(val, "byteOffset", 0);
            for (let i = 0; i < sc; i++) {
                if (ibase + (i + 1) * isize > ib.length || vbase + (i + 1) * size * n > vb.length) break;
                const target = <i32>readComponent(ib, ibase + i * isize, ict, false);
                if (target < 0 || target >= count) continue;
                for (let c = 0; c < n; c++) {
                    out[target * n + c] = <f32>readComponent(vb, vbase + (i * n + c) * size, ct, normalized);
                }
            }
        }
        return out;
    }

}

/// What decodeGLTF hands back to the main lane: every accessor as floats,
/// back to back (crossing lanes as one block).
export class GLTFDecoded {
    error: string = "";
    floats: Float32Array = new Float32Array(0);
    offsets: Int32Array = new Int32Array(0);
    lengths: Int32Array = new Int32Array(0);
}

/// The job behind loadAsync / parseAsync: parses the container, decodes
/// meshopt views and every accessor, off the main lane.
@job export function decodeGLTF(data: ArrayBuffer, meshopt: bool, externalBuffers: Array<ArrayBuffer>,
                                externalIndices: Array<i32>): GLTFDecoded {
    const out = new GLTFDecoded();
    const gd = new GLTFData(data, meshopt ? MeshoptDecoder : null);
    for (let i = 0; i < externalIndices.length && i < externalBuffers.length; i++) {
        gd.external.set(externalIndices[i], Uint8Array.wrap(externalBuffers[i]));
    }
    if (!gd.readContainer()) {
        out.error = gd.error;
        return out;
    }
    const accessors = arr(gd.json, "accessors");
    const n = accessors.length;
    const parts: Array<Float32Array> = [];
    let total = 0;
    for (let i = 0; i < n; i++) {
        const f = gd.floats(i);
        parts.push(f);
        total += f.length;
    }
    out.floats = new Float32Array(total);
    out.offsets = new Int32Array(n);
    out.lengths = new Int32Array(n);
    let at = 0;
    for (let i = 0; i < n; i++) {
        out.floats.set(parts[i], at);
        out.offsets[i] = at;
        out.lengths[i] = parts[i].length;
        at += parts[i].length;
    }
    return out;
}

const MODE_POINTS: i32 = 0;
const MODE_LINES: i32 = 1;
const MODE_LINE_LOOP: i32 = 2;
const MODE_LINE_STRIP: i32 = 3;
const MODE_TRIANGLES: i32 = 4;
const MODE_TRIANGLE_STRIP: i32 = 5;
const MODE_TRIANGLE_FAN: i32 = 6;

class GLTFParser {
    context: Context?;
    warnings: Array<string> = [];
    gd: GLTFData;
    error: string = "";
    json: Dynamic? = null;
    textures: Map<string, DataTexture> = new Map<string, DataTexture>();
    decodes: Map<i32, TextureDecode> = new Map<i32, TextureDecode>();
    materials: Map<i32, Material> = new Map<i32, Material>();
    nodes: Array<Object3D> = [];
    nodeNames: Array<string> = [];
    usedNames: Map<string, i32> = new Map<string, i32>();
    joints: Map<i32, bool> = new Map<i32, bool>();
    meshesOf: Array<Array<Mesh>> = [];
    cameras: Array<Camera> = [];

    constructor(context: Context?, gd: GLTFData) {
        this.context = context;
        this.gd = gd;
    }

    private floats(index: i32): Float32Array { return this.gd.accessor(index); }

    private viewBytes(index: i32): Uint8Array { return this.gd.viewBytes(index); }

    warn(message: string): void {
        this.warnings.push(message);
        const context = this.context;
        if (context != null) context.log("three: GLTFLoader: " + message);
    }

    parse(): GLTF? {
        const gd = this.gd;
        if (gd.json == null && !gd.readContainer()) {
            this.error = gd.error;
            return null;
        }
        this.json = gd.json;
        const json = this.json;
        if (json == null) return null;
        const required = arr(json, "extensionsRequired");
        for (let i = 0; i < required.length; i++) {
            const name = Dynamic.asStringOrNull(required[i]);
            if (name == null) continue;
            let known = false;
            for (let k = 0; k < SUPPORTED_EXTENSIONS.length; k++) if (SUPPORTED_EXTENSIONS[k] == name) known = true;
            if (!known) {
                this.error = "required extension " + name + " is not supported";
                return null;
            }
            if (name == "EXT_meshopt_compression" && gd.meshoptDecoder == null && gd.decoded == null) {
                this.error = "setMeshoptDecoder must be called before loading compressed files";
                return null;
            }
        }
        const gltf = new GLTF();
        const asset = dget(json, "asset");
        gltf.version = str(asset, "version", "");
        gltf.generator = str(asset, "generator", "");
        if (!gltf.version.startsWith("2")) {
            this.error = "only glTF 2.0 is supported (got " + gltf.version + ")";
            return null;
        }

        // Joints become Bones.
        const skins = arr(json, "skins");
        for (let s = 0; s < skins.length; s++) {
            const jointList = dnumbers(dget(skins[s], "joints"));
            for (let j = 0; j < jointList.length; j++) this.joints.set(<i32>jointList[j], true);
        }

        // Nodes, then the hierarchy.
        const nodes = arr(json, "nodes");
        for (let i = 0; i < nodes.length; i++) this.nodes.push(this.buildNode(i, nodes[i]));
        for (let i = 0; i < nodes.length; i++) {
            const children = Dynamic.asNumbersOrNull(dget(nodes[i], "children"));
            if (children == null) continue;
            for (let c = 0; c < children.length; c++) {
                const child = <i32>children[c];
                if (child >= 0 && child < this.nodes.length) this.nodes[i].add(this.nodes[child]);
            }
        }

        // Scenes.
        const scenes = arr(json, "scenes");
        for (let s = 0; s < scenes.length; s++) {
            const group = new Group();
            group.name = PropertyBinding.sanitizeNodeName(str(scenes[s], "name", ""));
            const roots = Dynamic.asNumbersOrNull(dget(scenes[s], "nodes"));
            if (roots != null) {
                for (let r = 0; r < roots.length; r++) {
                    const n = <i32>roots[r];
                    if (n >= 0 && n < this.nodes.length) group.add(this.nodes[n]);
                }
            }
            gltf.scenes.push(group);
        }
        if (gltf.scenes.length == 0) {
            const group = new Group();
            for (let i = 0; i < this.nodes.length; i++) if (this.nodes[i].parent == null) group.add(this.nodes[i]);
            gltf.scenes.push(group);
        }
        const sceneIndex = <i32>num(json, "scene", 0);
        gltf.scene = gltf.scenes[sceneIndex >= 0 && sceneIndex < gltf.scenes.length ? sceneIndex : 0];

        // Skins (bound in the world pose, as three.js).
        for (let s = 0; s < gltf.scenes.length; s++) gltf.scenes[s].updateMatrixWorld(true);
        for (let i = 0; i < nodes.length; i++) {
            const skinIndex = <i32>num(nodes[i], "skin", -1);
            if (skinIndex < 0 || skinIndex >= skins.length) continue;
            const skeleton = this.buildSkeleton(skins[skinIndex]);
            const meshes = this.meshesOf[i];
            for (let m = 0; m < meshes.length; m++) {
                const mesh = meshes[m];
                if (mesh instanceof SkinnedMesh) {
                    (mesh as SkinnedMesh).bind(skeleton, mesh.matrixWorld);
                    (mesh as SkinnedMesh).normalizeSkinWeights();
                }
            }
        }

        // Animations and cameras.
        const animations = arr(json, "animations");
        for (let a = 0; a < animations.length; a++) {
            const clip = this.buildAnimation(a, animations[a]);
            if (clip != null) gltf.animations.push(clip);
        }
        gltf.cameras = this.cameras;
        return gltf;
    }

    private ints(index: i32): Array<i32> {
        const f = this.floats(index);
        const out = new Array<i32>(f.length);
        for (let i = 0; i < f.length; i++) out[i] = <i32>f[i];
        return out;
    }

    // ------------------------------------------------------------- nodes

    private buildNode(index: i32, def: Dynamic?): Object3D {
        const objects: Array<Object3D> = [];
        const meshes: Array<Mesh> = [];
        const meshIndex = <i32>num(def, "mesh", -1);
        if (meshIndex >= 0) {
            const built = this.buildMesh(meshIndex, dget(def, "skin") != null);
            for (let i = 0; i < built.length; i++) {
                objects.push(built[i]);
                if (built[i] instanceof Mesh) meshes.push(built[i] as Mesh);
            }
            // Mesh-level default morph weights.
            const meshDef = dat(dget(this.json, "meshes"), meshIndex);
            const weights = Dynamic.asNumbersOrNull(dget(def, "weights"));
            const meshWeights = weights != null ? weights : Dynamic.asNumbersOrNull(dget(meshDef, "weights"));
            if (meshWeights != null) {
                for (let m = 0; m < meshes.length; m++) {
                    const infl = meshes[m].morphTargetInfluences;
                    for (let w = 0; w < meshWeights.length && w < infl.length; w++) infl[w] = meshWeights[w];
                }
            }
        }
        // EXT_mesh_gpu_instancing: each mesh becomes an InstancedMesh.
        const gpuInstancing = dget(dget(def, "extensions"), "EXT_mesh_gpu_instancing");
        if (gpuInstancing != null && meshes.length > 0) this.instance(gpuInstancing, objects, meshes);
        this.meshesOf.push(meshes);
        const cameraIndex = <i32>num(def, "camera", -1);
        if (cameraIndex >= 0) {
            const camera = this.buildCamera(cameraIndex);
            if (camera != null) {
                objects.push(camera);
                this.cameras.push(camera);
            }
        }
        const lightIndex = <i32>num(dget(dget(def, "extensions"), "KHR_lights_punctual"), "light", -1);
        if (lightIndex >= 0) {
            const light = this.buildLight(lightIndex);
            if (light != null) objects.push(light);
        }

        let node: Object3D;
        if (this.joints.has(index)) {
            node = new Bone();
            for (let i = 0; i < objects.length; i++) node.add(objects[i]);
        } else if (objects.length == 1) {
            node = objects[0];
        } else {
            node = new Group();
            for (let i = 0; i < objects.length; i++) node.add(objects[i]);
        }
        node.name = this.uniqueName(str(def, "name", ""), index);
        if (objects.length > 1 || this.joints.has(index)) {
            // Name the parts too (three.js names multi-primitive meshes the same).
            for (let i = 0; i < objects.length; i++) if (objects[i].name.length == 0) objects[i].name = node.name;
        }

        const matrix = Dynamic.asNumbersOrNull(dget(def, "matrix"));
        if (matrix != null && matrix.length == 16) {
            _m.fromArray(matrix);
            node.applyMatrix4(_m);
        } else {
            const t = Dynamic.asNumbersOrNull(dget(def, "translation"));
            const r = Dynamic.asNumbersOrNull(dget(def, "rotation"));
            const s = Dynamic.asNumbersOrNull(dget(def, "scale"));
            if (t != null && t.length == 3) node.position.set(t[0], t[1], t[2]);
            if (r != null && r.length == 4) node.quaternion.set(r[0], r[1], r[2], r[3]);
            if (s != null && s.length == 3) node.scale.set(s[0], s[1], s[2]);
        }
        return node;
    }

    private instance(def: Dynamic?, objects: Array<Object3D>, meshes: Array<Mesh>): void {
        const attrs = dget(def, "attributes");
        const t = <i32>num(attrs, "TRANSLATION", -1);
        const r = <i32>num(attrs, "ROTATION", -1);
        const sc = <i32>num(attrs, "SCALE", -1);
        const c = <i32>num(attrs, "_COLOR_0", -1);
        const translations = t >= 0 ? this.floats(t) : new Float32Array(0);
        const rotations = r >= 0 ? this.floats(r) : new Float32Array(0);
        const scales = sc >= 0 ? this.floats(sc) : new Float32Array(0);
        const colors = c >= 0 ? this.floats(c) : new Float32Array(0);
        const count = max<i32>(max<i32>(translations.length / 3, rotations.length / 4), scales.length / 3);
        if (count == 0) return;
        const p = new Vector3(), q = new Quaternion(), s = new Vector3(), m = new Matrix4(), color = new Color();
        const colorSize = c >= 0 ? colors.length / count : 0;
        for (let i = 0; i < meshes.length; i++) {
            const mesh = meshes[i];
            if (mesh instanceof SkinnedMesh) continue;
            const im = new InstancedMesh(mesh.geometry, mesh.material, count);
            for (let k = 0; k < count; k++) {
                p.set(0, 0, 0); q.set(0, 0, 0, 1); s.set(1, 1, 1);
                if (translations.length >= (k + 1) * 3) p.set(translations[k * 3], translations[k * 3 + 1], translations[k * 3 + 2]);
                if (rotations.length >= (k + 1) * 4) q.set(rotations[k * 4], rotations[k * 4 + 1], rotations[k * 4 + 2], rotations[k * 4 + 3]);
                if (scales.length >= (k + 1) * 3) s.set(scales[k * 3], scales[k * 3 + 1], scales[k * 3 + 2]);
                im.setMatrixAt(k, m.compose(p, q, s));
                if (colorSize >= 3) im.setColorAt(k, color.setRGB(colors[k * colorSize], colors[k * colorSize + 1], colors[k * colorSize + 2]));
            }
            im.name = mesh.name;
            for (let o = 0; o < objects.length; o++) if (objects[o] === mesh) objects[o] = im;
            meshes[i] = im;
        }
    }

    /// three.js-style unique, sanitized names ("node_<index>" when unnamed).
    private uniqueName(name: string, index: i32): string {
        let base = PropertyBinding.sanitizeNodeName(name);
        if (base.length == 0) base = "node_" + index.toString();
        if (!this.usedNames.has(base)) {
            this.usedNames.set(base, 1);
            return base;
        }
        const n = this.usedNames.get(base);
        this.usedNames.set(base, n + 1);
        return base + "_" + n.toString();
    }

    private buildSkeleton(skin: Dynamic?): Skeleton {
        const joints = dnumbers(dget(skin, "joints"));
        const bones: Array<Bone> = [];
        const inverses: Array<Matrix4> = [];
        const ibmIndex = <i32>num(skin, "inverseBindMatrices", -1);
        const ibm = ibmIndex >= 0 ? this.floats(ibmIndex) : new Float32Array(0);
        for (let j = 0; j < joints.length; j++) {
            const node = this.nodes[<i32>joints[j]];
            bones.push(node instanceof Bone ? node as Bone : new Bone());
            const m = new Matrix4();
            if (ibm.length >= (j + 1) * 16) {
                const e = m.elements;
                for (let k = 0; k < 16; k++) e[k] = ibm[j * 16 + k];
            }
            inverses.push(m);
        }
        return new Skeleton(bones, inverses);
    }

    // ------------------------------------------------------------- meshes

    private buildMesh(index: i32, skinned: bool): Array<Object3D> {
        const out: Array<Object3D> = [];
        const meshDef = dat(dget(this.json, "meshes"), index);
        const primitives = arr(meshDef, "primitives");
        const targetNames = Dynamic.asArrayOrNull(dget(dget(meshDef, "extras"), "targetNames"));
        for (let p = 0; p < primitives.length; p++) {
            const prim = primitives[p];
            const mode = <i32>num(prim, "mode", MODE_TRIANGLES);
            const geometry = this.buildGeometry(prim, mode);
            if (geometry == null) continue;
            const attrs = dget(prim, "attributes");
            const hasColors = dget(attrs, "COLOR_0") != null;
            const hasNormals = dget(attrs, "NORMAL") != null;
            const materialIndex = <i32>num(prim, "material", -1);
            let object: Object3D;
            if (mode == MODE_POINTS) {
                const m = new PointsMaterial({ sizeAttenuation: false });
                this.copyColor(materialIndex, m);
                m.vertexColors = hasColors;
                object = new Points(geometry, m);
            } else if (mode == MODE_LINES || mode == MODE_LINE_STRIP || mode == MODE_LINE_LOOP) {
                const m = new LineBasicMaterial();
                this.copyColor(materialIndex, m);
                m.vertexColors = hasColors;
                object = mode == MODE_LINES ? new LineSegments(geometry, m)
                    : mode == MODE_LINE_LOOP ? new LineLoop(geometry, m) : new Line(geometry, m);
            } else {
                let material = this.material(materialIndex);
                if (hasColors || !hasNormals) {
                    // Per-primitive variant, as three.js clones the material.
                    material = this.material(materialIndex, hasColors, !hasNormals);
                }
                const mesh = skinned && geometry.hasAttribute("skinIndex")
                    ? new SkinnedMesh(geometry, material) : new Mesh(geometry, material);
                if (geometry.morphAttributes.size > 0) {
                    mesh.updateMorphTargets();
                    if (targetNames != null) {
                        mesh.morphTargetDictionary.clear();
                        for (let t = 0; t < targetNames.length; t++) {
                            mesh.morphTargetDictionary.set(PropertyBinding.sanitizeNodeName(Dynamic.asString(targetNames[t])), t);
                        }
                    }
                }
                object = mesh;
            }
            out.push(object);
        }
        return out;
    }

    private buildGeometry(prim: Dynamic?, mode: i32): BufferGeometry? {
        const attrs = dget(prim, "attributes");
        const position = <i32>num(attrs, "POSITION", -1);
        if (position < 0) return null;
        const g = new BufferGeometry();
        g.setAttribute("position", new BufferAttribute(this.floats(position), 3));
        const normal = <i32>num(attrs, "NORMAL", -1);
        if (normal >= 0) g.setAttribute("normal", new BufferAttribute(this.floats(normal), 3));
        const uv = <i32>num(attrs, "TEXCOORD_0", -1);
        if (uv >= 0) g.setAttribute("uv", new BufferAttribute(this.floats(uv), 2));
        const uv1 = <i32>num(attrs, "TEXCOORD_1", -1);
        if (uv1 >= 0) g.setAttribute("uv1", new BufferAttribute(this.floats(uv1), 2));
        const color = <i32>num(attrs, "COLOR_0", -1);
        if (color >= 0) {
            const c = this.floats(color);
            const count = g.getAttribute("position")!.count;
            g.setAttribute("color", new BufferAttribute(c, count > 0 ? c.length / count : 3));
        }
        const joints = <i32>num(attrs, "JOINTS_0", -1);
        const weights = <i32>num(attrs, "WEIGHTS_0", -1);
        if (joints >= 0 && weights >= 0) {
            g.setAttribute("skinIndex", new BufferAttribute(this.floats(joints), 4));
            g.setAttribute("skinWeight", new BufferAttribute(this.floats(weights), 4));
        }
        const indices = <i32>num(prim, "indices", -1);
        let index: Array<i32>? = indices >= 0 ? this.ints(indices) : null;
        if (mode == MODE_TRIANGLE_STRIP || mode == MODE_TRIANGLE_FAN) {
            index = toTriangles(index, g.getAttribute("position")!.count, mode == MODE_TRIANGLE_FAN);
        }
        if (index != null) g.setIndex(index);

        // Morph targets: glTF targets are offsets.
        const targets = arr(prim, "targets");
        if (targets.length > 0) {
            const positions: Array<BufferAttribute> = [];
            const normals: Array<BufferAttribute> = [];
            const count = g.getAttribute("position")!.count;
            for (let t = 0; t < targets.length; t++) {
                const tp = <i32>num(targets[t], "POSITION", -1);
                positions.push(new BufferAttribute(tp >= 0 ? this.floats(tp) : new Float32Array(count * 3), 3));
                const tn = <i32>num(targets[t], "NORMAL", -1);
                if (tn >= 0) normals.push(new BufferAttribute(this.floats(tn), 3));
            }
            g.morphAttributes.set("position", positions);
            if (normals.length == positions.length) g.morphAttributes.set("normal", normals);
            g.morphTargetsRelative = true;
        }
        if (normal < 0 && (mode == MODE_TRIANGLES || mode == MODE_TRIANGLE_STRIP || mode == MODE_TRIANGLE_FAN)) {
            g.computeVertexNormals();
        }
        return g;
    }

    // ------------------------------------------------------------- materials

    private material(index: i32, vertexColors: bool = false, flatShading: bool = false): Material {
        const key = index * 4 + (vertexColors ? 1 : 0) + (flatShading ? 2 : 0);
        if (this.materials.has(key)) return this.materials.get(key);
        const m = this.buildMaterial(index);
        m.vertexColors = vertexColors;
        if (flatShading) m.flatShading = true;
        this.materials.set(key, m);
        return m;
    }

    private buildMaterial(index: i32): Material {
        const mats = arr(this.json, "materials");
        if (index < 0 || index >= mats.length) {
            // glTF's default material.
            return new MeshStandardMaterial({ color: 0xFFFFFF, metalness: 1, roughness: 1 });
        }
        const def = mats[index];
        const pbr = dget(def, "pbrMetallicRoughness");
        const ext = dget(def, "extensions");
        const factor = Dynamic.asNumbersOrNull(dget(pbr, "baseColorFactor"));
        const baseTex = dget(pbr, "baseColorTexture");
        let material: Material;
        if (dget(ext, "KHR_materials_unlit") != null) {
            const m = new MeshBasicMaterial();
            if (factor != null && factor.length == 4) {
                m.color.setRGB(factor[0], factor[1], factor[2]);
                m.opacity = factor[3];
            }
            if (baseTex != null) m.map = this.texture(baseTex, true);
            material = m;
        } else {
            const physical = dget(ext, "KHR_materials_clearcoat") != null
                || dget(ext, "KHR_materials_sheen") != null || dget(ext, "KHR_materials_ior") != null
                || dget(ext, "KHR_materials_specular") != null || dget(ext, "KHR_materials_transmission") != null
                || dget(ext, "KHR_materials_volume") != null || dget(ext, "KHR_materials_iridescence") != null
                || dget(ext, "KHR_materials_anisotropy") != null || dget(ext, "KHR_materials_dispersion") != null;
            const m: MeshStandardMaterial = physical ? <MeshStandardMaterial>new MeshPhysicalMaterial() : new MeshStandardMaterial();
            if (factor != null && factor.length == 4) {
                m.color.setRGB(factor[0], factor[1], factor[2]);
                m.opacity = factor[3];
            }
            m.metalness = num(pbr, "metallicFactor", 1);
            m.roughness = num(pbr, "roughnessFactor", 1);
            if (baseTex != null) m.map = this.texture(baseTex, true);
            const mr = dget(pbr, "metallicRoughnessTexture");
            if (mr != null) {
                const t = this.texture(mr, false);
                m.metalnessMap = t;
                m.roughnessMap = t;
            }
            const normalTex = dget(def, "normalTexture");
            if (normalTex != null) {
                m.normalMap = this.texture(normalTex, false);
                const scale = num(normalTex, "scale", 1);
                // As three.js without tangents: glTF's v runs down.
                m.normalScale.set(scale, -scale);
            }
            const occlusion = dget(def, "occlusionTexture");
            if (occlusion != null) {
                m.aoMap = this.texture(occlusion, false);
                m.aoMapIntensity = num(occlusion, "strength", 1);
            }
            const emissive = Dynamic.asNumbersOrNull(dget(def, "emissiveFactor"));
            if (emissive != null && emissive.length == 3) m.emissive.setRGB(emissive[0], emissive[1], emissive[2]);
            const emissiveTex = dget(def, "emissiveTexture");
            if (emissiveTex != null) m.emissiveMap = this.texture(emissiveTex, true);
            const strength = dget(ext, "KHR_materials_emissive_strength");
            if (strength != null) m.emissiveIntensity = num(strength, "emissiveStrength", 1);
            if (physical) {
                const p = m as MeshPhysicalMaterial;
                const cc = dget(ext, "KHR_materials_clearcoat");
                if (cc != null) {
                    p.clearcoat = num(cc, "clearcoatFactor", 0);
                    p.clearcoatRoughness = num(cc, "clearcoatRoughnessFactor", 0);
                    p.clearcoatMap = this.optTexture(dget(cc, "clearcoatTexture"), false);
                    p.clearcoatRoughnessMap = this.optTexture(dget(cc, "clearcoatRoughnessTexture"), false);
                    const ccn = dget(cc, "clearcoatNormalTexture");
                    if (ccn != null) {
                        p.clearcoatNormalMap = this.texture(ccn, false);
                        const scale = num(ccn, "scale", 1);
                        p.clearcoatNormalScale.set(scale, -scale);
                    }
                }
                const sheen = dget(ext, "KHR_materials_sheen");
                if (sheen != null) {
                    p.sheen = 1;
                    const sc = Dynamic.asNumbersOrNull(dget(sheen, "sheenColorFactor"));
                    if (sc != null && sc.length == 3) p.sheenColor.setRGB(sc[0], sc[1], sc[2]);
                    p.sheenRoughness = num(sheen, "sheenRoughnessFactor", 0);
                    p.sheenColorMap = this.optTexture(dget(sheen, "sheenColorTexture"), true);
                    p.sheenRoughnessMap = this.optTexture(dget(sheen, "sheenRoughnessTexture"), false);
                }
                const ior = dget(ext, "KHR_materials_ior");
                if (ior != null) p.ior = num(ior, "ior", 1.5);
                const spec = dget(ext, "KHR_materials_specular");
                if (spec != null) {
                    p.specularIntensity = num(spec, "specularFactor", 1);
                    const sc = Dynamic.asNumbersOrNull(dget(spec, "specularColorFactor"));
                    if (sc != null && sc.length == 3) p.specularColor.setRGB(sc[0], sc[1], sc[2]);
                    p.specularIntensityMap = this.optTexture(dget(spec, "specularTexture"), false);
                    p.specularColorMap = this.optTexture(dget(spec, "specularColorTexture"), true);
                }
                const tr = dget(ext, "KHR_materials_transmission");
                if (tr != null) {
                    p.transmission = num(tr, "transmissionFactor", 0);
                    p.transmissionMap = this.optTexture(dget(tr, "transmissionTexture"), false);
                }
                const volume = dget(ext, "KHR_materials_volume");
                if (volume != null) {
                    p.thickness = num(volume, "thicknessFactor", 0);
                    p.thicknessMap = this.optTexture(dget(volume, "thicknessTexture"), false);
                    p.attenuationDistance = num(volume, "attenuationDistance", Infinity);
                    const ac = Dynamic.asNumbersOrNull(dget(volume, "attenuationColor"));
                    if (ac != null && ac.length == 3) p.attenuationColor.setRGB(ac[0], ac[1], ac[2]);
                }
                const irid = dget(ext, "KHR_materials_iridescence");
                if (irid != null) {
                    p.iridescence = num(irid, "iridescenceFactor", 0);
                    p.iridescenceIOR = num(irid, "iridescenceIor", 1.3);
                    p.iridescenceThicknessRange = [num(irid, "iridescenceThicknessMinimum", 100),
                        num(irid, "iridescenceThicknessMaximum", 400)];
                    p.iridescenceMap = this.optTexture(dget(irid, "iridescenceTexture"), false);
                    p.iridescenceThicknessMap = this.optTexture(dget(irid, "iridescenceThicknessTexture"), false);
                }
                const aniso = dget(ext, "KHR_materials_anisotropy");
                if (aniso != null) {
                    p.anisotropy = num(aniso, "anisotropyStrength", 0);
                    p.anisotropyRotation = num(aniso, "anisotropyRotation", 0);
                    p.anisotropyMap = this.optTexture(dget(aniso, "anisotropyTexture"), false);
                }
                const dispersion = dget(ext, "KHR_materials_dispersion");
                if (dispersion != null) p.dispersion = num(dispersion, "dispersion", 0);
            }
            material = m;
        }
        material.name = str(def, "name", "");
        const alphaMode = str(def, "alphaMode", "OPAQUE");
        if (alphaMode == "BLEND") {
            material.transparent = true;
            material.depthWrite = false;
        } else {
            if (alphaMode == "MASK") material.alphaTest = num(def, "alphaCutoff", 0.5);
            // three.js: opaque glTF materials ignore base colour alpha.
            if (alphaMode == "OPAQUE") material.opacity = 1;
        }
        if (dbool(dget(def, "doubleSided"))) material.side = DoubleSide;
        return material;
    }

    /// The base colour of material `index`, for lines and points.
    private copyColor(index: i32, m: Material): void {
        const def = dat(dget(this.json, "materials"), index);
        const factor = Dynamic.asNumbersOrNull(dget(dget(def, "pbrMetallicRoughness"), "baseColorFactor"));
        if (factor == null || factor.length != 4) return;
        if (m instanceof LineBasicMaterial) (m as LineBasicMaterial).color.setRGB(factor[0], factor[1], factor[2]);
        else if (m instanceof PointsMaterial) (m as PointsMaterial).color.setRGB(factor[0], factor[1], factor[2]);
    }

    private optTexture(info: Dynamic?, srgb: bool): Texture? {
        return info != null ? this.texture(info, srgb) : null;
    }

    /// A textureInfo ({index, texCoord, extensions}) as a Texture.
    private texture(info: Dynamic?, srgb: bool): Texture? {
        const index = <i32>num(info, "index", -1);
        const textures = arr(this.json, "textures");
        if (index < 0 || index >= textures.length) return null;
        const tdef = textures[index];
        const transform = dget(dget(info, "extensions"), "KHR_texture_transform");
        let channel = <i32>num(info, "texCoord", 0);
        if (transform != null) channel = <i32>num(transform, "texCoord", <f64>channel);
        const key = index.toString() + (srgb ? "s" : "l") + channel.toString()
            + (transform != null ? Dynamic.toText(transform) : "");
        if (this.textures.has(key)) return this.textures.get(key);
        let source = <i32>num(tdef, "source", -1);
        const webp = dget(dget(tdef, "extensions"), "EXT_texture_webp");
        if (webp != null) source = <i32>num(webp, "source", <f64>source);
        const images = arr(this.json, "images");
        if (source < 0 || source >= images.length) return null;
        const texture = new DataTexture(new Uint8Array(0), 0, 0);
        texture.name = str(images[source], "name", "");
        texture.flipY = false;   // glTF uvs start at the top left
        texture.premultiplyAlpha = true;   // decoded images are premultiplied
        texture.colorSpace = srgb ? SRGBColorSpace : NoColorSpace;
        texture.generateMipmaps = true;
        texture.magFilter = LinearFilter;
        texture.minFilter = LinearMipmapLinearFilter;
        texture.wrapS = RepeatWrapping;
        texture.wrapT = RepeatWrapping;
        texture.channel = channel;
        const samplerIndex = <i32>num(tdef, "sampler", -1);
        const samplers = arr(this.json, "samplers");
        if (samplerIndex >= 0 && samplerIndex < samplers.length) {
            const s = samplers[samplerIndex];
            texture.magFilter = filterOf(<i32>num(s, "magFilter", 9729));
            texture.minFilter = filterOf(<i32>num(s, "minFilter", 9987));
            texture.wrapS = wrapOf(<i32>num(s, "wrapS", 10497));
            texture.wrapT = wrapOf(<i32>num(s, "wrapT", 10497));
        }
        if (transform != null) {
            const offset = Dynamic.asNumbersOrNull(dget(transform, "offset"));
            const scale = Dynamic.asNumbersOrNull(dget(transform, "scale"));
            if (offset != null && offset.length == 2) texture.offset.set(offset[0], offset[1]);
            if (scale != null && scale.length == 2) texture.repeat.set(scale[0], scale[1]);
            texture.rotation = num(transform, "rotation", 0);
        }
        this.decode(source, texture);
        this.textures.set(key, texture);
        return texture;
    }

    /// Starts decoding image `source` once; every texture of it fills in.
    private decode(source: i32, texture: DataTexture): void {
        if (this.decodes.has(source)) {
            this.decodes.get(source).textures.push(texture);
            return;
        }
        const context = this.context;
        if (context == null) return;   // parsing without a context: no images
        const listener = new TextureDecode(context);
        listener.textures.push(texture);
        this.decodes.set(source, listener);
        const image = dat(dget(this.json, "images"), source);
        const bv = <i32>num(image, "bufferView", -1);
        let bytes: Uint8Array? = null;
        if (bv >= 0) bytes = this.viewBytes(bv);
        else if (this.gd.externalImages.has(source)) bytes = this.gd.externalImages.get(source);
        else {
            const uri = str(image, "uri", "");
            if (uri.startsWith("data:")) bytes = decodeDataUri(uri);
        }
        if (bytes == null || bytes.length == 0) {
            this.warn("image " + source.toString() + " is missing (external files: see load / loadAsync)");
            return;
        }
        pendingDecodes.push(listener);
        context.decodeImage(bytes.slice().buffer, listener);
    }

    // ------------------------------------------------------------- cameras & lights

    private buildCamera(index: i32): Camera? {
        const def = dat(dget(this.json, "cameras"), index);
        if (def == null) return null;
        let camera: Camera;
        if (str(def, "type", "") == "orthographic") {
            const o = dget(def, "orthographic");
            const xmag = num(o, "xmag", 1), ymag = num(o, "ymag", 1);
            camera = new OrthographicCamera(-xmag, xmag, ymag, -ymag, num(o, "znear", 0.1), num(o, "zfar", 2000));
        } else {
            const p = dget(def, "perspective");
            camera = new PerspectiveCamera(num(p, "yfov", 0.8) * 180 / Math.PI, num(p, "aspectRatio", 1),
                num(p, "znear", 0.1), num(p, "zfar", 2e6));
        }
        camera.name = PropertyBinding.sanitizeNodeName(str(def, "name", ""));
        return camera;
    }

    private buildLight(index: i32): Light? {
        const lights = arr(dget(dget(this.json, "extensions"), "KHR_lights_punctual"), "lights");
        if (index < 0 || index >= lights.length) return null;
        const def = lights[index];
        const c = Dynamic.asNumbersOrNull(dget(def, "color"));
        const intensity = num(def, "intensity", 1);
        const range = num(def, "range", 0);
        const type = str(def, "type", "point");
        let light: Light;
        if (type == "directional") {
            const d = new DirectionalLight(0xFFFFFF, intensity);
            d.position.set(0, 0, 0);
            d.target.position.set(0, 0, -1);   // glTF lights point down -Z
            d.add(d.target);
            light = d;
        } else if (type == "spot") {
            const spot = dget(def, "spot");
            const outer = num(spot, "outerConeAngle", Math.PI / 4);
            const inner = num(spot, "innerConeAngle", 0);
            const s = new SpotLight(0xFFFFFF, intensity, range, outer, 1 - inner / outer, 2);
            s.position.set(0, 0, 0);
            s.target.position.set(0, 0, -1);
            s.add(s.target);
            light = s;
        } else {
            light = new PointLight(0xFFFFFF, intensity, range, 2);
        }
        if (c != null && c.length == 3) light.color.setRGB(c[0], c[1], c[2]);
        light.name = PropertyBinding.sanitizeNodeName(str(def, "name", ""));
        return light;
    }

    // ------------------------------------------------------------- animations

    private buildAnimation(index: i32, def: Dynamic?): AnimationClip? {
        const channels = arr(def, "channels");
        const samplers = arr(def, "samplers");
        const tracks: Array<KeyframeTrack> = [];
        for (let c = 0; c < channels.length; c++) {
            const target = dget(channels[c], "target");
            const nodeIndex = <i32>num(target, "node", -1);
            const samplerIndex = <i32>num(channels[c], "sampler", -1);
            if (nodeIndex < 0 || nodeIndex >= this.nodes.length || samplerIndex < 0 || samplerIndex >= samplers.length) continue;
            const sampler = samplers[samplerIndex];
            const input = this.floats(<i32>num(sampler, "input", -1));
            const output = this.floats(<i32>num(sampler, "output", -1));
            const mode = str(sampler, "interpolation", "LINEAR");
            const interpolation = mode == "STEP" ? InterpolateDiscrete
                : mode == "CUBICSPLINE" ? InterpolateGLTFCubicSpline : InterpolateLinear;
            const times = toArray(input);
            const values = toArray(output);
            const name = this.nodes[nodeIndex].name;
            const path = str(target, "path", "");
            if (path == "translation") tracks.push(new VectorKeyframeTrack(name + ".position", times, values, interpolation));
            else if (path == "rotation") tracks.push(new QuaternionKeyframeTrack(name + ".quaternion", times, values, interpolation));
            else if (path == "scale") tracks.push(new VectorKeyframeTrack(name + ".scale", times, values, interpolation));
            else if (path == "weights") this.weightTracks(nodeIndex, name, times, values, interpolation, tracks);
        }
        const name = str(def, "name", "animation_" + index.toString());
        return new AnimationClip(name, -1, tracks);
    }

    /// One NumberKeyframeTrack per morph target (glTF interleaves them).
    private weightTracks(nodeIndex: i32, name: string, times: Array<f64>, values: Array<f64>, interpolation: i32,
                         tracks: Array<KeyframeTrack>): void {
        const keys = times.length;
        if (keys == 0) return;
        const perKey = interpolation == InterpolateGLTFCubicSpline ? 3 : 1;
        const targets = values.length / (keys * perKey);
        // The node may be a group of primitives: bind on each mesh's own name.
        const meshes = this.meshesOf[nodeIndex];
        for (let t = 0; t < targets; t++) {
            const v: Array<f64> = [];
            for (let k = 0; k < keys; k++) {
                for (let e = 0; e < perKey; e++) v.push(values[(k * perKey + e) * targets + t]);
            }
            const track = name + ".morphTargetInfluences[" + t.toString() + "]";
            tracks.push(new NumberKeyframeTrack(track, times, v, interpolation));
            if (meshes.length > 1) {
                for (let m = 0; m < meshes.length; m++) {
                    if (meshes[m].name != name) {
                        tracks.push(new NumberKeyframeTrack(meshes[m].name + ".morphTargetInfluences[" + t.toString() + "]",
                            times, v, interpolation));
                    }
                }
            }
        }
    }
}

// ----------------------------------------------------------------- helpers

/// The bytes of a base64 data: URI (null when not base64).
function decodeDataUri(uri: string): Uint8Array? {
    const comma = uri.indexOf(",");
    if (comma < 0 || !uri.substring(0, comma).endsWith(";base64")) return null;
    return base64Decode(uri, comma + 1);
}

function base64Value(c: i32): i32 {
    if (c >= 65 && c <= 90) return c - 65;
    if (c >= 97 && c <= 122) return c - 71;
    if (c >= 48 && c <= 57) return c + 4;
    if (c == 43 || c == 45) return 62;
    if (c == 47 || c == 95) return 63;
    return -1;
}

export function base64Decode(text: string, start: i32 = 0): Uint8Array {
    const out = new Uint8Array((text.length - start) * 3 / 4 + 3);
    let n = 0, acc: u32 = 0, bits = 0;
    for (let i = start; i < text.length; i++) {
        const v = base64Value(text.charCodeAt(i));
        if (v < 0) continue;   // padding, whitespace
        acc = (acc << 6) | <u32>v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = <u8>((acc >> <u32>bits) & 255);
        }
    }
    return out.slice(0, n);
}

/// Dynamic.get, but null for a null or non-table value (Dynamic.get traps).
function dget(value: Dynamic?, key: string): Dynamic? {
    if (value == null || Dynamic.typeName(value) != "table") return null;
    return Dynamic.get(value, key);
}

/// Dynamic.asBool, false for null (Dynamic.asBool traps on null).
function dbool(value: Dynamic?): bool {
    return value != null && Dynamic.typeName(value) == "boolean" && Dynamic.asBool(value);
}

function dnumbers(value: Dynamic?): Array<f64> {
    const a = Dynamic.asNumbersOrNull(value);
    return a != null ? a : [];
}

function dat(value: Dynamic?, index: i32): Dynamic? {
    if (value == null || Dynamic.typeName(value) != "table") return null;
    if (index < 0 || <f64>index >= Dynamic.length(value)) return null;
    return Dynamic.at(value, index);
}

function arr(value: Dynamic?, key: string): Array<Dynamic?> {
    const a = Dynamic.asArrayOrNull(dget(value, key));
    return a != null ? a : [];
}

function num(value: Dynamic?, key: string, fallback: f64): f64 {
    const n = Dynamic.asNumberOrNull(dget(value, key));
    return n != null ? n.value : fallback;
}

function str(value: Dynamic?, key: string, fallback: string): string {
    const s = Dynamic.asStringOrNull(dget(value, key));
    return s != null ? s : fallback;
}

function components(type: string): i32 {
    if (type == "VEC2") return 2;
    if (type == "VEC3") return 3;
    if (type == "VEC4") return 4;
    if (type == "MAT2") return 4;
    if (type == "MAT3") return 9;
    if (type == "MAT4") return 16;
    return 1;
}

function componentSize(ct: i32): i32 {
    if (ct == 5120 || ct == 5121) return 1;
    if (ct == 5122 || ct == 5123) return 2;
    return 4;
}

function u32At(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

function readComponent(b: Uint8Array, at: i32, ct: i32, normalized: bool): f64 {
    if (ct == 5126) return <f64>reinterpret<f32>(u32At(b, at));
    if (ct == 5125) return <f64>u32At(b, at);
    if (ct == 5121) {
        const v: f64 = b[at];
        return normalized ? v / 255 : v;
    }
    if (ct == 5123) {
        const v: f64 = <u32>b[at] | (<u32>b[at + 1] << 8);
        return normalized ? v / 65535 : v;
    }
    if (ct == 5120) {
        const v: f64 = <i8>b[at];
        return normalized ? Math.max(v / 127, -1) : v;
    }
    if (ct == 5122) {
        const v: f64 = <i16>(<u32>b[at] | (<u32>b[at + 1] << 8));
        return normalized ? Math.max(v / 32767, -1) : v;
    }
    return 0;
}

function toArray(f: Float32Array): Array<f64> {
    const out = new Array<f64>(f.length);
    for (let i = 0; i < f.length; i++) out[i] = f[i];
    return out;
}

/// TRIANGLE_STRIP / TRIANGLE_FAN to a triangle list index.
function toTriangles(index: Array<i32>?, vertexCount: i32, fan: bool): Array<i32> {
    const n = index != null ? index.length : vertexCount;
    const out: Array<i32> = [];
    for (let i = 0; i + 2 < n; i++) {
        const a = index != null ? index[i] : i;
        const b = index != null ? index[i + 1] : i + 1;
        const c = index != null ? index[i + 2] : i + 2;
        if (fan) {
            const f = index != null ? index[0] : 0;
            out.push(f); out.push(b); out.push(c);
        } else if (i % 2 == 0) {
            out.push(a); out.push(b); out.push(c);
        } else {
            out.push(b); out.push(a); out.push(c);
        }
    }
    return out;
}

function filterOf(f: i32): i32 {
    if (f == 9728) return NearestFilter;
    if (f == 9729) return LinearFilter;
    if (f == 9984) return NearestMipmapNearestFilter;
    if (f == 9985) return LinearMipmapNearestFilter;
    if (f == 9986) return NearestMipmapLinearFilter;
    return LinearMipmapLinearFilter;
}

function wrapOf(w: i32): i32 {
    if (w == 33071) return ClampToEdgeWrapping;
    if (w == 33648) return MirroredRepeatWrapping;
    return RepeatWrapping;
}

const _m: Matrix4 = new Matrix4();
