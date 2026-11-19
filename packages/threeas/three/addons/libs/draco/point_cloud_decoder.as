// Draco's PointCloudDecoder and MeshDecoder (compression/point_cloud/
// point_cloud_decoder.cc, compression/mesh/mesh_decoder.cc), the header and
// the metadata (metadata/metadata_decoder.cc), ported from Google's Draco
// decoder (Apache License 2.0, https://github.com/google/draco) to
// AnimaScript.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION } from "./decoder_buffer";
import {
    PointCloud, Mesh, PointAttribute, Metadata, AttributeMetadata, GeometryMetadata,
    POINT_CLOUD, TRIANGULAR_MESH,
} from "./point_cloud";
import { CornerTable, MeshAttributeCornerTable, MeshAttributeIndicesEncodingData } from "./corner_table";

// Latest bitstream versions (compression/config/compression_shared.h).
export const kDracoPointCloudBitstreamVersionMajor: i32 = 2;
export const kDracoPointCloudBitstreamVersionMinor: i32 = 3;
export const kDracoMeshBitstreamVersionMajor: i32 = 2;
export const kDracoMeshBitstreamVersionMinor: i32 = 2;

// Encoding methods.
export const POINT_CLOUD_SEQUENTIAL_ENCODING: i32 = 0;
export const POINT_CLOUD_KD_TREE_ENCODING: i32 = 1;
export const MESH_SEQUENTIAL_ENCODING: i32 = 0;
export const MESH_EDGEBREAKER_ENCODING: i32 = 1;

const METADATA_FLAG_MASK: u32 = 0x8000;

/// DracoHeader.
export class DracoHeader {
    versionMajor: i32 = 0;
    versionMinor: i32 = 0;
    encoderType: i32 = -1;
    encoderMethod: i32 = -1;
    flags: u32 = 0;
}

/// PointCloudDecoder::DecodeHeader: "" on success, else the error.
export function decodeHeader(buffer: DecoderBuffer, out: DracoHeader): string {
    const d = buffer.data;
    const at = buffer.head;
    if (buffer.remainingSize() < 5) return "Failed to parse Draco header.";
    if (d[at] != 68 || d[at + 1] != 82 || d[at + 2] != 65 || d[at + 3] != 67 || d[at + 4] != 79) {
        return "Not a Draco file.";
    }
    buffer.advance(5);
    out.versionMajor = <i32>buffer.u8();
    out.versionMinor = <i32>buffer.u8();
    out.encoderType = <i32>buffer.u8();
    out.encoderMethod = <i32>buffer.u8();
    out.flags = buffer.u16();
    if (buffer.failed) return "Failed to parse Draco header.";
    return "";
}

/// AttributesDecoderInterface.
export abstract class AttributesDecoderInterface {
    abstract init(decoder: PointCloudDecoder, pc: PointCloud): bool;
    abstract decodeAttributesDecoderData(buffer: DecoderBuffer): bool;
    abstract getAttributeId(i: i32): i32;
    abstract getNumAttributes(): i32;
    abstract decodeAttributes(buffer: DecoderBuffer): bool;
    getPortableAttribute(pointAttributeId: i32): PointAttribute? { return null; }
}

/// PointCloudDecoder: the header, metadata, geometry data and attributes.
export class PointCloudDecoder {
    pointCloud: PointCloud = new PointCloud();
    buffer: DecoderBuffer = new DecoderBuffer();
    versionMajor: i32 = 0;
    versionMinor: i32 = 0;
    attributesDecoders: Array<AttributesDecoderInterface?> = [];
    attributeToDecoderMap: Array<i32> = [];
    error: string = "";

    getGeometryType(): i32 { return POINT_CLOUD; }

    bitstreamVersion(): i32 { return DRACO_BITSTREAM_VERSION(this.versionMajor, this.versionMinor); }

