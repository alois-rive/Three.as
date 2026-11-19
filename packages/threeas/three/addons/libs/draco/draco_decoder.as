// Google's Draco geometry decoder (https://github.com/google/draco,
// Apache License 2.0), ported to AnimaScript from its C++ sources
// (src/draco/compression/ decode paths), for three.js's DRACOLoader.
//
// What three.js loads as draco_decoder.js / draco_decoder.wasm: the
// decoder's JavaScript API (DecoderModule's Decoder, Mesh, PointCloud,
// PointAttribute, Status), with its method names, over the C++ decoder:
//
//     const decoder = new Decoder();
//     const mesh = new Mesh();
//     const status = decoder.DecodeArrayToMesh(bytes, bytes.length, mesh);
//     if (status.ok()) {
//         const id = decoder.GetAttributeId(mesh, POSITION);
//         const positions = decoder.GetAttributeFloatForAllPoints(mesh, decoder.GetAttribute(mesh, id));
//         const index = decoder.GetTrianglesUInt32Array(mesh);
//     }
//
// Reads bitstreams 1.0 to 2.2 (meshes) and 2.3 (point clouds): header and
// metadata; sequential (compressed and raw indices) and Edgebreaker
// (standard, valence and the deprecated predictive) connectivity with
// attribute seams; the generic, integer, quantization and normal attribute
// decoders; the delta, parallelogram, multi-parallelogram, constrained
// multi-parallelogram, tex-coords (portable and deprecated) and geometric
// normal prediction schemes with the wrap and octahedron transforms; rANS
// symbols and the rANS, direct and folded bit decoders; sequential and
// kd-tree point clouds. Not ported: kd-tree point clouds from bitstreams
// before 2.3, and the transcoder's attribute types (tangents, joints,
// weights as named types: glTF stores them as GENERIC, which decodes).
//
// Every class and function here is pure code, so a Rive job can run it.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION } from "./decoder_buffer";
import { decodeSymbols } from "./ans";
import {
    PointCloud, Mesh, PointAttribute, POINT_CLOUD, TRIANGULAR_MESH, INVALID_GEOMETRY_TYPE, DT_FLOAT32,
    isDataTypeIntegral, dataTypeMax, dataTypeMin,
} from "./point_cloud";
import {
    PointCloudDecoder, MeshDecoder, DracoHeader, decodeHeader, POINT_CLOUD_SEQUENTIAL_ENCODING,
    POINT_CLOUD_KD_TREE_ENCODING, MESH_SEQUENTIAL_ENCODING, MESH_EDGEBREAKER_ENCODING,
} from "./point_cloud_decoder";
import { SequentialAttributeDecodersController, LinearSequencer } from "./attributes_decoder";
import { KdTreeAttributesDecoder } from "./kd_tree_attributes_decoder";
import { MeshEdgebreakerDecoder } from "./mesh_edgebreaker_decoder";

export {
    PointCloud, Mesh, PointAttribute, GeometryMetadata, AttributeMetadata, Metadata,
    INVALID, POSITION, NORMAL, COLOR, TEX_COORD, GENERIC,
    DT_INVALID, DT_INT8, DT_UINT8, DT_INT16, DT_UINT16, DT_INT32, DT_UINT32, DT_INT64, DT_UINT64, DT_FLOAT32,
    DT_FLOAT64, DT_BOOL, POINT_CLOUD, TRIANGULAR_MESH, INVALID_GEOMETRY_TYPE,
} from "./point_cloud";

/// PointCloudSequentialDecoder.
class PointCloudSequentialDecoder extends PointCloudDecoder {
    protected override decodeGeometryData(): bool {
        const n = this.buffer.i32();
        if (this.buffer.failed) return false;
        this.pointCloud.numPoints = n;
        return true;
    }

    override createAttributesDecoder(id: i32): bool {
        return this.setAttributesDecoder(id, new SequentialAttributeDecodersController(new LinearSequencer(this.pointCloud.numPoints)));
    }
}

/// PointCloudKdTreeDecoder.
class PointCloudKdTreeDecoder extends PointCloudDecoder {
    protected override decodeGeometryData(): bool {
        const n = this.buffer.i32();
        if (this.buffer.failed || n < 0) return false;
        this.pointCloud.numPoints = n;
        return true;
    }

    override createAttributesDecoder(id: i32): bool {
        return this.setAttributesDecoder(id, new KdTreeAttributesDecoder());
    }
}

