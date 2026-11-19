// Draco's geometry (attributes/point_attribute.h, geometry_attribute.h,
// point_cloud/point_cloud.h, mesh/mesh.h, metadata/), ported from Google's
// Draco decoder (Apache License 2.0, https://github.com/google/draco) to
// AnimaScript: what the decoder fills, reduced to what decoding needs.

// GeometryAttribute::Type.
export const INVALID: i32 = -1;
export const POSITION: i32 = 0;
export const NORMAL: i32 = 1;
export const COLOR: i32 = 2;
export const TEX_COORD: i32 = 3;
export const GENERIC: i32 = 4;
export const NAMED_ATTRIBUTES_COUNT: i32 = 5;

// DataType.
export const DT_INVALID: i32 = 0;
export const DT_INT8: i32 = 1;
export const DT_UINT8: i32 = 2;
export const DT_INT16: i32 = 3;
export const DT_UINT16: i32 = 4;
export const DT_INT32: i32 = 5;
export const DT_UINT32: i32 = 6;
export const DT_INT64: i32 = 7;
export const DT_UINT64: i32 = 8;
export const DT_FLOAT32: i32 = 9;
export const DT_FLOAT64: i32 = 10;
export const DT_BOOL: i32 = 11;
export const DT_TYPES_COUNT: i32 = 12;

// EncodedGeometryType.
export const INVALID_GEOMETRY_TYPE: i32 = -1;
export const POINT_CLOUD: i32 = 0;
export const TRIANGULAR_MESH: i32 = 1;

export function dataTypeLength(dt: i32): i32 {
    if (dt == DT_INT8 || dt == DT_UINT8 || dt == DT_BOOL) return 1;
    if (dt == DT_INT16 || dt == DT_UINT16) return 2;
    if (dt == DT_INT32 || dt == DT_UINT32 || dt == DT_FLOAT32) return 4;
    if (dt == DT_INT64 || dt == DT_UINT64 || dt == DT_FLOAT64) return 8;
    return -1;
}

/// The largest value of an integer data type (for normalization).
export function dataTypeMax(dt: i32): f64 {
    if (dt == DT_INT8) return 127;
    if (dt == DT_UINT8 || dt == DT_BOOL) return 255;
    if (dt == DT_INT16) return 32767;
    if (dt == DT_UINT16) return 65535;
    if (dt == DT_INT32) return 2147483647;
    if (dt == DT_UINT32) return 4294967295;
    if (dt == DT_INT64) return 9223372036854775807;
    if (dt == DT_UINT64) return 18446744073709551615;
    return 1;
}

/// The smallest value of an integer data type.
export function dataTypeMin(dt: i32): f64 {
    if (dt == DT_INT8) return -128;
    if (dt == DT_INT16) return -32768;
    if (dt == DT_INT32) return -2147483648;
    if (dt == DT_INT64) return -9223372036854775808;
    return 0;
}

export function isDataTypeIntegral(dt: i32): bool {
    return dt != DT_FLOAT32 && dt != DT_FLOAT64 && dt != DT_INVALID;
}

/// PointAttribute: values (`size` entries of `byteStride` bytes) and the
/// map from points to them (identity, or `indicesMap`).
export class PointAttribute {
    attributeType: i32 = INVALID;
    dataType: i32 = DT_INVALID;
    numComponents: i32 = 0;
    normalized: bool = false;
    byteStride: i32 = 0;
    uniqueId: u32 = 0;
    /// The number of values (num_unique_entries).
    size: i32 = 0;
    buffer: ArrayBuffer = new ArrayBuffer(0);
    bytes: Uint8Array = new Uint8Array(0);
    /// Views over `buffer` (whole 4-byte words).
    ints: Int32Array = new Int32Array(0);
    floats: Float32Array = new Float32Array(0);
    identityMapping: bool = false;
    indicesMap: Int32Array = new Int32Array(0);

    /// GeometryAttribute::Init.
    init(attributeType: i32, numComponents: i32, dataType: i32, normalized: bool): PointAttribute {
        this.attributeType = attributeType;
        this.numComponents = numComponents;
        this.dataType = dataType;
        this.normalized = normalized;
        this.byteStride = dataTypeLength(dataType) * numComponents;
        return this;
    }

    /// Reset(num_attribute_values): room for that many values, zeroed.
    reset(numValues: i32): bool {
        if (numValues < 0 || this.byteStride <= 0) return numValues == 0;
        const bytes = numValues * this.byteStride;
        this.buffer = new ArrayBuffer((bytes + 3) & ~3);
        this.bytes = Uint8Array.wrap(this.buffer);
        this.ints = Int32Array.wrap(this.buffer);
        this.floats = Float32Array.wrap(this.buffer);
        this.size = numValues;
        return true;
    }

    setIdentityMapping(): void {
        this.identityMapping = true;
        this.indicesMap = new Int32Array(0);
    }

