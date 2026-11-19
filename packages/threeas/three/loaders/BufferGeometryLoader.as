// three.js BufferGeometryLoader: a BufferGeometry from three.js's JSON
// (BufferGeometry.toJSON's `data`: attributes, index, morph attributes,
// groups, bounding sphere; interleaved buffers too).
//
// Attributes are Float32 here: integer arrays are converted, normalized
// ones to their [0, 1] / [-1, 1] values (then `normalized` is false);
// interleaved attributes are read de-interleaved.

import { Context } from "rive/host";
import { Dynamic, DynamicKind } from "rive/dynamic";
import { Promise } from "rive/promise";
import { Loader } from "./Loader";
import { LoadingManager } from "./LoadingManager";
import { LoaderUtils } from "./LoaderUtils";
import { fetchBytes } from "./FileLoader";
import { JSON, jget, jhas, jnum, jint, jbool, jstr, jarr, jnumbers } from "../core/JSON";
import { BufferGeometry } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
import { InstancedBufferAttribute } from "../core/InstancedBufferAttribute";
import { Sphere } from "../math/Sphere";
import { Vector3 } from "../math/Vector3";

export class BufferGeometryLoader extends Loader {
    /// Problems met by the last parse.
    warnings: Array<string> = [];

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The geometry in the BlobAsset `name` (JSON text), or null.
    load(name: string): BufferGeometry? {
        const context = this.context;
        const full = LoaderUtils.resolveURL(name, this.path);
        const bytesAsset = context != null ? context.blob(full) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            this.warn("no blob asset named '" + full + "'");
            return null;
        }
        return this.parse<string>(String.UTF8.decode(bytes!));
    }

    /// The geometry at `url` (an https: url, else a blob asset).
    loadAsync(url: string): Promise<BufferGeometry> {
        return loadGeometryAsync(this, url);
    }

    /// A geometry from three.js's JSON: the text (a string) or its parsed
    /// `Dynamic`. Null when the text is not JSON.
    parse<T>(json: T): BufferGeometry? {
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
        return this.parseGeometry(data);
    }

    private parseGeometry(json: Dynamic?): BufferGeometry {
        this.warnings = [];
        const geometry = new BufferGeometry();
        const data = jget(json, "data");
        const index = jget(data, "index");
        if (index != null) {
            const values = jnumbers(index, "array");
            if (values != null) {
                const indices = new Array<i32>(values.length);
                for (let i = 0; i < values.length; i++) indices[i] = <i32>values[i];
                geometry.setIndex(indices);
            }
        }
        const attributes = jget(data, "attributes");
        if (attributes != null && attributes.kind == DynamicKind.table) {
            const map = Dynamic.asMap(attributes);
            const names = map.keys();
            for (let i = 0; i < names.length; i++) {
                const attribute = this.parseAttribute(map.get(names[i]), data);
                if (attribute != null) geometry.setAttribute(names[i], attribute!);
            }
        }
        const morphAttributes = jget(data, "morphAttributes");
        if (morphAttributes != null && morphAttributes.kind == DynamicKind.table) {
            const map = Dynamic.asMap(morphAttributes);
            const names = map.keys();
            for (let i = 0; i < names.length; i++) {
                const list = Dynamic.asArray(map.get(names[i]));
                const out: Array<BufferAttribute> = [];
                for (let j = 0; j < list.length; j++) {
                    const attribute = this.parseAttribute(list[j], data);
                    if (attribute != null) out.push(attribute!);
                }
                geometry.morphAttributes.set(names[i], out);
            }
        }
        if (jbool(data, "morphTargetsRelative", false)) geometry.morphTargetsRelative = true;
        let groups = jarr(data, "groups");
        if (groups.length == 0) groups = jarr(data, "drawcalls");
        if (groups.length == 0) groups = jarr(data, "offsets");
        for (let i = 0; i < groups.length; i++) {
            const g = groups[i];
            geometry.addGroup(jint(g, "start", 0), jint(g, "count", 0), jint(g, "materialIndex", 0));
        }
        const boundingSphere = jget(data, "boundingSphere");
        if (boundingSphere != null) {
            const center = new Vector3();
            const c = jnumbers(boundingSphere, "center");
            if (c != null && c.length >= 3) center.set(c[0], c[1], c[2]);
            geometry.boundingSphere = new Sphere(center, jnum(boundingSphere, "radius", 0));
        }
        const name = jstr(json, "name", "");
        if (name.length > 0) geometry.name = name;
        const userData = jget(json, "userData");
        if (userData != null) geometry.userData = userData!;
        return geometry;
    }

    /// One attribute: { itemSize, type, array, normalized, name }, an
    /// instanced one, or an interleaved one (read from `data`'s
    /// interleavedBuffers and arrayBuffers).
    private parseAttribute(json: Dynamic?, data: Dynamic?): BufferAttribute? {
        const itemSize = jint(json, "itemSize", 1);
        const normalized = jbool(json, "normalized", false);
        let values: Array<f64>;
        let type: string;
        if (jbool(json, "isInterleavedBufferAttribute", false)) {
            const buffer = jget(jget(data, "interleavedBuffers"), jstr(json, "data", ""));
            if (buffer == null) {
                this.warn("missing interleaved buffer " + jstr(json, "data", ""));
                return null;
            }
            type = jstr(buffer, "type", "Float32Array");
            const words = jnumbers(jget(data, "arrayBuffers"), jstr(buffer, "buffer", ""));
            if (words == null) {
                this.warn("missing array buffer " + jstr(buffer, "buffer", ""));
                return null;
            }
            const all = typedValues(type, words!);
            const stride = jint(buffer, "stride", itemSize);
            const offset = jint(json, "offset", 0);
            const count = stride > 0 ? all.length / stride : 0;
            values = new Array<f64>(count * itemSize);
            for (let i = 0; i < count; i++) {
                for (let k = 0; k < itemSize; k++) values[i * itemSize + k] = all[i * stride + offset + k];
            }
        } else {
            type = jstr(json, "type", "Float32Array");
            const a = jnumbers(json, "array");
            values = a != null ? a! : [];
        }
        const f = new Float32Array(values.length);
        const scale = normalized ? normalizedScale(type) : 0;
        for (let i = 0; i < values.length; i++) {
            const v = values[i];
            f[i] = <f32>(scale > 0 ? Math.max(v / scale, -1) : v);
        }
        const keepNormalized = normalized && scale == 0;
        let attribute: BufferAttribute;
        if (jbool(json, "isInstancedBufferAttribute", false)) {
            attribute = new InstancedBufferAttribute(f, itemSize, keepNormalized, jint(json, "meshPerAttribute", 1));
        } else {
            attribute = new BufferAttribute(f, itemSize, keepNormalized);
        }
        if (jhas(json, "name")) attribute.name = jstr(json, "name", "");
        return attribute;
    }

    private warn(message: string): void {
        this.warnings.push(message);
        const context = this.context;
        if (context != null) context.log("three: BufferGeometryLoader: " + message);
    }
}

