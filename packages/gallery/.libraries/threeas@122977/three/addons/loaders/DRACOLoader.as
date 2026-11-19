// three.js's DRACOLoader addon (examples/jsm/loaders/DRACOLoader.js, r170),
// for Rive: decodes Draco-compressed geometry (.drc files, and glTF's
// KHR_draco_mesh_compression through GLTFLoader.setDRACOLoader) to a
// BufferGeometry.
//
//     const loader = new DRACOLoader(context);
//     const geometry = loader.load("bunny");          // the BlobAsset's name, at once
//     // or, decoding in a Rive job:
//     const settled = await loader.loadAsync("bunny").settled();
//
// The decoder is Google's Draco decoder ported to AnimaScript
// (three/addons/libs/draco), not draco_decoder.js / .wasm in Web Workers:
// setDecoderPath, setDecoderConfig, setWorkerLimit and preload are kept and
// do nothing, and the asynchronous paths decode in a Rive job (decodeDraco)
// instead of a worker. Every attribute is a Float32Array (as ThreeAS's
// BufferAttribute): integer attribute types convert, and normalized ones
// (colours from .drc files, normalized glTF accessors) scale to [0, 1].

import { Context } from "rive/host";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Uint32BufferAttribute } from "../../core/BufferAttribute";
import { SRGBToLinear } from "../../math/Color";
import { LinearSRGBColorSpace, SRGBColorSpace } from "../../constants";
import {
    Decoder, Mesh as DracoMesh, PointCloud as DracoPointCloud, PointAttribute as DracoPointAttribute,
    POSITION, NORMAL, COLOR, TEX_COORD, GENERIC, TRIANGULAR_MESH, POINT_CLOUD,
    DT_FLOAT32, DT_INT8, DT_INT16, DT_INT32, DT_UINT8, DT_UINT16, DT_UINT32,
} from "../libs/draco/draco_decoder";

/// three.js's decoderConfig ({ type: 'js' | 'wasm' }); kept, unused.
export class DRACODecoderConfig {
    type: string = "";
}

/// three.js's taskConfig, as arrays (a Map does not cross to a job): one
/// entry per attribute to decode, by three.js name.
export class DRACOTaskConfig {
    attributeNames: Array<string> = [];
    /// Draco attribute types (POSITION ...) by default, or the unique ids
    /// a glTF maps its attributes to (`useUniqueIDs`).
    attributeIDs: Array<i32> = [];
    /// "Float32Array", "Uint8Array", ...
    attributeTypes: Array<string> = [];
    /// Whether each attribute's integers are normalized (scaled to [0, 1]
    /// or [-1, 1]); when empty, only "color" is, as three.js.
    attributeNormalized: Array<bool> = [];
    useUniqueIDs: bool = false;
    vertexColorSpace: string = LinearSRGBColorSpace;
}

/// The decoded geometry (three.js's message.geometry), crossing back from
/// the job: attributes as floats, already normalized where they should be.
export class DRACOGeometryData {
    error: string = "";
    hasIndex: bool = false;
    index: Uint32Array = new Uint32Array(0);
    names: Array<string> = [];
    arrays: Array<Float32Array> = [];
    itemSizes: Array<i32> = [];
}

