// three.js's PLYLoader addon: ASCII and binary (little and big endian) PLY
// to a BufferGeometry: positions, normals, uvs, vertex colours, faces
// (triangles and quads), per-face uvs and colours, and custom vertex
// properties (setCustomPropertyNameMapping).
//
//     const geometry = new PLYLoader(context).load("bunny");    // a BlobAsset

import { Context } from "rive/host";
import { Promise } from "rive/promise";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { BufferGeometry } from "../../core/BufferGeometry";
import { Float32BufferAttribute } from "../../core/BufferAttribute";
import { Color } from "../../math/Color";
import { SRGBColorSpace } from "../../constants";

const _color = new Color();

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

    loadAsync(url: string): Promise<BufferGeometry> {
        return loadPLY(this, url);
    }

    parse(data: ArrayBuffer): BufferGeometry {
        const bytes = Uint8Array.wrap(data);
        const header = this.parseHeader(bytes);
        if (header.format == "ascii") return this.parseASCII(String.UTF8.decode(data), header);
        return this.parseBinary(bytes, header);
    }

    /// The header lines up to end_header, and where the body starts.
    parseHeader(bytes: Uint8Array): PLYHeader {
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
                if (this.propertyNameMapping.has(p.name)) p.name = this.propertyNameMapping.get(p.name);
                current!.properties.push(p);
            } else if (type == "obj_info") {
                header.objInfo = rest;
            }
        }
        if (current != null) header.elements.push(current!);
        return header;
    }

    private parseASCII(text: string, header: PLYHeader): BufferGeometry {
        const buffer = this.createBuffer();
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
                this.handleElement(buffer, desc.name, element, map);
            }
        }
        return this.postProcess(buffer);
    }

    private parseBinary(bytes: Uint8Array, header: PLYHeader): BufferGeometry {
        const buffer = this.createBuffer();
        const little = header.format == "binary_little_endian";
        const view = new DataView(bytes.buffer, bytes.byteOffset + header.headerLength,
            bytes.byteLength - header.headerLength);
        let loc = 0;
        for (let e = 0; e < header.elements.length; e++) {
            const desc = header.elements[e];
            const map = mapElementAttributes(desc.properties);
            for (let c = 0; c < desc.count; c++) {
                const element = new PLYElement();
                for (let p = 0; p < desc.properties.length; p++) {
                    const prop = desc.properties[p];
                    if (prop.type == "list") {
                        const n = <i32>readBinary(view, loc, prop.countType, little);
                        loc += typeSize(prop.countType);
                        const list: Array<f64> = [];
                        for (let m = 0; m < n; m++) {
                            list.push(readBinary(view, loc, prop.itemType, little));
                            loc += typeSize(prop.itemType);
                        }
                        element.lists.set(prop.name, list);
                    } else {
                        element.values.set(prop.name, readBinary(view, loc, prop.type, little));
                        loc += typeSize(prop.type);
                    }
                }
                this.handleElement(buffer, desc.name, element, map);
            }
        }
        return this.postProcess(buffer);
    }

    private createBuffer(): PLYBuffer {
        const b = new PLYBuffer();
        const keys = this.customPropertyMapping.keys();
        for (let i = 0; i < keys.length; i++) b.custom.set(keys[i], []);
        return b;
    }

    private handleElement(buffer: PLYBuffer, name: string, element: PLYElement, map: AttributeMap): void {
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
                _color.setRGB(element.get(map.r!) / 255.0, element.get(map.g!) / 255.0, element.get(map.b!) / 255.0,
                    SRGBColorSpace);
                buffer.colors.push(_color.r); buffer.colors.push(_color.g); buffer.colors.push(_color.b);
            }
            const keys = this.customPropertyMapping.keys();
            for (let i = 0; i < keys.length; i++) {
                const props = this.customPropertyMapping.get(keys[i]);
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
                _color.setRGB(element.get(map.r!) / 255.0, element.get(map.g!) / 255.0, element.get(map.b!) / 255.0,
                    SRGBColorSpace);
                for (let k = 0; k < 3; k++) {
                    buffer.faceVertexColors.push(_color.r);
                    buffer.faceVertexColors.push(_color.g);
                    buffer.faceVertexColors.push(_color.b);
                }
            }
        }
    }

    private postProcess(buffer: PLYBuffer): BufferGeometry {
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
        const keys = this.customPropertyMapping.keys();
        for (let i = 0; i < keys.length; i++) {
            const values = buffer.custom.get(keys[i]);
            if (values.length > 0) {
                geometry.setAttribute(keys[i], new Float32BufferAttribute(values, this.customPropertyMapping.get(keys[i]).length));
            }
        }
        geometry.computeBoundingSphere();
        return geometry;
    }
}

async function loadPLY(loader: PLYLoader, url: string): Promise<BufferGeometry> {
    const bytes = await fetchBytes(loader, url);
    return loader.parse(bytes);
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