/// MeshSequentialDecoder.
class MeshSequentialDecoder extends MeshDecoder {
    protected override decodeConnectivity(): bool {
        const buffer = this.buffer;
        let numFaces: u32, numPoints: u32;
        if (this.bitstreamVersion() < DRACO_BITSTREAM_VERSION(2, 2)) {
            numFaces = buffer.u32();
            numPoints = buffer.u32();
        } else {
            numFaces = buffer.varintU32();
            numPoints = buffer.varintU32();
        }
        if (buffer.failed) return false;
        if (<u64>numFaces > 0xFFFFFFFF / 3) return false;
        if (<i64>numFaces > <i64>(buffer.remainingSize() / 3)) return false;
        const connectivityMethod = buffer.u8();
        if (buffer.failed) return false;
        const mesh = this.mesh;
        const nf = <i32>numFaces;
        mesh.setNumFaces(nf);
        const faces = mesh.faces;
        if (connectivityMethod == 0) {
            if (!this.decodeAndDecompressIndices(numFaces)) return false;
        } else {
            const count = nf * 3;
            if (numPoints < 256) {
                for (let i = 0; i < count; i++) faces[i] = <i32>buffer.u8();
            } else if (numPoints < (1 << 16)) {
                for (let i = 0; i < count; i++) faces[i] = <i32>buffer.u16();
            } else if (numPoints < (1 << 21) && this.bitstreamVersion() >= DRACO_BITSTREAM_VERSION(2, 2)) {
                for (let i = 0; i < count; i++) faces[i] = <i32>buffer.varintU32();
            } else {
                for (let i = 0; i < count; i++) faces[i] = <i32>buffer.u32();
            }
            if (buffer.failed) return false;
        }
        this.pointCloud.numPoints = <i32>numPoints;
        return true;
    }

    private decodeAndDecompressIndices(numFaces: u32): bool {
        const n = <i32>numFaces * 3;
        const indices = new Int32Array(n);
        if (!decodeSymbols(<u32>n, 1, this.buffer, indices)) return false;
        const faces = this.mesh.faces;
        let last: i32 = 0;
        for (let i = 0; i < n; i++) {
            const encoded = <u32>indices[i];
            let diff = <i32>(encoded >> 1);
            if ((encoded & 1) != 0) {
                if (diff > last) return false;
                diff = -diff;
            } else {
                if (diff > 0x7FFFFFFF - last) return false;
            }
            last = diff + last;
            faces[i] = last;
        }
        return true;
    }

    override createAttributesDecoder(id: i32): bool {
        return this.setAttributesDecoder(id, new SequentialAttributeDecodersController(new LinearSequencer(this.pointCloud.numPoints)));
    }
}

/// Status: ok, or why decoding failed.
export class Status {
    message: string;

    constructor(message: string = "") {
        this.message = message;
    }

    ok(): bool { return this.message.length == 0; }
    error_msg(): string { return this.message; }
}

/// Decoder (decode.cc), with the JavaScript API's methods.
export class Decoder {
    /// GetEncodedGeometryType: TRIANGULAR_MESH, POINT_CLOUD or
    /// INVALID_GEOMETRY_TYPE.
    GetEncodedGeometryType(data: Uint8Array): i32 {
        const buffer = new DecoderBuffer().init(data, 0, data.length, 0);
        const header = new DracoHeader();
        if (decodeHeader(buffer, header).length > 0) return INVALID_GEOMETRY_TYPE;
        if (header.encoderType < 0 || header.encoderType > TRIANGULAR_MESH) return INVALID_GEOMETRY_TYPE;
        return header.encoderType;
    }

    DecodeArrayToMesh(data: Uint8Array, size: i32, out: Mesh): Status {
        return this.decodeBufferToGeometry(new DecoderBuffer().init(data, 0, size, 0), out, TRIANGULAR_MESH);
    }

    DecodeArrayToPointCloud(data: Uint8Array, size: i32, out: PointCloud): Status {
        return this.decodeBufferToGeometry(new DecoderBuffer().init(data, 0, size, 0), out, POINT_CLOUD);
    }