export class DRACOLoader extends Loader {
    decoderPath: string = "";
    decoderConfig: DRACODecoderConfig = new DRACODecoderConfig();
    workerLimit: i32 = 4;
    /// three.js names to Draco attribute types, for .drc files.
    defaultAttributeIDs: Map<string, string> = new Map<string, string>();
    defaultAttributeTypes: Map<string, string> = new Map<string, string>();
    /// Why the last decode failed ("" when it did not); three.js rejects
    /// with it.
    error: string = "";

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
        this.defaultAttributeIDs.set("position", "POSITION");
        this.defaultAttributeIDs.set("normal", "NORMAL");
        this.defaultAttributeIDs.set("color", "COLOR");
        this.defaultAttributeIDs.set("uv", "TEX_COORD");
        this.defaultAttributeTypes.set("position", "Float32Array");
        this.defaultAttributeTypes.set("normal", "Float32Array");
        this.defaultAttributeTypes.set("color", "Float32Array");
        this.defaultAttributeTypes.set("uv", "Float32Array");
    }

    /// Kept for three.js's API: the decoder is built in, no path to set.
    setDecoderPath(path: string): DRACOLoader {
        this.decoderPath = path;
        return this;
    }

    /// Kept for three.js's API: there is one decoder (no 'js' / 'wasm').
    setDecoderConfig(config: DRACODecoderConfig): DRACOLoader {
        this.decoderConfig = config;
        return this;
    }

    /// Kept for three.js's API: Rive's job pool sizes itself.
    setWorkerLimit(workerLimit: i32): DRACOLoader {
        this.workerLimit = workerLimit;
        return this;
    }

    /// Kept for three.js's API: nothing to fetch ahead.
    preload(): DRACOLoader { return this; }

    /// Kept for three.js's API: no workers to end.
    dispose(): DRACOLoader { return this; }

    /// Loads the BlobAsset called `name` (`path` + name) and decodes it at
    /// once (three.js's load(url, onLoad), without the callbacks); null,
    /// with `error`, when it is missing or does not decode. Urls need
    /// loadAsync.
    load(name: string): BufferGeometry? {
        const context = this.context;
        const bytesAsset = context != null ? context.blob(this.path + name) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            this.fail("no blob asset named '" + this.path + name + "'");
            return null;
        }
        return this.parse(bytes!);
    }

    /// Loads `url` (an https: url where the host allows the network, else
    /// the blob asset of that name) and decodes it in a Rive job.
    loadAsync(url: string): Promise<BufferGeometry> {
        return loadInJob(this, url);
    }

    /// Decodes .drc bytes at once (three.js's parse(buffer, onLoad,
    /// onError)): positions, normals, colours (sRGB, converted to linear,
    /// as three.js) and uvs by Draco attribute type.
    parse(buffer: ArrayBuffer): BufferGeometry? {
        return this.decodeDracoFile(buffer, null, null, SRGBColorSpace);
    }

    /// As parse, decoding in a Rive job.
    parseAsync(buffer: ArrayBuffer): Promise<BufferGeometry> {
        return this.decodeGeometry(buffer, this.taskConfig(null, null, SRGBColorSpace));
    }

    /// three.js's decodeDracoFile, returning the geometry (null and
    /// `error` on failure) instead of calling back. `attributeIDs` maps
    /// three.js attribute names to the unique ids of the file's attributes
    /// (glTF's KHR_draco_mesh_compression map); without it, attributes are
    /// read by type (defaultAttributeIDs). `attributeTypes` maps names to
    /// typed array names ("Float32Array" when missing).
    decodeDracoFile(buffer: ArrayBuffer, attributeIDs: Map<string, i32>? = null,
                    attributeTypes: Map<string, string>? = null,
                    vertexColorSpace: string = LinearSRGBColorSpace): BufferGeometry? {
        const data = decodeDracoGeometry(buffer, this.taskConfig(attributeIDs, attributeTypes, vertexColorSpace));
        if (data.error.length > 0) {
            this.fail(data.error);
            return null;
        }
        this.error = "";
        return this.createGeometry(data);
    }

    /// three.js's decodeGeometry(buffer, taskConfig): decodes in a Rive job
    /// (decodeDraco), the geometry built when it is done.
    decodeGeometry(buffer: ArrayBuffer, taskConfig: DRACOTaskConfig): Promise<BufferGeometry> {
        return decodeInJob(this, buffer, taskConfig);
    }

    /// The task config for decodeDracoFile's arguments.
    taskConfig(attributeIDs: Map<string, i32>?, attributeTypes: Map<string, string>?,
               vertexColorSpace: string): DRACOTaskConfig {
        const config = new DRACOTaskConfig();
        config.vertexColorSpace = vertexColorSpace;
        if (attributeIDs != null) {
            config.useUniqueIDs = true;
            const names = attributeIDs.keys();
            for (let i = 0; i < names.length; i++) {
                config.attributeNames.push(names[i]);
                config.attributeIDs.push(attributeIDs.get(names[i]));
            }
        } else {
            const names = this.defaultAttributeIDs.keys();
            for (let i = 0; i < names.length; i++) {
                config.attributeNames.push(names[i]);
                config.attributeIDs.push(dracoAttributeType(this.defaultAttributeIDs.get(names[i])));
            }
        }
        const types = attributeTypes != null ? attributeTypes : this.defaultAttributeTypes;
        for (let i = 0; i < config.attributeNames.length; i++) {
            const name = config.attributeNames[i];
            config.attributeTypes.push(types.has(name) ? types.get(name) : "Float32Array");
        }
        return config;
    }

    /// three.js's _createGeometry.
    createGeometry(data: DRACOGeometryData): BufferGeometry {
        const geometry = new BufferGeometry();
        if (data.hasIndex) {
            const index = new Uint32BufferAttribute([]);
            index.array = data.index;
            geometry.setIndexAttribute(index);
        }
        for (let i = 0; i < data.names.length; i++) {
            geometry.setAttribute(data.names[i], new BufferAttribute(data.arrays[i], data.itemSizes[i]));
        }
        return geometry;
    }

    private fail(message: string): void {
        this.error = message;
        const context = this.context;
        if (context != null) context.log("three: DRACOLoader: " + message);
    }
}

