// three.js examples/jsm/utils/BufferGeometryUtils.js: merging geometries
// and attributes, welding vertices, interleaving. Functions, as three.js
// (import them by path).

import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute } from "../../core/BufferAttribute";
import { InterleavedBuffer, InterleavedBufferAttribute } from "../../core/InterleavedBuffer";

/// One geometry from many with the same attributes (all indexed or none);
/// `useGroups` adds a group per input (for a material array). Null when
/// they do not match.
export function mergeGeometries(geometries: Array<BufferGeometry>, useGroups: bool = false): BufferGeometry? {
    if (geometries.length == 0) return null;
    const first = geometries[0];
    const indexed = first.index != null;
    const names = first.attributes.keys();
    const merged = new BufferGeometry();
    let offset = 0;
    let vertexOffset = 0;
    const indices: Array<i32> = [];
    for (let i = 0; i < geometries.length; i++) {
        const g = geometries[i];
        if ((g.index != null) != indexed) return null;
        if (g.attributes.size != names.length) return null;
        for (let n = 0; n < names.length; n++) if (!g.attributes.has(names[n])) return null;
        const position = g.getAttribute("position");
        const vertexCount = position != null ? position.count : 0;
        if (useGroups) {
            const count = indexed ? g.index!.count : vertexCount;
            merged.addGroup(offset, count, i);
            offset += count;
        }
        if (indexed) {
            const idx = g.index!.array;
            for (let k = 0; k < idx.length; k++) indices.push(<i32>idx[k] + vertexOffset);
        }
        vertexOffset += vertexCount;
    }
    for (let n = 0; n < names.length; n++) {
        const list: Array<BufferAttribute> = [];
        for (let i = 0; i < geometries.length; i++) list.push(geometries[i].attributes.get(names[n]));
        const m = mergeAttributes(list);
        if (m == null) return null;
        merged.setAttribute(names[n], m);
    }
    if (indexed) merged.setIndex(indices);
    return merged;
}

/// The attributes one after the other (same itemSize and normalized).
export function mergeAttributes(attributes: Array<BufferAttribute>): BufferAttribute? {
    if (attributes.length == 0) return null;
    const itemSize = attributes[0].itemSize, normalized = attributes[0].normalized;
    let length = 0;
    for (let i = 0; i < attributes.length; i++) {
        if (attributes[i].itemSize != itemSize || attributes[i].normalized != normalized) return null;
        length += attributes[i].array.length;
    }
    const array = new Float32Array(length);
    let o = 0;
    for (let i = 0; i < attributes.length; i++) {
        array.set(attributes[i].array, o);
        o += attributes[i].array.length;
    }
    return new BufferAttribute(array, itemSize, normalized);
}

/// Welds vertices whose every attribute matches within `tolerance` into
/// one, indexing the geometry (three.js's mergeVertices).
export function mergeVertices(geometry: BufferGeometry, tolerance: f64 = 1e-4): BufferGeometry {
    const position = geometry.getAttribute("position");
    const result = new BufferGeometry();
    if (position == null) return result;
    const names = geometry.attributes.keys();
    const precision = Math.log10(1 / tolerance);
    const factor = Math.pow(10, Math.floor(precision));
    const vertexCount = position.count;
    const source = geometry.index;
    const indexCount = source != null ? source.count : vertexCount;
    const map = new Map<string, i32>();
    const newIndices: Array<i32> = [];
    const attrs: Array<BufferAttribute> = [];
    const out: Array<Array<f64>> = [];
    for (let n = 0; n < names.length; n++) {
        attrs.push(geometry.attributes.get(names[n]));
        out.push([]);
    }
    let next = 0;
    for (let i = 0; i < indexCount; i++) {
        const v = source != null ? <i32>source.array[i] : i;
        let hash = "";
        for (let n = 0; n < attrs.length; n++) {
            const a = attrs[n];
            const stride = a.itemSize;
            const arr = a.array;
            const base = v * stride;
            for (let k = 0; k < stride; k++) {
                hash += (Math.round(<f64>arr[base + k] * factor)).toString() + ",";
            }
        }
        if (map.has(hash)) {
            newIndices.push(map.get(hash));
        } else {
            for (let n = 0; n < attrs.length; n++) {
                const a = attrs[n];
                const stride = a.itemSize;
                const arr = a.array;
                const base = v * stride;
                const dst = out[n];
                for (let k = 0; k < stride; k++) dst.push(<f64>arr[base + k]);
            }
            map.set(hash, next);
            newIndices.push(next);
            next++;
        }
    }
    for (let n = 0; n < names.length; n++) {
        const a = attrs[n];
        const data = new Float32Array(out[n].length);
        for (let k = 0; k < data.length; k++) data[k] = <f32>out[n][k];
        result.setAttribute(names[n], new BufferAttribute(data, a.itemSize, a.normalized));
    }
    result.setIndex(newIndices);
    for (let i = 0; i < geometry.groups.length; i++) {
        const g = geometry.groups[i];
        result.addGroup(g.start, g.count, g.materialIndex);
    }
    return result;
}

/// The attributes as one InterleavedBuffer (in order), each replaced by an
/// InterleavedBufferAttribute over it.
export function interleaveAttributes(attributes: Array<BufferAttribute>): Array<InterleavedBufferAttribute> {
    let stride = 0;
    let count = 0;
    for (let i = 0; i < attributes.length; i++) {
        stride += attributes[i].itemSize;
        count = attributes[i].count;
    }
    const buffer = new InterleavedBuffer(new Float32Array(count * stride), stride);
    let offset = 0;
    for (let i = 0; i < attributes.length; i++) {
        const a = attributes[i];
        for (let v = 0; v < count; v++) {
            for (let k = 0; k < a.itemSize; k++) buffer.array[v * stride + offset + k] = a.array[v * a.itemSize + k];
        }
        offset += a.itemSize;
    }
    const out: Array<InterleavedBufferAttribute> = [];
    offset = 0;
    for (let i = 0; i < attributes.length; i++) {
        out.push(new InterleavedBufferAttribute(buffer, attributes[i].itemSize, offset, attributes[i].normalized));
        offset += attributes[i].itemSize;
    }
    return out;
}

/// Replaces interleaved attributes by plain ones.
export function deinterleaveGeometry(geometry: BufferGeometry): void {
    const names = geometry.attributes.keys();
    for (let i = 0; i < names.length; i++) {
        const a = geometry.attributes.get(names[i]);
        if (a instanceof InterleavedBufferAttribute) geometry.setAttribute(names[i], a.clone());
    }
}

/// three.js computes MikkTSpace tangents with a WASM module; here this is
/// BufferGeometry.computeTangents (the same frame for most meshes).
export function computeMikkTSpaceTangents(geometry: BufferGeometry): BufferGeometry {
    geometry.computeTangents();
    return geometry;
}
