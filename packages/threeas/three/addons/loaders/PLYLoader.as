// three.js's PLYLoader addon: ASCII and binary (little and big endian) PLY
// to a BufferGeometry: positions, normals, uvs, vertex colours, faces
// (triangles and quads), per-face uvs and colours, and custom vertex
// properties (setCustomPropertyNameMapping).
//
//     const geometry = new PLYLoader(context).load("bunny");    // a BlobAsset

import { Context } from "rive/host";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Blob } from "rive/shared";
import { BinaryReader } from "rive/binary_reader";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Float32BufferAttribute } from "../../core/BufferAttribute";
import { Color } from "../../math/Color";
import { SRGBColorSpace } from "../../constants";

class PLYProperty {
    type: string = "";
    name: string = "";
    countType: string = "";
    itemType: string = "";
}

class PLYElementDesc {
    name: string = "";
    count: i32 = 0;
    properties: Array<PLYProperty> = [];
}

/// The parsed header (three.js's header object).
export class PLYHeader {
    format: string = "";
    version: string = "";
    comments: Array<string> = [];
    elements: Array<PLYElementDesc> = [];
    headerLength: i32 = 0;
    objInfo: string = "";
}

/// One element's values: scalars and lists by property name.
class PLYElement {
    values: Map<string, f64> = new Map<string, f64>();
    lists: Map<string, Array<f64>> = new Map<string, Array<f64>>();

    get(name: string): f64 { return this.values.has(name) ? this.values.get(name) : 0; }
}

class AttributeMap {
    x: string = "x"; y: string = "y"; z: string = "z";
    nx: string? = null; ny: string? = null; nz: string? = null;
    s: string? = null; t: string? = null;
    r: string? = null; g: string? = null; b: string? = null;
}

class PLYBuffer {
    indices: Array<i32> = [];
    vertices: Array<f64> = [];
    normals: Array<f64> = [];
    uvs: Array<f64> = [];
    faceVertexUvs: Array<f64> = [];
    colors: Array<f64> = [];
    faceVertexColors: Array<f64> = [];
    custom: Map<string, Array<f64>> = new Map<string, Array<f64>>();
}

/// What `decodePLY` hands back from a Rive job: packed float attributes in a
/// shared Blob, indices, and any custom attribute metadata.
export class PLYDecoded {
    blob: Blob? = null;
    indices: Int32Array = new Int32Array(0);
    /// Float counts in `blob`: [vertices, normals, uvs, colors, faceVertexUvs, faceVertexColors].
    counts: Int32Array = new Int32Array(6);
    customNames: Array<string> = [];
    customItemSizes: Int32Array = new Int32Array(0);
    customCounts: Int32Array = new Int32Array(0);
}

/// Decodes ASCII or binary PLY off the main lane (the job behind loadAsync /
/// parseAsync).
@job export function decodePLY(
    data: ArrayBuffer,
    propMapKeys: Array<string> = [],
    propMapVals: Array<string> = [],
    customNames: Array<string> = [],
    customPropCounts: Int32Array = new Int32Array(0),
    customPropNames: Array<string> = [],
): PLYDecoded {
    const propMap = new Map<string, string>();
    for (let i = 0; i < propMapKeys.length && i < propMapVals.length; i++) {
        propMap.set(propMapKeys[i], propMapVals[i]);
    }
    const customMap = new Map<string, Array<string>>();
    let pOff = 0;
    for (let i = 0; i < customNames.length && i < customPropCounts.length; i++) {
        const cnt = customPropCounts[i];
        const props: Array<string> = [];
        for (let j = 0; j < cnt && pOff < customPropNames.length; j++) props.push(customPropNames[pOff++]);
        customMap.set(customNames[i], props);
    }
    const buf = parsePLYBuffer(data, propMap, customMap);
    const out = new PLYDecoded();
    out.indices = new Int32Array(buf.indices.length);
    for (let i = 0; i < buf.indices.length; i++) out.indices[i] = buf.indices[i];
    out.counts[0] = buf.vertices.length;
    out.counts[1] = buf.normals.length;
    out.counts[2] = buf.uvs.length;
    out.counts[3] = buf.colors.length;
    out.counts[4] = buf.faceVertexUvs.length;
    out.counts[5] = buf.faceVertexColors.length;
    let total = buf.vertices.length + buf.normals.length + buf.uvs.length + buf.colors.length
        + buf.faceVertexUvs.length + buf.faceVertexColors.length;
    out.customNames = customNames;
    out.customItemSizes = customPropCounts;
    out.customCounts = new Int32Array(customNames.length);
    for (let i = 0; i < customNames.length; i++) {
        const arr = buf.custom.get(customNames[i]);
        out.customCounts[i] = arr.length;
        total += arr.length;
    }
    if (total > 0) {
        const packed = new Float32Array(total);
        let at = 0;
        at = copyFloats(packed, at, buf.vertices);
        at = copyFloats(packed, at, buf.normals);
        at = copyFloats(packed, at, buf.uvs);
        at = copyFloats(packed, at, buf.colors);
        at = copyFloats(packed, at, buf.faceVertexUvs);
        at = copyFloats(packed, at, buf.faceVertexColors);
        for (let i = 0; i < customNames.length; i++) {
            at = copyFloats(packed, at, buf.custom.get(customNames[i]));
        }
        out.blob = Blob.fromArray(packed);
    }
    return out;
}