    /// Decode: "" on success, else the error (Draco's Status).
    decode(buffer: DecoderBuffer, out: PointCloud): string {
        this.buffer = buffer;
        this.pointCloud = out;
        this.setOutput(out);
        const header = new DracoHeader();
        const err = decodeHeader(buffer, header);
        if (err.length > 0) return err;
        if (header.encoderType != this.getGeometryType()) return "Using incompatible decoder for the input geometry.";
        this.versionMajor = header.versionMajor;
        this.versionMinor = header.versionMinor;
        const maxMajor = header.encoderType == POINT_CLOUD ? kDracoPointCloudBitstreamVersionMajor : kDracoMeshBitstreamVersionMajor;
        const maxMinor = header.encoderType == POINT_CLOUD ? kDracoPointCloudBitstreamVersionMinor : kDracoMeshBitstreamVersionMinor;
        if (this.versionMajor < 1 || this.versionMajor > maxMajor) return "Unknown major version.";
        if (this.versionMajor == maxMajor && this.versionMinor > maxMinor) return "Unknown minor version.";
        buffer.bitstreamVersion = this.bitstreamVersion();
        if (this.bitstreamVersion() >= DRACO_BITSTREAM_VERSION(1, 3) && (header.flags & METADATA_FLAG_MASK) != 0) {
            if (!this.decodeMetadata()) return "Failed to decode metadata.";
        }
        if (!this.initializeDecoder()) return "Failed to initialize the decoder.";
        if (!this.decodeGeometryData()) return "Failed to decode geometry data.";
        if (!this.decodePointAttributes()) return "Failed to decode point attributes.";
        return "";
    }

    protected setOutput(out: PointCloud): void {}

    setAttributesDecoder(id: i32, decoder: AttributesDecoderInterface): bool {
        if (id < 0) return false;
        while (this.attributesDecoders.length <= id) this.attributesDecoders.push(null);
        this.attributesDecoders[id] = decoder;
        return true;
    }

    numAttributesDecoders(): i32 { return this.attributesDecoders.length; }

    attributesDecoder(id: i32): AttributesDecoderInterface? { return this.attributesDecoders[id]; }

    getPortableAttribute(parentAttId: i32): PointAttribute? {
        if (parentAttId < 0 || parentAttId >= this.pointCloud.numAttributes()) return null;
        if (parentAttId >= this.attributeToDecoderMap.length) return null;
        const dec = this.attributesDecoders[this.attributeToDecoderMap[parentAttId]];
        return dec != null ? dec.getPortableAttribute(parentAttId) : null;
    }

    protected initializeDecoder(): bool { return true; }

    createAttributesDecoder(id: i32): bool { return false; }

    protected decodeGeometryData(): bool { return true; }

    protected decodeMetadata(): bool {
        const metadata = new GeometryMetadata();
        if (!decodeGeometryMetadata(this.buffer, metadata)) return false;
        this.pointCloud.metadata = metadata;
        return true;
    }

    protected decodePointAttributes(): bool {
        const buffer = this.buffer;
        const n = <i32>buffer.u8();
        if (buffer.failed) return false;
        for (let i = 0; i < n; ++i) {
            if (!this.createAttributesDecoder(i)) return false;
        }
        for (let i = 0; i < this.attributesDecoders.length; i++) {
            const d = this.attributesDecoders[i];
            if (d == null || !d.init(this, this.pointCloud)) return false;
        }
        for (let i = 0; i < n; ++i) {
            if (!this.attributesDecoders[i]!.decodeAttributesDecoderData(buffer)) return false;
        }
        for (let i = 0; i < n; ++i) {
            const d = this.attributesDecoders[i]!;
            const na = d.getNumAttributes();
            for (let j = 0; j < na; ++j) {
                const attId = d.getAttributeId(j);
                while (this.attributeToDecoderMap.length <= attId) this.attributeToDecoderMap.push(0);
                this.attributeToDecoderMap[attId] = i;
            }
        }
        if (!this.decodeAllAttributes()) return false;
        return this.onAttributesDecoded();
    }

    protected decodeAllAttributes(): bool {
        for (let i = 0; i < this.attributesDecoders.length; i++) {
            if (!this.attributesDecoders[i]!.decodeAttributes(this.buffer)) return false;
        }
        return true;
    }