async function loadGeometryAsync(loader: BufferGeometryLoader, url: string): Promise<BufferGeometry> {
    const settled = await fetchBytes(loader, url).settled();
    if (!settled.ok) return await Promise.reject<BufferGeometry>(settled.error);
    const geometry = loader.parse<string>(String.UTF8.decode(settled.value));
    if (geometry == null) return await Promise.reject<BufferGeometry>("not a geometry JSON: " + url);
    return geometry!;
}

/// The divisor turning a normalized integer of `type` into a float (0 for
/// float types).
function normalizedScale(type: string): f64 {
    if (type == "Int8Array") return 127;
    if (type == "Uint8Array" || type == "Uint8ClampedArray") return 255;
    if (type == "Int16Array") return 32767;
    if (type == "Uint16Array") return 65535;
    if (type == "Int32Array") return 2147483647;
    if (type == "Uint32Array") return 4294967295;
    return 0;
}

/// The values of an ArrayBuffer three.js wrote as uint32 words, read as a
/// `type` array (little endian).
function typedValues(type: string, words: Array<f64>): Array<f64> {
    const u32 = new Uint32Array(words.length);
    for (let i = 0; i < words.length; i++) u32[i] = <u32>words[i];
    const bytes = Uint8Array.wrap(u32.buffer);
    const out: Array<f64> = [];
    if (type == "Float32Array") {
        const a = Float32Array.wrap(u32.buffer);
        for (let i = 0; i < a.length; i++) out.push(<f64>a[i]);
    } else if (type == "Uint8Array" || type == "Uint8ClampedArray") {
        for (let i = 0; i < bytes.length; i++) out.push(<f64>bytes[i]);
    } else if (type == "Int8Array") {
        for (let i = 0; i < bytes.length; i++) out.push(<f64><i8>bytes[i]);
    } else if (type == "Uint16Array" || type == "Int16Array") {
        const a = Uint16Array.wrap(u32.buffer);
        for (let i = 0; i < a.length; i++) out.push(type == "Int16Array" ? <f64><i16>a[i] : <f64>a[i]);
    } else if (type == "Int32Array") {
        for (let i = 0; i < u32.length; i++) out.push(<f64><i32>u32[i]);
    } else {
        for (let i = 0; i < u32.length; i++) out.push(<f64>u32[i]);
    }
    return out;
}