async function loadInJob(loader: DRACOLoader, url: string): Promise<BufferGeometry> {
    const settled = await fetchBytes(loader, url).settled();
    if (!settled.ok) {
        loader.error = settled.error;
        return await Promise.reject<BufferGeometry>(settled.error);
    }
    return await decodeInJob(loader, settled.value, loader.taskConfig(null, null, SRGBColorSpace));
}

async function decodeInJob(loader: DRACOLoader, buffer: ArrayBuffer, taskConfig: DRACOTaskConfig): Promise<BufferGeometry> {
    const data = await Jobs.run(decodeDraco, buffer, taskConfig).promise();
    if (data.error.length > 0) {
        loader.error = data.error;
        return await Promise.reject<BufferGeometry>(data.error);
    }
    loader.error = "";
    return loader.createGeometry(data);
}

/// The job behind loadAsync, parseAsync and decodeGeometry: decodes off
/// the main lane (three.js's worker).
@job export function decodeDraco(buffer: ArrayBuffer, taskConfig: DRACOTaskConfig): DRACOGeometryData {
    return decodeDracoGeometry(buffer, taskConfig);
}

/// The worker's decodeGeometry: pure code, for the main lane and jobs.
export function decodeDracoGeometry(buffer: ArrayBuffer, taskConfig: DRACOTaskConfig): DRACOGeometryData {
    const out = new DRACOGeometryData();
    const array = Uint8Array.wrap(buffer);
    const decoder = new Decoder();
    const geometryType = decoder.GetEncodedGeometryType(array);
    let dracoGeometry: DracoPointCloud;
    let status: string;
    if (geometryType == TRIANGULAR_MESH) {
        const mesh = new DracoMesh();
        status = decoder.DecodeArrayToMesh(array, array.length, mesh).error_msg();
        dracoGeometry = mesh;
    } else if (geometryType == POINT_CLOUD) {
        dracoGeometry = new DracoPointCloud();
        status = decoder.DecodeArrayToPointCloud(array, array.length, dracoGeometry).error_msg();
    } else {
        out.error = "Unexpected geometry type.";
        return out;
    }
    if (status.length > 0) {
        out.error = "Decoding failed: " + status;
        return out;
    }
    for (let i = 0; i < taskConfig.attributeNames.length; i++) {
        const name = taskConfig.attributeNames[i];
        const id = taskConfig.attributeIDs[i];
        let attribute: DracoPointAttribute? = null;
        if (taskConfig.useUniqueIDs) {
            attribute = decoder.GetAttributeByUniqueId(dracoGeometry, <u32>id);
            if (attribute == null) continue;
        } else {
            const attributeID = decoder.GetAttributeId(dracoGeometry, id);
            if (attributeID == -1) continue;
            attribute = decoder.GetAttribute(dracoGeometry, attributeID);
        }
        const type = i < taskConfig.attributeTypes.length ? taskConfig.attributeTypes[i] : "Float32Array";
        const values = decodeAttribute(decoder, dracoGeometry, attribute!, type);
        if (values == null) {
            out.error = "Decoding failed: attribute '" + name + "' does not convert to " + type;
            return out;
        }
        // three.js keeps normalized integers as they are, flagged
        // `normalized`; floats here, so they scale.
        const normalized = i < taskConfig.attributeNormalized.length ? taskConfig.attributeNormalized[i] : name == "color";
        const dt = dataTypeOf(type);
        if (normalized && dt != DT_FLOAT32) {
            const scale = 1.0 / typeMax(dt);
            // Signed values clamp at -1, as WebGL's normalization does.
            for (let k = 0; k < values.length; k++) values[k] = <f32>Math.max(<f64>values[k] * scale, -1);
        }
        if (name == "color") {
            if (taskConfig.vertexColorSpace == SRGBColorSpace) {
                const n = attribute!.numComponents;
                for (let k = 0; k < values.length; k++) {
                    if (k % n < 3) values[k] = <f32>SRGBToLinear(<f64>values[k]);
                }
            }
        }
        out.names.push(name);
        out.arrays.push(values);
        out.itemSizes.push(attribute!.numComponents);
    }
    if (geometryType == TRIANGULAR_MESH) {
        out.hasIndex = true;
        out.index = decoder.GetTrianglesUInt32Array(dracoGeometry as DracoMesh);
    }
    return out;
}