    /// DecodeBufferToGeometry for a point cloud or a mesh.
    private decodeBufferToGeometry(buffer: DecoderBuffer, out: PointCloud, type: i32): Status {
        const header = new DracoHeader();
        const err = decodeHeader(buffer.clone(), header);
        if (err.length > 0) return new Status(err);
        if (header.encoderType != type) {
            return new Status(type == TRIANGULAR_MESH ? "Input is not a mesh." : "Input is not a point cloud.");
        }
        let decoder: PointCloudDecoder? = null;
        if (type == TRIANGULAR_MESH) {
            if (!(out instanceof Mesh)) return new Status("Input is not a mesh.");
            if (header.encoderMethod == MESH_SEQUENTIAL_ENCODING) decoder = new MeshSequentialDecoder();
            else if (header.encoderMethod == MESH_EDGEBREAKER_ENCODING) decoder = new MeshEdgebreakerDecoder();
        } else {
            if (header.encoderMethod == POINT_CLOUD_SEQUENTIAL_ENCODING) decoder = new PointCloudSequentialDecoder();
            else if (header.encoderMethod == POINT_CLOUD_KD_TREE_ENCODING) decoder = new PointCloudKdTreeDecoder();
        }
        if (decoder == null) return new Status("Unsupported encoding method.");
        return new Status(decoder.decode(buffer, out));
    }

    /// GetAttributeId: the first attribute of that type, or -1.
    GetAttributeId(pc: PointCloud, type: i32): i32 { return pc.getNamedAttributeId(type); }

    GetAttribute(pc: PointCloud, id: i32): PointAttribute { return pc.attribute(id); }

    GetAttributeIdByUniqueId(pc: PointCloud, uniqueId: u32): i32 { return pc.getAttributeIdByUniqueId(uniqueId); }

    GetAttributeByUniqueId(pc: PointCloud, uniqueId: u32): PointAttribute? { return pc.getAttributeByUniqueId(uniqueId); }

    /// GetTrianglesUInt32Array: three point ids per face.
    GetTrianglesUInt32Array(mesh: Mesh): Uint32Array {
        const n = mesh.numFaces * 3;
        const out = new Uint32Array(n);
        for (let i = 0; i < n; i++) out[i] = <u32>mesh.faces[i];
        return out;
    }

    /// GetAttributeFloatForAllPoints: every point's value as floats
    /// (ConvertValue<float>: normalized integers scale to [0, 1] or [-1, 1]).
    GetAttributeFloatForAllPoints(pc: PointCloud, att: PointAttribute): Float32Array {
        const n = att.numComponents;
        const numPoints = pc.numPoints;
        const out = new Float32Array(numPoints * n);
        const scale = isDataTypeIntegral(att.dataType) && att.normalized ? 1.0 / dataTypeMax(att.dataType) : 1.0;
        if (att.dataType == DT_FLOAT32 && att.isMappingIdentity() && att.size >= numPoints) {
            for (let i = 0; i < numPoints * n; i++) out[i] = att.floats[i];
            return out;
        }
        let k = 0;
        for (let p = 0; p < numPoints; p++) {
            const v = att.mappedIndex(p);
            for (let c = 0; c < n; c++) out[k++] = <f32>(att.component(v, c) * scale);
        }
        return out;
    }

    /// GetAttributeDataArrayForAllPoints: every point's value converted to
    /// `dataType` (ConvertValue<T>), as numbers; null when a value does not
    /// fit the type.
    GetAttributeDataArrayForAllPoints(pc: PointCloud, att: PointAttribute, dataType: i32): Float64Array? {
        const n = att.numComponents;
        const numPoints = pc.numPoints;
        const out = new Float64Array(numPoints * n);
        const srcIntegral = isDataTypeIntegral(att.dataType);
        const dstIntegral = isDataTypeIntegral(dataType);
        const dstMax = dataTypeMax(dataType), dstMin = dataTypeMin(dataType);
        const srcMax = dataTypeMax(att.dataType);
        let k = 0;
        for (let p = 0; p < numPoints; p++) {
            const v = att.mappedIndex(p);
            for (let c = 0; c < n; c++) {
                let x = att.component(v, c);
                if (dstIntegral) {
                    if (srcIntegral) {
                        if (x < dstMin || x > dstMax) return null;
                    } else {
                        if (isNaN(x) || !isFinite(x) || x < dstMin || x >= dstMax) return null;
                        if (att.normalized) {
                            if (x > 1 || x < 0) return null;
                            x = Math.floor(x * dstMax + 0.5);
                        } else {
                            x = x < 0 ? Math.ceil(x) : Math.floor(x);
                        }
                    }
                } else if (srcIntegral && att.normalized) {
                    x = x / srcMax;
                }
                out[k++] = x;
            }
        }
        return out;
    }
}