    protected onAttributesDecoded(): bool { return true; }
}

/// MeshDecoder: connectivity first, then the point cloud's data.
export class MeshDecoder extends PointCloudDecoder {
    mesh: Mesh = new Mesh();

    override getGeometryType(): i32 { return TRIANGULAR_MESH; }

    protected override setOutput(out: PointCloud): void {
        if (out instanceof Mesh) this.mesh = out as Mesh;
    }

    getCornerTable(): CornerTable? { return null; }

    getAttributeCornerTable(attId: i32): MeshAttributeCornerTable? { return null; }

    getAttributeEncodingData(attId: i32): MeshAttributeIndicesEncodingData? { return null; }

    protected override decodeGeometryData(): bool {
        if (!this.decodeConnectivity()) return false;
        return true;
    }

    protected decodeConnectivity(): bool { return false; }
}

// ------------------------------------------------------------- metadata

function decodeName(buffer: DecoderBuffer): string? {
    const len = <i32>buffer.u8();
    if (buffer.failed) return null;
    if (len == 0) return "";
    if (len > buffer.remainingSize()) return null;
    const bytes = new Uint8Array(len);
    buffer.bytes(bytes, 0, len);
    return String.UTF8.decode(bytes.buffer);
}

function decodeEntry(buffer: DecoderBuffer, metadata: Metadata): bool {
    const name = decodeName(buffer);
    if (name == null) return false;
    const dataSize = buffer.varintU32();
    if (buffer.failed || dataSize == 0) return false;
    if (<i64>dataSize > <i64>buffer.remainingSize()) return false;
    const value = new Uint8Array(<i32>dataSize);
    if (!buffer.bytes(value, 0, <i32>dataSize)) return false;
    metadata.addEntryBinary(name!, value);
    return true;
}

class MetadataTuple {
    parent: Metadata?;
    decoded: Metadata?;
    level: i32;

    constructor(parent: Metadata?, decoded: Metadata?, level: i32) {
        this.parent = parent;
        this.decoded = decoded;
        this.level = level;
    }
}

/// MetadataDecoder::DecodeMetadata.
export function decodeMetadata(buffer: DecoderBuffer, root: Metadata): bool {
    const stack: Array<MetadataTuple> = [new MetadataTuple(null, root, 0)];
    while (stack.length > 0) {
        const mp = stack.pop();
        let metadata = mp.decoded;
        const parent = mp.parent;
        if (parent != null) {
            if (mp.level > 1000) return false;
            const name = decodeName(buffer);
            if (name == null) return false;
            const sub = new Metadata();
            metadata = sub;
            if (!parent.addSubMetadata(name!, sub)) return false;
        }
        if (metadata == null) return false;
        const numEntries = buffer.varintU32();
        if (buffer.failed) return false;
        for (let i: u32 = 0; i < numEntries; ++i) {
            if (!decodeEntry(buffer, metadata)) return false;
        }
        const numSub = buffer.varintU32();
        if (buffer.failed) return false;
        if (<i64>numSub > <i64>buffer.remainingSize()) return false;
        for (let i: u32 = 0; i < numSub; ++i) {
            stack.push(new MetadataTuple(metadata, null, parent != null ? mp.level + 1 : mp.level));
        }
    }
    return true;
}

/// MetadataDecoder::DecodeGeometryMetadata.
export function decodeGeometryMetadata(buffer: DecoderBuffer, metadata: GeometryMetadata): bool {
    const numAttMetadata = buffer.varintU32();
    if (buffer.failed) return false;
    for (let i: u32 = 0; i < numAttMetadata; ++i) {
        const uniqueId = buffer.varintU32();
        if (buffer.failed) return false;
        const att = new AttributeMetadata();
        att.attUniqueId = uniqueId;
        if (!decodeMetadata(buffer, att)) return false;
        metadata.attributeMetadatas.push(att);
    }
    return decodeMetadata(buffer, metadata);
}