    setExplicitMapping(numPoints: i32): void {
        this.identityMapping = false;
        this.indicesMap = new Int32Array(numPoints);
        this.indicesMap.fill(-1);
    }

    setPointMapEntry(point: i32, value: i32): void {
        this.indicesMap[point] = value;
    }

    isMappingIdentity(): bool { return this.identityMapping; }

    indicesMapSize(): i32 { return this.identityMapping ? 0 : this.indicesMap.length; }

    mappedIndex(point: i32): i32 {
        return this.identityMapping ? point : this.indicesMap[point];
    }

    /// Component `c` of value `index` as a double (no normalization).
    component(index: i32, c: i32): f64 {
        const dt = this.dataType;
        const at = index * this.byteStride;
        const b = this.bytes;
        if (dt == DT_FLOAT32) {
            if ((at & 3) == 0) return <f64>this.floats[(at >> 2) + c];
            return <f64>reinterpret<f32>(readU32(b, at + c * 4));
        }
        if (dt == DT_INT32) {
            if ((at & 3) == 0) return <f64>this.ints[(at >> 2) + c];
            return <f64><i32>readU32(b, at + c * 4);
        }
        if (dt == DT_UINT32) return <f64>readU32(b, at + c * 4);
        if (dt == DT_UINT8 || dt == DT_BOOL) return <f64>b[at + c];
        if (dt == DT_INT8) return <f64><i8>b[at + c];
        if (dt == DT_UINT16) return <f64>(<u32>b[at + c * 2] | (<u32>b[at + c * 2 + 1] << 8));
        if (dt == DT_INT16) return <f64><i16>(<u32>b[at + c * 2] | (<u32>b[at + c * 2 + 1] << 8));
        if (dt == DT_FLOAT64) return reinterpret<f64>(<u64>readU32(b, at + c * 8) | (<u64>readU32(b, at + c * 8 + 4) << 32));
        if (dt == DT_INT64 || dt == DT_UINT64) {
            const v = <u64>readU32(b, at + c * 8) | (<u64>readU32(b, at + c * 8 + 4) << 32);
            return dt == DT_INT64 ? <f64><i64>v : <f64>v;
        }
        return 0;
    }

    /// Component `c` of value `index` as an int64 (ConvertValue<int64_t>:
    /// floats truncate).
    componentI64(index: i32, c: i32): i64 {
        const dt = this.dataType;
        if (dt == DT_INT32 && (this.byteStride & 3) == 0) return <i64>this.ints[index * (this.byteStride >> 2) + c];
        if (dt == DT_INT64 || dt == DT_UINT64) {
            const at = index * this.byteStride + c * 8;
            return <i64>(<u64>readU32(this.bytes, at) | (<u64>readU32(this.bytes, at + 4) << 32));
        }
        return <i64>this.component(index, c);
    }

    /// Writes `value` (converted to the data type) as component `c`.
    setComponent(index: i32, c: i32, value: f64): void {
        const dt = this.dataType;
        const at = index * this.byteStride;
        const b = this.bytes;
        if (dt == DT_FLOAT32) writeU32(b, at + c * 4, reinterpret<u32>(<f32>value));
        else if (dt == DT_INT32) writeU32(b, at + c * 4, <u32><i32><i64>value);
        else if (dt == DT_UINT32) writeU32(b, at + c * 4, <u32><i64>value);
        else if (dt == DT_UINT8 || dt == DT_INT8 || dt == DT_BOOL) b[at + c] = <u8><i64>value;
        else if (dt == DT_UINT16 || dt == DT_INT16) {
            const v = <u32><i64>value;
            b[at + c * 2] = <u8>v;
            b[at + c * 2 + 1] = <u8>(v >> 8);
        } else if (dt == DT_FLOAT64) {
            const v = reinterpret<u64>(value);
            writeU32(b, at + c * 8, <u32>v);
            writeU32(b, at + c * 8 + 4, <u32>(v >> 32));
        } else if (dt == DT_INT64 || dt == DT_UINT64) {
            const v = <u64><i64>value;
            writeU32(b, at + c * 8, <u32>v);
            writeU32(b, at + c * 8 + 4, <u32>(v >> 32));
        }
    }
}