/// The worker's decodeAttribute: every point's value in the asked type, as
/// floats.
function decodeAttribute(decoder: Decoder, geometry: DracoPointCloud, attribute: DracoPointAttribute,
                         type: string): Float32Array? {
    const dt = dataTypeOf(type);
    if (dt == DT_FLOAT32) return decoder.GetAttributeFloatForAllPoints(geometry, attribute);
    const values = decoder.GetAttributeDataArrayForAllPoints(geometry, attribute, dt);
    if (values == null) return null;
    const out = new Float32Array(values.length);
    for (let i = 0; i < values.length; i++) out[i] = <f32>values[i];
    return out;
}

/// getDracoDataType, by typed array name.
export function dataTypeOf(type: string): i32 {
    if (type == "Int8Array") return DT_INT8;
    if (type == "Int16Array") return DT_INT16;
    if (type == "Int32Array") return DT_INT32;
    if (type == "Uint8Array") return DT_UINT8;
    if (type == "Uint16Array") return DT_UINT16;
    if (type == "Uint32Array") return DT_UINT32;
    return DT_FLOAT32;
}

/// The largest value of an integer data type (normalization's divisor).
export function typeMax(dt: i32): f64 {
    if (dt == DT_INT8) return 127;
    if (dt == DT_UINT8) return 255;
    if (dt == DT_INT16) return 32767;
    if (dt == DT_UINT16) return 65535;
    if (dt == DT_INT32) return 2147483647;
    if (dt == DT_UINT32) return 4294967295;
    return 1;
}

function dracoAttributeType(name: string): i32 {
    if (name == "POSITION") return POSITION;
    if (name == "NORMAL") return NORMAL;
    if (name == "COLOR") return COLOR;
    if (name == "TEX_COORD") return TEX_COORD;
    if (name == "GENERIC") return GENERIC;
    return -1;
}