export function buildPLYFromDecoded(decoded: PLYDecoded): BufferGeometry {
    let geometry = new BufferGeometry();
    const blob = decoded.blob;
    const hasBlob = blob != null && blob.id != 0;
    if (decoded.indices.length > 0) {
        const idx = new Array<i32>(decoded.indices.length);
        for (let i = 0; i < decoded.indices.length; i++) idx[i] = decoded.indices[i];
        geometry.setIndex(idx);
    }
    const vLen = decoded.counts[0];
    const nLen = decoded.counts[1];
    const uvLen = decoded.counts[2];
    const cLen = decoded.counts[3];
    const fuvLen = decoded.counts[4];
    const fcLen = decoded.counts[5];
    const willDeindex = fuvLen > 0 || fcLen > 0;
    let byteOff: u32 = 0;

    const verts = new Float32Array(vLen);
    if (hasBlob && vLen > 0) blob!.readInto(byteOff, verts);
    const posAttr = new BufferAttribute(verts, 3);
    if (hasBlob && vLen > 0 && !willDeindex) posAttr.setBlob(blob!, byteOff, <u32>(vLen * 4));
    geometry.setAttribute("position", posAttr);
    byteOff += <u32>(vLen * 4);

    if (nLen > 0) {
        const nrms = new Float32Array(nLen);
        if (hasBlob) blob!.readInto(byteOff, nrms);
        geometry.setAttribute("normal", new BufferAttribute(nrms, 3));
        byteOff += <u32>(nLen * 4);
    }
    if (uvLen > 0) {
        const uvs = new Float32Array(uvLen);
        if (hasBlob) blob!.readInto(byteOff, uvs);
        const uvAttr = new BufferAttribute(uvs, 2);
        if (hasBlob && !willDeindex) uvAttr.setBlob(blob!, byteOff, <u32>(uvLen * 4));
        geometry.setAttribute("uv", uvAttr);
        byteOff += <u32>(uvLen * 4);
    }
    if (cLen > 0) {
        const cols = new Float32Array(cLen);
        if (hasBlob) blob!.readInto(byteOff, cols);
        geometry.setAttribute("color", new BufferAttribute(cols, 3));
        byteOff += <u32>(cLen * 4);
    }
    if (willDeindex) {
        geometry = geometry.toNonIndexed();
        if (fuvLen > 0) {
            const fuv = new Float32Array(fuvLen);
            if (hasBlob) blob!.readInto(byteOff, fuv);
            const fuvAttr = new BufferAttribute(fuv, 2);
            if (hasBlob) fuvAttr.setBlob(blob!, byteOff, <u32>(fuvLen * 4));
            geometry.setAttribute("uv", fuvAttr);
            byteOff += <u32>(fuvLen * 4);
        }
        if (fcLen > 0) {
            const fc = new Float32Array(fcLen);
            if (hasBlob) blob!.readInto(byteOff, fc);
            geometry.setAttribute("color", new BufferAttribute(fc, 3));
            byteOff += <u32>(fcLen * 4);
        }
    }
    for (let i = 0; i < decoded.customNames.length; i++) {
        const cnt = decoded.customCounts[i];
        if (cnt > 0) {
            const arr = new Float32Array(cnt);
            if (hasBlob) blob!.readInto(byteOff, arr);
            geometry.setAttribute(decoded.customNames[i], new BufferAttribute(arr, decoded.customItemSizes[i]));
            byteOff += <u32>(cnt * 4);
        }
    }
    geometry.computeBoundingSphere();
    return geometry;
}