export function readU32(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

export function writeU32(b: Uint8Array, at: i32, v: u32): void {
    b[at] = <u8>v;
    b[at + 1] = <u8>(v >> 8);
    b[at + 2] = <u8>(v >> 16);
    b[at + 3] = <u8>(v >> 24);
}

/// Metadata: named binary entries and named sub-metadata.
export class Metadata {
    entryNames: Array<string> = [];
    entryValues: Array<Uint8Array> = [];
    subMetadataNames: Array<string> = [];
    subMetadatas: Array<Metadata> = [];

    addEntryBinary(name: string, value: Uint8Array): void {
        for (let i = 0; i < this.entryNames.length; i++) {
            if (this.entryNames[i] == name) {
                this.entryValues[i] = value;
                return;
            }
        }
        this.entryNames.push(name);
        this.entryValues.push(value);
    }

    addSubMetadata(name: string, metadata: Metadata): bool {
        for (let i = 0; i < this.subMetadataNames.length; i++) if (this.subMetadataNames[i] == name) return false;
        this.subMetadataNames.push(name);
        this.subMetadatas.push(metadata);
        return true;
    }

    getEntry(name: string): Uint8Array? {
        for (let i = 0; i < this.entryNames.length; i++) if (this.entryNames[i] == name) return this.entryValues[i];
        return null;
    }

    getSubMetadata(name: string): Metadata? {
        for (let i = 0; i < this.subMetadataNames.length; i++) if (this.subMetadataNames[i] == name) return this.subMetadatas[i];
        return null;
    }

    /// GetEntryString: the entry's bytes as UTF-8 ("" when missing).
    getEntryString(name: string): string {
        const e = this.getEntry(name);
        if (e == null) return "";
        return String.UTF8.decode(e.slice(0).buffer);
    }

    /// GetEntryInt: a 4-byte entry as int32 (0 when missing).
    getEntryInt(name: string): i32 {
        const e = this.getEntry(name);
        if (e == null || e.length < 4) return 0;
        return <i32>readU32(e, 0);
    }

    /// GetEntryIntArray.
    getEntryIntArray(name: string): Array<i32> {
        const out: Array<i32> = [];
        const e = this.getEntry(name);
        if (e == null) return out;
        for (let i = 0; i + 4 <= e.length; i += 4) out.push(<i32>readU32(e, i));
        return out;
    }

    /// GetEntryDouble: an 8-byte entry as a double (0 when missing).
    getEntryDouble(name: string): f64 {
        const e = this.getEntry(name);
        if (e == null || e.length < 8) return 0;
        return reinterpret<f64>(<u64>readU32(e, 0) | (<u64>readU32(e, 4) << 32));
    }

    /// GetEntryDoubleArray.
    getEntryDoubleArray(name: string): Array<f64> {
        const out: Array<f64> = [];
        const e = this.getEntry(name);
        if (e == null) return out;
        for (let i = 0; i + 8 <= e.length; i += 8) out.push(reinterpret<f64>(<u64>readU32(e, i) | (<u64>readU32(e, i + 4) << 32)));
        return out;
    }
}

export class AttributeMetadata extends Metadata {
    attUniqueId: u32 = 0;
}

export class GeometryMetadata extends Metadata {
    attributeMetadatas: Array<AttributeMetadata> = [];

    getAttributeMetadataByUniqueId(uniqueId: u32): AttributeMetadata? {
        for (let i = 0; i < this.attributeMetadatas.length; i++) {
            if (this.attributeMetadatas[i].attUniqueId == uniqueId) return this.attributeMetadatas[i];
        }
        return null;
    }
}

/// PointCloud: points and their attributes.
export class PointCloud {
    numPoints: i32 = 0;
    attributes: Array<PointAttribute> = [];
    metadata: GeometryMetadata? = null;

    numAttributes(): i32 { return this.attributes.length; }

    attribute(id: i32): PointAttribute { return this.attributes[id]; }

    addAttribute(att: PointAttribute): i32 {
        this.attributes.push(att);
        return this.attributes.length - 1;
    }

    /// GetNamedAttributeId: the first attribute of that type, or -1.
    getNamedAttributeId(type: i32): i32 {
        for (let i = 0; i < this.attributes.length; i++) if (this.attributes[i].attributeType == type) return i;
        return -1;
    }

    getAttributeIdByUniqueId(uniqueId: u32): i32 {
        for (let i = 0; i < this.attributes.length; i++) if (this.attributes[i].uniqueId == uniqueId) return i;
        return -1;
    }

    getAttributeByUniqueId(uniqueId: u32): PointAttribute? {
        const id = this.getAttributeIdByUniqueId(uniqueId);
        return id >= 0 ? this.attributes[id] : null;
    }

    isMesh(): bool { return false; }
}

/// Mesh: a point cloud with triangles (three point ids each).
export class Mesh extends PointCloud {
    faces: Int32Array = new Int32Array(0);
    numFaces: i32 = 0;

    setNumFaces(n: i32): void {
        const f = new Int32Array(n * 3);
        const keep = min<i32>(n, this.numFaces) * 3;
        for (let i = 0; i < keep; i++) f[i] = this.faces[i];
        this.faces = f;
        this.numFaces = n;
    }

    setFace(face: i32, a: i32, b: i32, c: i32): void {
        const o = face * 3;
        this.faces[o] = a;
        this.faces[o + 1] = b;
        this.faces[o + 2] = c;
    }

    /// CornerToPointId.
    cornerToPointId(corner: i32): i32 {
        return this.faces[corner];
    }

    override isMesh(): bool { return true; }
}