export class PLYLoader extends Loader {
    propertyNameMapping: Map<string, string> = new Map<string, string>();
    customPropertyMapping: Map<string, Array<string>> = new Map<string, Array<string>>();

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    setPropertyNameMapping(mapping: Map<string, string>): void { this.propertyNameMapping = mapping; }
    setCustomPropertyNameMapping(mapping: Map<string, Array<string>>): void { this.customPropertyMapping = mapping; }

    load(name: string): BufferGeometry? {
        const context = this.context;
        const bytesAsset = context != null ? context.blob(this.path + name) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            if (context != null) context.log("three: PLYLoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        return this.parse(bytes!);
    }

    /// An https: url or a blob asset name, decoded in a Rive job.
    loadAsync(url: string): Promise<BufferGeometry> {
        return loadPLY(this, url);
    }

    /// As `parse`, decoding in a Rive job off the main lane.
    parseAsync(data: ArrayBuffer): Promise<BufferGeometry> {
        return parsePLYAsync(this, data);
    }

    parse(data: ArrayBuffer): BufferGeometry {
        const buf = parsePLYBuffer(data, this.propertyNameMapping, this.customPropertyMapping);
        return postProcessPLY(buf, this.customPropertyMapping);
    }

    /// The header lines up to end_header, and where the body starts.
    parseHeader(bytes: Uint8Array): PLYHeader {
        return parsePLYHeader(bytes, this.propertyNameMapping);
    }
}

async function loadPLY(loader: PLYLoader, url: string): Promise<BufferGeometry> {
    const bytes = await fetchBytes(loader, url);
    return await parsePLYAsync(loader, bytes);
}

async function parsePLYAsync(loader: PLYLoader, data: ArrayBuffer): Promise<BufferGeometry> {
    const propKeys = loader.propertyNameMapping.keys();
    const propVals: Array<string> = [];
    for (let i = 0; i < propKeys.length; i++) propVals.push(loader.propertyNameMapping.get(propKeys[i]));
    const customNames = loader.customPropertyMapping.keys();
    const customCounts = new Int32Array(customNames.length);
    const customProps: Array<string> = [];
    for (let i = 0; i < customNames.length; i++) {
        const ps = loader.customPropertyMapping.get(customNames[i]);
        customCounts[i] = ps.length;
        for (let j = 0; j < ps.length; j++) customProps.push(ps[j]);
    }
    const job = Jobs.run(decodePLY, data, propKeys, propVals, customNames, customCounts, customProps);
    const settled = await job.promise().settled();
    job.release();
    if (!settled.ok) return await Promise.reject<BufferGeometry>(settled.error);
    return buildPLYFromDecoded(settled.value);
}

function copyFloats(dst: Float32Array, at: i32, src: Array<f64>): i32 {
    for (let i = 0; i < src.length; i++) dst[at + i] = <f32>src[i];
    return at + src.length;
}

function parsePLYBuffer(
    data: ArrayBuffer,
    propertyNameMapping: Map<string, string>,
    customPropertyMapping: Map<string, Array<string>>,
): PLYBuffer {
    const bytes = Uint8Array.wrap(data);
    const header = parsePLYHeader(bytes, propertyNameMapping);
    if (header.format == "ascii") return parsePLYASCII(String.UTF8.decode(data), header, customPropertyMapping);
    return parsePLYBinary(bytes, header, customPropertyMapping);
}

function parsePLYHeader(bytes: Uint8Array, propertyNameMapping: Map<string, string>): PLYHeader {
    const header = new PLYHeader();
    let i = 0;
    let line = "";
    const lines: Array<string> = [];
    let done = false;
    const crnl = bytes.length > 4 && bytes[3] == 13 && bytes[4] == 10;
    while (!done && i < bytes.length) {
        const c = bytes[i++];
        if (c != 10 && c != 13) line += String.fromCharCode(c);
        else {
            if (line == "end_header") done = true;
            if (line.length > 0) {
                lines.push(line);
                line = "";
            }
        }
    }
    if (crnl) i++;
    header.headerLength = i;
    let current: PLYElementDesc? = null;
    for (let l = 0; l < lines.length; l++) {
        const values = splitSpaces(lines[l].trim());
        if (values.length == 0) continue;
        const type = values.shift();
        const rest = values.join(" ");
        if (type == "format") {
            header.format = values.length > 0 ? values[0] : "";
            header.version = values.length > 1 ? values[1] : "";
        } else if (type == "comment") {
            header.comments.push(rest);
        } else if (type == "element") {
            if (current != null) header.elements.push(current!);
            const e = new PLYElementDesc();
            e.name = values.length > 0 ? values[0] : "";
            e.count = values.length > 1 ? <i32>parseInt(values[1]) : 0;
            current = e;
        } else if (type == "property") {
            if (current == null) continue;
            const p = new PLYProperty();
            p.type = values.length > 0 ? values[0] : "";
            if (p.type == "list") {
                p.countType = values.length > 1 ? values[1] : "";
                p.itemType = values.length > 2 ? values[2] : "";
                p.name = values.length > 3 ? values[3] : "";
            } else {
                p.name = values.length > 1 ? values[1] : "";
            }
            if (propertyNameMapping.has(p.name)) p.name = propertyNameMapping.get(p.name);
            current!.properties.push(p);
        } else if (type == "obj_info") {
            header.objInfo = rest;
        }
    }
    if (current != null) header.elements.push(current!);
    return header;
}

function createPLYBuffer(customPropertyMapping: Map<string, Array<string>>): PLYBuffer {
    const b = new PLYBuffer();
    const keys = customPropertyMapping.keys();
    for (let i = 0; i < keys.length; i++) b.custom.set(keys[i], []);
    return b;
}

function parsePLYASCII(text: string, header: PLYHeader, customPropertyMapping: Map<string, Array<string>>): PLYBuffer {
    const buffer = createPLYBuffer(customPropertyMapping);
    const color = new Color();
    const at = text.indexOf("end_header");
    const body = at >= 0 ? splitSpaces(text.substring(at + 10).trim()) : [];
    let k = 0;
    let ok = true;
    for (let i = 0; i < header.elements.length && ok; i++) {
        const desc = header.elements[i];
        const map = mapElementAttributes(desc.properties);
        for (let j = 0; j < desc.count; j++) {
            const element = new PLYElement();
            for (let p = 0; p < desc.properties.length; p++) {
                const prop = desc.properties[p];
                if (k >= body.length) { ok = false; break; }
                if (prop.type == "list") {
                    const n = <i32>parseFloat(body[k++]);
                    const list: Array<f64> = [];
                    for (let m = 0; m < n; m++) {
                        if (k >= body.length) { ok = false; break; }
                        list.push(parseFloat(body[k++]));
                    }
                    element.lists.set(prop.name, list);
                } else {
                    element.values.set(prop.name, parseFloat(body[k++]));
                }
            }
            if (!ok) break;
            handlePLYElement(buffer, desc.name, element, map, customPropertyMapping, color);
        }
    }
    return buffer;
}

function parsePLYBinary(bytes: Uint8Array, header: PLYHeader, customPropertyMapping: Map<string, Array<string>>): PLYBuffer {
    const buffer = createPLYBuffer(customPropertyMapping);
    const color = new Color();
    const little = header.format == "binary_little_endian";
    const bodyOff = bytes.byteOffset + header.headerLength;
    const bodyLen = max<i32>(0, bytes.byteLength - header.headerLength);
    if (little) {
        const reader = new BinaryReader(bytes.buffer, bodyOff, bodyLen);
        for (let e = 0; e < header.elements.length && !reader.didOverflow; e++) {
            const desc = header.elements[e];
            const map = mapElementAttributes(desc.properties);
            for (let c = 0; c < desc.count && !reader.didOverflow; c++) {
                const element = new PLYElement();
                for (let p = 0; p < desc.properties.length; p++) {
                    const prop = desc.properties[p];
                    if (prop.type == "list") {
                        const n = <i32>readBinaryLE(reader, prop.countType);
                        const list: Array<f64> = [];
                        for (let m = 0; m < n && !reader.didOverflow; m++) {
                            list.push(readBinaryLE(reader, prop.itemType));
                        }
                        element.lists.set(prop.name, list);
                    } else {
                        element.values.set(prop.name, readBinaryLE(reader, prop.type));
                    }
                }
                handlePLYElement(buffer, desc.name, element, map, customPropertyMapping, color);
            }
        }
        return buffer;
    }
    const view = new DataView(bytes.buffer, bodyOff, bodyLen);
    let loc = 0;
    for (let e = 0; e < header.elements.length; e++) {
        const desc = header.elements[e];
        const map = mapElementAttributes(desc.properties);
        for (let c = 0; c < desc.count; c++) {
            const element = new PLYElement();
            for (let p = 0; p < desc.properties.length; p++) {
                const prop = desc.properties[p];
                if (prop.type == "list") {
                    const n = <i32>readBinary(view, loc, prop.countType, false);
                    loc += typeSize(prop.countType);
                    const list: Array<f64> = [];
                    for (let m = 0; m < n; m++) {
                        list.push(readBinary(view, loc, prop.itemType, false));
                        loc += typeSize(prop.itemType);
                    }
                    element.lists.set(prop.name, list);
                } else {
                    element.values.set(prop.name, readBinary(view, loc, prop.type, false));
                    loc += typeSize(prop.type);
                }
            }
            handlePLYElement(buffer, desc.name, element, map, customPropertyMapping, color);
        }
    }
    return buffer;
}

function handlePLYElement(
    buffer: PLYBuffer,
    name: string,
    element: PLYElement,
    map: AttributeMap,
    customPropertyMapping: Map<string, Array<string>>,
    color: Color,
): void {
    if (name == "vertex") {
        buffer.vertices.push(element.get(map.x));
        buffer.vertices.push(element.get(map.y));
        buffer.vertices.push(element.get(map.z));
        if (map.nx != null && map.ny != null && map.nz != null) {
            buffer.normals.push(element.get(map.nx!));
            buffer.normals.push(element.get(map.ny!));
            buffer.normals.push(element.get(map.nz!));
        }
        if (map.s != null && map.t != null) {
            buffer.uvs.push(element.get(map.s!));
            buffer.uvs.push(element.get(map.t!));
        }
        if (map.r != null && map.g != null && map.b != null) {
            color.setRGB(element.get(map.r!) / 255.0, element.get(map.g!) / 255.0, element.get(map.b!) / 255.0,
                SRGBColorSpace);
            buffer.colors.push(color.r); buffer.colors.push(color.g); buffer.colors.push(color.b);
        }
        const keys = customPropertyMapping.keys();
        for (let i = 0; i < keys.length; i++) {
            const props = customPropertyMapping.get(keys[i]);
            const out = buffer.custom.get(keys[i]);
            for (let p = 0; p < props.length; p++) out.push(element.get(props[p]));
        }
    } else if (name == "face") {
        const vi = element.lists.has("vertex_indices") ? element.lists.get("vertex_indices")
            : element.lists.has("vertex_index") ? element.lists.get("vertex_index") : [];
        const texcoord: Array<f64> = element.lists.has("texcoord") ? element.lists.get("texcoord") : [];
        if (vi.length == 3) {
            buffer.indices.push(<i32>vi[0]); buffer.indices.push(<i32>vi[1]); buffer.indices.push(<i32>vi[2]);
            if (texcoord.length == 6) for (let i = 0; i < 6; i++) buffer.faceVertexUvs.push(texcoord[i]);
        } else if (vi.length == 4) {
            buffer.indices.push(<i32>vi[0]); buffer.indices.push(<i32>vi[1]); buffer.indices.push(<i32>vi[3]);
            buffer.indices.push(<i32>vi[1]); buffer.indices.push(<i32>vi[2]); buffer.indices.push(<i32>vi[3]);
        }
        if (map.r != null && map.g != null && map.b != null) {
            color.setRGB(element.get(map.r!) / 255.0, element.get(map.g!) / 255.0, element.get(map.b!) / 255.0,
                SRGBColorSpace);
            for (let k = 0; k < 3; k++) {
                buffer.faceVertexColors.push(color.r);
                buffer.faceVertexColors.push(color.g);
                buffer.faceVertexColors.push(color.b);
            }
        }
    }
}

function postProcessPLY(buffer: PLYBuffer, customPropertyMapping: Map<string, Array<string>>): BufferGeometry {
    let geometry = new BufferGeometry();
    if (buffer.indices.length > 0) geometry.setIndex(buffer.indices);
    geometry.setAttribute("position", new Float32BufferAttribute(buffer.vertices, 3));
    if (buffer.normals.length > 0) geometry.setAttribute("normal", new Float32BufferAttribute(buffer.normals, 3));
    if (buffer.uvs.length > 0) geometry.setAttribute("uv", new Float32BufferAttribute(buffer.uvs, 2));
    if (buffer.colors.length > 0) geometry.setAttribute("color", new Float32BufferAttribute(buffer.colors, 3));
    if (buffer.faceVertexUvs.length > 0 || buffer.faceVertexColors.length > 0) {
        geometry = geometry.toNonIndexed();
        if (buffer.faceVertexUvs.length > 0) geometry.setAttribute("uv", new Float32BufferAttribute(buffer.faceVertexUvs, 2));
        if (buffer.faceVertexColors.length > 0) geometry.setAttribute("color", new Float32BufferAttribute(buffer.faceVertexColors, 3));
    }
    const keys = customPropertyMapping.keys();
    for (let i = 0; i < keys.length; i++) {
        const values = buffer.custom.get(keys[i]);
        if (values.length > 0) {
            geometry.setAttribute(keys[i], new Float32BufferAttribute(values, customPropertyMapping.get(keys[i]).length));
        }
    }
    geometry.computeBoundingSphere();
    return geometry;
}

function readBinaryLE(reader: BinaryReader, type: string): f64 {
    if (type == "int8" || type == "char") return <f64>reader.read<i8>();
    if (type == "uint8" || type == "uchar") return <f64>reader.readByte();
    if (type == "int16" || type == "short") return <f64>reader.read<i16>();
    if (type == "uint16" || type == "ushort") return <f64>reader.readUint16();
    if (type == "int32" || type == "int") return <f64>reader.read<i32>();
    if (type == "uint32" || type == "uint") return <f64>reader.readUint32();
    if (type == "float32" || type == "float") return <f64>reader.readFloat32();
    if (type == "float64" || type == "double") return reader.readFloat64();
    return 0;
}

function splitSpaces(text: string): Array<string> {
    const out: Array<string> = [];
    let start = -1;
    for (let i = 0; i <= text.length; i++) {
        const c = i < text.length ? text.charCodeAt(i) : 32;
        const space = c == 32 || c == 9 || c == 10 || c == 13;
        if (space) {
            if (start >= 0) { out.push(text.substring(start, i)); start = -1; }
        } else if (start < 0) start = i;
    }
    return out;
}

function findAttrName(names: StaticArray<string>, props: Array<PLYProperty>): string? {
    for (let i = 0; i < names.length; i++) {
        for (let p = 0; p < props.length; p++) if (props[p].name == names[i]) return names[i];
    }
    return null;
}

function mapElementAttributes(props: Array<PLYProperty>): AttributeMap {
    const m = new AttributeMap();
    const x = findAttrName(["x", "px", "posx"], props); if (x != null) m.x = x!;
    const y = findAttrName(["y", "py", "posy"], props); if (y != null) m.y = y!;
    const z = findAttrName(["z", "pz", "posz"], props); if (z != null) m.z = z!;
    m.nx = findAttrName(["nx", "normalx"], props);
    m.ny = findAttrName(["ny", "normaly"], props);
    m.nz = findAttrName(["nz", "normalz"], props);
    m.s = findAttrName(["s", "u", "texture_u", "tx"], props);
    m.t = findAttrName(["t", "v", "texture_v", "ty"], props);
    m.r = findAttrName(["red", "diffuse_red", "r", "diffuse_r"], props);
    m.g = findAttrName(["green", "diffuse_green", "g", "diffuse_g"], props);
    m.b = findAttrName(["blue", "diffuse_blue", "b", "diffuse_b"], props);
    return m;
}

function typeSize(type: string): i32 {
    if (type == "int8" || type == "char" || type == "uint8" || type == "uchar") return 1;
    if (type == "int16" || type == "short" || type == "uint16" || type == "ushort") return 2;
    if (type == "float64" || type == "double") return 8;
    return 4;
}

function readBinary(view: DataView, at: i32, type: string, little: bool): f64 {
    if (at + typeSize(type) > view.byteLength) return 0;
    if (type == "int8" || type == "char") return <f64>view.getInt8(at);
    if (type == "uint8" || type == "uchar") return <f64>view.getUint8(at);
    if (type == "int16" || type == "short") return <f64>view.getInt16(at, little);
    if (type == "uint16" || type == "ushort") return <f64>view.getUint16(at, little);
    if (type == "int32" || type == "int") return <f64>view.getInt32(at, little);
    if (type == "uint32" || type == "uint") return <f64>view.getUint32(at, little);
    if (type == "float32" || type == "float") return <f64>view.getFloat32(at, little);
    if (type == "float64" || type == "double") return view.getFloat64(at, little);
    return 0;
}
