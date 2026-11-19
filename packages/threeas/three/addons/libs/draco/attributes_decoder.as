// Draco's attribute decoders (compression/attributes/attributes_decoder.cc,
// sequential_attribute_decoders_controller.cc, sequential_*_decoder.cc),
// the attribute transforms (attributes/attribute_quantization_transform.cc,
// attribute_octahedron_transform.cc), the points sequencers and the mesh
// traversers (compression/mesh/traverser/), ported from Google's Draco
// decoder (Apache License 2.0, https://github.com/google/draco) to
// AnimaScript.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION, convertSymbolToSignedInt } from "./decoder_buffer";
import { decodeSymbols } from "./ans";
import {
    PointCloud, Mesh, PointAttribute, NAMED_ATTRIBUTES_COUNT, DT_INVALID, DT_TYPES_COUNT, DT_INT32, DT_FLOAT32,
    DT_UINT8, DT_INT8, DT_UINT16, DT_INT16, DT_UINT32, TRIANGULAR_MESH,
} from "./point_cloud";
import { PointCloudDecoder, MeshDecoder, AttributesDecoderInterface } from "./point_cloud_decoder";
import {
    CornerTableBase, MeshAttributeIndicesEncodingData, INVALID_INDEX,
} from "./corner_table";
import {
    PredictionSchemeDecoder, PredictionSchemeTransform, PredictionSchemeWrapDecodingTransform,
    PredictionSchemeNormalOctahedronDecodingTransform, PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform,
    PredictionSchemeDeltaDecoder, MeshPredictionSchemeData, MeshPredictionSchemeParallelogramDecoder,
    MeshPredictionSchemeMultiParallelogramDecoder, MeshPredictionSchemeConstrainedMultiParallelogramDecoder,
    MeshPredictionSchemeTexCoordsPortableDecoder, MeshPredictionSchemeGeometricNormalDecoder, OctahedronToolBox,
    PREDICTION_NONE, NUM_PREDICTION_SCHEMES, PREDICTION_TRANSFORM_NONE, NUM_PREDICTION_SCHEME_TRANSFORM_TYPES,
    PREDICTION_TRANSFORM_WRAP, PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON,
    PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON_CANONICALIZED, MESH_PREDICTION_PARALLELOGRAM,
    MESH_PREDICTION_MULTI_PARALLELOGRAM, MESH_PREDICTION_CONSTRAINED_MULTI_PARALLELOGRAM,
    MESH_PREDICTION_TEX_COORDS_PORTABLE, MESH_PREDICTION_GEOMETRIC_NORMAL, MESH_PREDICTION_TEX_COORDS_DEPRECATED,
} from "./prediction_schemes";
import { MeshPredictionSchemeTexCoordsDecoder } from "./tex_coords_deprecated";

// SequentialAttributeEncoderType.
export const SEQUENTIAL_ATTRIBUTE_ENCODER_GENERIC: i32 = 0;
export const SEQUENTIAL_ATTRIBUTE_ENCODER_INTEGER: i32 = 1;
export const SEQUENTIAL_ATTRIBUTE_ENCODER_QUANTIZATION: i32 = 2;
export const SEQUENTIAL_ATTRIBUTE_ENCODER_NORMALS: i32 = 3;

// ------------------------------------------------------------ factory

/// CreatePredictionSchemeForDecoder<int32_t, Transform>.
export function createPredictionSchemeForDecoder(method: i32, attId: i32, decoder: PointCloudDecoder,
                                                 transform: PredictionSchemeTransform): PredictionSchemeDecoder? {
    if (method == PREDICTION_NONE) return null;
    const att = decoder.pointCloud.attribute(attId);
    if (decoder.getGeometryType() == TRIANGULAR_MESH) {
        const ret = createMeshPredictionScheme(decoder as MeshDecoder, method, attId, att, transform);
        if (ret != null) return ret;
    }
    return new PredictionSchemeDeltaDecoder(att, transform);
}

function createMeshPredictionScheme(decoder: MeshDecoder, method: i32, attId: i32, att: PointAttribute,
                                    transform: PredictionSchemeTransform): PredictionSchemeDecoder? {
    if (method != MESH_PREDICTION_PARALLELOGRAM && method != MESH_PREDICTION_MULTI_PARALLELOGRAM
        && method != MESH_PREDICTION_CONSTRAINED_MULTI_PARALLELOGRAM && method != MESH_PREDICTION_TEX_COORDS_PORTABLE
        && method != MESH_PREDICTION_GEOMETRIC_NORMAL && method != MESH_PREDICTION_TEX_COORDS_DEPRECATED) return null;
    const ct = decoder.getCornerTable();
    const encodingData = decoder.getAttributeEncodingData(attId);
    if (ct == null || encodingData == null) return null;
    const attCt = decoder.getAttributeCornerTable(attId);
    const table: CornerTableBase = attCt != null ? <CornerTableBase>attCt : <CornerTableBase>ct;
    const md = new MeshPredictionSchemeData(table, encodingData);
    const type = transform.getType();
    if (type == PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON || type == PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON_CANONICALIZED) {
        if (method == MESH_PREDICTION_GEOMETRIC_NORMAL) return new MeshPredictionSchemeGeometricNormalDecoder(att, transform, md);
        return null;
    }
    if (method == MESH_PREDICTION_PARALLELOGRAM) return new MeshPredictionSchemeParallelogramDecoder(att, transform, md);
    if (method == MESH_PREDICTION_MULTI_PARALLELOGRAM) return new MeshPredictionSchemeMultiParallelogramDecoder(att, transform, md);
    if (method == MESH_PREDICTION_CONSTRAINED_MULTI_PARALLELOGRAM) {
        return new MeshPredictionSchemeConstrainedMultiParallelogramDecoder(att, transform, md);
    }
    if (method == MESH_PREDICTION_TEX_COORDS_DEPRECATED) {
        return new MeshPredictionSchemeTexCoordsDecoder(att, transform, md, decoder.bitstreamVersion());
    }
    if (method == MESH_PREDICTION_TEX_COORDS_PORTABLE) return new MeshPredictionSchemeTexCoordsPortableDecoder(att, transform, md);
    if (method == MESH_PREDICTION_GEOMETRIC_NORMAL) return new MeshPredictionSchemeGeometricNormalDecoder(att, transform, md);
    return null;
}

// ------------------------------------------------------------ transforms

/// AttributeQuantizationTransform (decoding side).
export class AttributeQuantizationTransform {
    quantizationBits: i32 = -1;
    minValues: Float32Array = new Float32Array(0);
    range: f32 = 0;

    decodeParameters(att: PointAttribute, buffer: DecoderBuffer): bool {
        const n = att.numComponents;
        this.minValues = new Float32Array(n);
        for (let i = 0; i < n; i++) this.minValues[i] = buffer.f32();
        this.range = buffer.f32();
        const bits = <i32>buffer.u8();
        if (buffer.failed) return false;
        if (bits < 1 || bits > 30) return false;
        this.quantizationBits = bits;
        return true;
    }

    setParameters(bits: i32, minValues: Float32Array, range: f32): bool {
        if (bits < 1 || bits > 30) return false;
        this.quantizationBits = bits;
        this.minValues = minValues;
        this.range = range;
        return true;
    }

    /// InverseTransformAttribute: int32 `source` values to floats in `target`.
    inverseTransformAttribute(source: PointAttribute, target: PointAttribute): bool {
        if (target.dataType != DT_FLOAT32) return false;
        const maxQuantizedValue = <i32>((<u32>1 << <u32>this.quantizationBits) - 1);
        if (maxQuantizedValue <= 0) return false;
        const delta: f32 = this.range / <f32>maxQuantizedValue;
        const n = target.numComponents;
        const src = source.ints;
        const out = target.floats;
        const count = target.size * n;
        const mins = this.minValues;
        for (let i = 0; i < count; i++) {
            out[i] = <f32>src[i] * delta + mins[i % n];
        }
        return true;
    }
}

/// AttributeOctahedronTransform (decoding side).
export class AttributeOctahedronTransform {
    quantizationBits: i32 = -1;

    decodeParameters(buffer: DecoderBuffer): bool {
        this.quantizationBits = <i32>buffer.u8();
        return !buffer.failed;
    }

    inverseTransformAttribute(source: PointAttribute, target: PointAttribute): bool {
        if (target.dataType != DT_FLOAT32 || target.numComponents != 3) return false;
        const tb = new OctahedronToolBox();
        if (!tb.setQuantizationBits(this.quantizationBits)) return false;
        const src = source.ints;
        const out = target.floats;
        const n = target.size;
        for (let i = 0; i < n; i++) {
            tb.quantizedOctahedralCoordsToUnitVector(src[i * 2], src[i * 2 + 1], out, i * 3);
        }
        return true;
    }
}

// ------------------------------------------------------------ sequencers

/// PointsSequencer: the order points' values were encoded in.
export abstract class PointsSequencer {
    outPointIds: Array<i32> = [];

    generateSequence(out: Array<i32>): bool {
        this.outPointIds = out;
        return this.generateSequenceInternal();
    }

    addPointId(point: i32): void { this.outPointIds.push(point); }

    updatePointToAttributeIndexMapping(att: PointAttribute): bool { return false; }

    protected abstract generateSequenceInternal(): bool;
}

/// LinearSequencer: points 0 .. n - 1.
export class LinearSequencer extends PointsSequencer {
    numPoints: i32;

    constructor(numPoints: i32) {
        super();
        this.numPoints = numPoints;
    }

    override updatePointToAttributeIndexMapping(att: PointAttribute): bool {
        att.setIdentityMapping();
        return true;
    }

    protected generateSequenceInternal(): bool {
        if (this.numPoints < 0) return false;
        for (let i = 0; i < this.numPoints; i++) this.outPointIds.push(i);
        return true;
    }
}

/// MeshAttributeIndicesEncodingObserver.
export class MeshAttributeIndicesEncodingObserver {
    mesh: Mesh;
    sequencer: PointsSequencer;
    encodingData: MeshAttributeIndicesEncodingData;

    constructor(mesh: Mesh, sequencer: PointsSequencer, encodingData: MeshAttributeIndicesEncodingData) {
        this.mesh = mesh;
        this.sequencer = sequencer;
        this.encodingData = encodingData;
    }

    onNewVertexVisited(vertex: i32, corner: i32): void {
        this.sequencer.addPointId(this.mesh.faces[corner]);
        const data = this.encodingData;
        data.encodedAttributeValueIndexToCornerMap.push(corner);
        data.vertexToEncodedAttributeValueIndexMap[vertex] = data.numValues;
        data.numValues++;
    }
}

/// TraverserBase.
export abstract class Traverser {
    cornerTable: CornerTableBase;
    observer: MeshAttributeIndicesEncodingObserver;
    isFaceVisited: Uint8Array;
    isVertexVisited: Uint8Array;

    constructor(cornerTable: CornerTableBase, observer: MeshAttributeIndicesEncodingObserver) {
        this.cornerTable = cornerTable;
        this.observer = observer;
        this.isFaceVisited = new Uint8Array(cornerTable.numFaces());
        this.isVertexVisited = new Uint8Array(cornerTable.numVertices());
    }

    @inline faceVisited(face: i32): bool {
        if (face < 0) return true;
        return this.isFaceVisited[face] != 0;
    }

    @inline cornerFaceVisited(corner: i32): bool {
        if (corner < 0) return true;
        return this.isFaceVisited[corner / 3] != 0;
    }

    onTraversalStart(): void {}
    onTraversalEnd(): void {}
    abstract traverseFromCorner(corner: i32): bool;
}

/// DepthFirstTraverser.
export class DepthFirstTraverser extends Traverser {
    stack: Array<i32> = [];

    traverseFromCorner(cornerId: i32): bool {
        if (this.cornerFaceVisited(cornerId)) return true;
        const ct = this.cornerTable;
        const stack = this.stack;
        stack.length = 0;
        stack.push(cornerId);
        const nextVert = ct.vertex(ct.next(cornerId));
        const prevVert = ct.vertex(ct.previous(cornerId));
        if (nextVert == INVALID_INDEX || prevVert == INVALID_INDEX) return false;
        if (this.isVertexVisited[nextVert] == 0) {
            this.isVertexVisited[nextVert] = 1;
            this.observer.onNewVertexVisited(nextVert, ct.next(cornerId));
        }
        if (this.isVertexVisited[prevVert] == 0) {
            this.isVertexVisited[prevVert] = 1;
            this.observer.onNewVertexVisited(prevVert, ct.previous(cornerId));
        }
        while (stack.length > 0) {
            cornerId = stack[stack.length - 1];
            let faceId = cornerId < 0 ? -1 : cornerId / 3;
            if (cornerId == INVALID_INDEX || this.faceVisited(faceId)) {
                stack.pop();
                continue;
            }
            while (true) {
                this.isFaceVisited[faceId] = 1;
                const vertId = ct.vertex(cornerId);
                if (vertId == INVALID_INDEX) return false;
                if (this.isVertexVisited[vertId] == 0) {
                    const onBoundary = ct.isOnBoundary(vertId);
                    this.isVertexVisited[vertId] = 1;
                    this.observer.onNewVertexVisited(vertId, cornerId);
                    if (!onBoundary) {
                        cornerId = ct.getRightCorner(cornerId);
                        faceId = cornerId / 3;
                        continue;
                    }
                }
                const rightCorner = ct.getRightCorner(cornerId);
                const leftCorner = ct.getLeftCorner(cornerId);
                const rightFace = rightCorner == INVALID_INDEX ? -1 : rightCorner / 3;
                const leftFace = leftCorner == INVALID_INDEX ? -1 : leftCorner / 3;
                if (this.faceVisited(rightFace)) {
                    if (this.faceVisited(leftFace)) {
                        stack.pop();
                        break;
                    } else {
                        cornerId = leftCorner;
                        faceId = leftFace;
                    }
                } else {
                    if (this.faceVisited(leftFace)) {
                        cornerId = rightCorner;
                        faceId = rightFace;
                    } else {
                        stack[stack.length - 1] = leftCorner;
                        stack.push(rightCorner);
                        break;
                    }
                }
            }
        }
        return true;
    }
}

const kMaxPriority: i32 = 3;

/// MaxPredictionDegreeTraverser.
export class MaxPredictionDegreeTraverser extends Traverser {
    stacks: Array<Array<i32>> = [[], [], []];
    bestPriority: i32 = 0;
    predictionDegree: Int32Array = new Int32Array(0);

    override onTraversalStart(): void {
        this.predictionDegree = new Int32Array(this.cornerTable.numVertices());
    }

    traverseFromCorner(cornerId: i32): bool {
        if (this.predictionDegree.length == 0) return true;
        const ct = this.cornerTable;
        this.stacks[0].push(cornerId);
        this.bestPriority = 0;
        const nextVert = ct.vertex(ct.next(cornerId));
        const prevVert = ct.vertex(ct.previous(cornerId));
        if (this.isVertexVisited[nextVert] == 0) {
            this.isVertexVisited[nextVert] = 1;
            this.observer.onNewVertexVisited(nextVert, ct.next(cornerId));
        }
        if (this.isVertexVisited[prevVert] == 0) {
            this.isVertexVisited[prevVert] = 1;
            this.observer.onNewVertexVisited(prevVert, ct.previous(cornerId));
        }
        const tipVertex = ct.vertex(cornerId);
        if (this.isVertexVisited[tipVertex] == 0) {
            this.isVertexVisited[tipVertex] = 1;
            this.observer.onNewVertexVisited(tipVertex, cornerId);
        }
        while ((cornerId = this.popNextCornerToTraverse()) != INVALID_INDEX) {
            let faceId = cornerId / 3;
            if (this.faceVisited(faceId)) continue;
            while (true) {
                faceId = cornerId / 3;
                this.isFaceVisited[faceId] = 1;
                const vertId = ct.vertex(cornerId);
                if (this.isVertexVisited[vertId] == 0) {
                    this.isVertexVisited[vertId] = 1;
                    this.observer.onNewVertexVisited(vertId, cornerId);
                }
                const rightCorner = ct.getRightCorner(cornerId);
                const leftCorner = ct.getLeftCorner(cornerId);
                const rightFace = rightCorner == INVALID_INDEX ? -1 : rightCorner / 3;
                const leftFace = leftCorner == INVALID_INDEX ? -1 : leftCorner / 3;
                const isRightVisited = this.faceVisited(rightFace);
                const isLeftVisited = this.faceVisited(leftFace);
                if (!isLeftVisited) {
                    const priority = this.computePriority(leftCorner);
                    if (isRightVisited && priority <= this.bestPriority) {
                        cornerId = leftCorner;
                        continue;
                    } else {
                        this.addCornerToTraversalStack(leftCorner, priority);
                    }
                }
                if (!isRightVisited) {
                    const priority = this.computePriority(rightCorner);
                    if (priority <= this.bestPriority) {
                        cornerId = rightCorner;
                        continue;
                    } else {
                        this.addCornerToTraversalStack(rightCorner, priority);
                    }
                }
                break;
            }
        }
        return true;
    }

    private popNextCornerToTraverse(): i32 {
        for (let i = this.bestPriority; i < kMaxPriority; ++i) {
            const s = this.stacks[i];
            if (s.length > 0) {
                const ret = s.pop();
                this.bestPriority = i;
                return ret;
            }
        }
        return INVALID_INDEX;
    }

    private addCornerToTraversalStack(ci: i32, priority: i32): void {
        this.stacks[priority].push(ci);
        if (priority < this.bestPriority) this.bestPriority = priority;
    }

    private computePriority(cornerId: i32): i32 {
        const vTip = this.cornerTable.vertex(cornerId);
        let priority = 0;
        if (this.isVertexVisited[vTip] == 0) {
            const degree = ++this.predictionDegree[vTip];
            priority = degree > 1 ? 1 : 2;
        }
        if (priority >= kMaxPriority) priority = kMaxPriority - 1;
        return priority;
    }
}

/// MeshTraversalSequencer: points in the order a traversal visits them.
export class MeshTraversalSequencer extends PointsSequencer {
    mesh: Mesh;
    encodingData: MeshAttributeIndicesEncodingData;
    traverser: Traverser? = null;

    constructor(mesh: Mesh, encodingData: MeshAttributeIndicesEncodingData) {
        super();
        this.mesh = mesh;
        this.encodingData = encodingData;
    }

    setTraverser(t: Traverser): void { this.traverser = t; }

    override updatePointToAttributeIndexMapping(att: PointAttribute): bool {
        const ct = this.traverser!.cornerTable;
        const mesh = this.mesh;
        att.setExplicitMapping(mesh.numPoints);
        const numFaces = mesh.numFaces;
        const numPoints = mesh.numPoints;
        const map = this.encodingData.vertexToEncodedAttributeValueIndexMap;
        for (let f = 0; f < numFaces; ++f) {
            for (let p = 0; p < 3; ++p) {
                const pointId = mesh.faces[f * 3 + p];
                const vertId = ct.vertex(f * 3 + p);
                if (vertId == INVALID_INDEX) return false;
                const attEntryId = map[vertId];
                if (pointId < 0 || pointId >= numPoints || attEntryId < 0 || attEntryId >= numPoints) return false;
                att.setPointMapEntry(pointId, attEntryId);
            }
        }
        return true;
    }

    protected generateSequenceInternal(): bool {
        const t = this.traverser!;
        t.onTraversalStart();
        const numFaces = t.cornerTable.numFaces();
        for (let i = 0; i < numFaces; ++i) {
            if (!t.traverseFromCorner(3 * i)) return false;
        }
        t.onTraversalEnd();
        return true;
    }
}

// ------------------------------------------------------------ attribute decoders

/// AttributesDecoder: the attributes one decoder owns.
export abstract class AttributesDecoder extends AttributesDecoderInterface {
    pointAttributeIds: Array<i32> = [];
    pointAttributeToLocalIdMap: Array<i32> = [];
    decoder: PointCloudDecoder = new PointCloudDecoder();
    pointCloud: PointCloud = new PointCloud();

    init(decoder: PointCloudDecoder, pc: PointCloud): bool {
        this.decoder = decoder;
        this.pointCloud = pc;
        return true;
    }

    decodeAttributesDecoderData(buffer: DecoderBuffer): bool {
        const version = this.decoder.bitstreamVersion();
        let numAttributes: u32;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numAttributes = buffer.u32();
        else numAttributes = buffer.varintU32();
        if (buffer.failed || numAttributes == 0) return false;
        if (<i64>numAttributes > 5 * <i64>buffer.remainingSize()) return false;
        const pc = this.pointCloud;
        for (let i: u32 = 0; i < numAttributes; ++i) {
            const attType = <i32>buffer.u8();
            const dataType = <i32>buffer.u8();
            const numComponents = <i32>buffer.u8();
            const normalized = buffer.u8();
            if (buffer.failed) return false;
            if (attType >= NAMED_ATTRIBUTES_COUNT) return false;
            if (dataType == DT_INVALID || dataType >= DT_TYPES_COUNT) return false;
            if (numComponents == 0) return false;
            const att = new PointAttribute().init(attType, numComponents, dataType, normalized > 0);
            let uniqueId: u32;
            if (version < DRACO_BITSTREAM_VERSION(1, 3)) uniqueId = buffer.u16();
            else uniqueId = buffer.varintU32();
            if (buffer.failed) return false;
            att.uniqueId = uniqueId;
            const attId = pc.addAttribute(att);
            this.pointAttributeIds.push(attId);
            while (this.pointAttributeToLocalIdMap.length <= attId) this.pointAttributeToLocalIdMap.push(-1);
            this.pointAttributeToLocalIdMap[attId] = <i32>i;
        }
        return true;
    }

    getAttributeId(i: i32): i32 { return this.pointAttributeIds[i]; }
    getNumAttributes(): i32 { return this.pointAttributeIds.length; }

    getLocalIdForPointAttribute(pointAttributeId: i32): i32 {
        if (pointAttributeId >= this.pointAttributeToLocalIdMap.length) return -1;
        return this.pointAttributeToLocalIdMap[pointAttributeId];
    }

    decodeAttributes(buffer: DecoderBuffer): bool {
        if (!this.decodePortableAttributes(buffer)) return false;
        if (!this.decodeDataNeededByPortableTransforms(buffer)) return false;
        return this.transformAttributesToOriginalFormat();
    }

    protected abstract decodePortableAttributes(buffer: DecoderBuffer): bool;
    protected decodeDataNeededByPortableTransforms(buffer: DecoderBuffer): bool { return true; }
    protected transformAttributesToOriginalFormat(): bool { return true; }
}

/// SequentialAttributeDecodersController: one sequential decoder per
/// attribute, over the points in the sequencer's order.
export class SequentialAttributeDecodersController extends AttributesDecoder {
    sequencer: PointsSequencer;
    sequentialDecoders: Array<SequentialAttributeDecoder> = [];
    pointIds: Int32Array = new Int32Array(0);

    constructor(sequencer: PointsSequencer) {
        super();
        this.sequencer = sequencer;
    }

    override decodeAttributesDecoderData(buffer: DecoderBuffer): bool {
        if (!super.decodeAttributesDecoderData(buffer)) return false;
        const n = this.getNumAttributes();
        for (let i = 0; i < n; ++i) {
            const type = <i32>buffer.u8();
            if (buffer.failed) return false;
            const d = createSequentialDecoder(type);
            if (d == null) return false;
            if (!d.init(this.decoder, this.getAttributeId(i))) return false;
            this.sequentialDecoders.push(d);
        }
        return true;
    }

    override decodeAttributes(buffer: DecoderBuffer): bool {
        const ids: Array<i32> = [];
        if (!this.sequencer.generateSequence(ids)) return false;
        const pointIds = new Int32Array(ids.length);
        for (let i = 0; i < ids.length; i++) pointIds[i] = ids[i];
        this.pointIds = pointIds;
        const n = this.getNumAttributes();
        for (let i = 0; i < n; ++i) {
            const pa = this.pointCloud.attribute(this.getAttributeId(i));
            if (!this.sequencer.updatePointToAttributeIndexMapping(pa)) return false;
        }
        return super.decodeAttributes(buffer);
    }

    override getPortableAttribute(pointAttributeId: i32): PointAttribute? {
        const loc = this.getLocalIdForPointAttribute(pointAttributeId);
        if (loc < 0) return null;
        return this.sequentialDecoders[loc].getPortableAttribute();
    }

    protected decodePortableAttributes(buffer: DecoderBuffer): bool {
        for (let i = 0; i < this.sequentialDecoders.length; ++i) {
            if (!this.sequentialDecoders[i].decodePortableAttribute(this.pointIds, buffer)) return false;
        }
        return true;
    }

    protected override decodeDataNeededByPortableTransforms(buffer: DecoderBuffer): bool {
        for (let i = 0; i < this.sequentialDecoders.length; ++i) {
            if (!this.sequentialDecoders[i].decodeDataNeededByPortableTransform(this.pointIds, buffer)) return false;
        }
        return true;
    }

    protected override transformAttributesToOriginalFormat(): bool {
        for (let i = 0; i < this.sequentialDecoders.length; ++i) {
            if (!this.sequentialDecoders[i].transformAttributeToOriginalFormat(this.pointIds)) return false;
        }
        return true;
    }
}

function createSequentialDecoder(type: i32): SequentialAttributeDecoder? {
    if (type == SEQUENTIAL_ATTRIBUTE_ENCODER_GENERIC) return new SequentialAttributeDecoder();
    if (type == SEQUENTIAL_ATTRIBUTE_ENCODER_INTEGER) return new SequentialIntegerAttributeDecoder();
    if (type == SEQUENTIAL_ATTRIBUTE_ENCODER_QUANTIZATION) return new SequentialQuantizationAttributeDecoder();
    if (type == SEQUENTIAL_ATTRIBUTE_ENCODER_NORMALS) return new SequentialNormalAttributeDecoder();
    return null;
}

/// SequentialAttributeDecoder: raw values, as encoded.
export class SequentialAttributeDecoder {
    decoder: PointCloudDecoder = new PointCloudDecoder();
    attribute: PointAttribute = new PointAttribute();
    attributeId: i32 = -1;
    portableAttribute: PointAttribute? = null;

    init(decoder: PointCloudDecoder, attributeId: i32): bool {
        this.decoder = decoder;
        this.attribute = decoder.pointCloud.attribute(attributeId);
        this.attributeId = attributeId;
        return true;
    }

    decodePortableAttribute(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        if (this.attribute.numComponents <= 0 || !this.attribute.reset(pointIds.length)) return false;
        return this.decodeValues(pointIds, buffer);
    }

    decodeDataNeededByPortableTransform(pointIds: Int32Array, buffer: DecoderBuffer): bool { return true; }

    transformAttributeToOriginalFormat(pointIds: Int32Array): bool { return true; }

    /// GetPortableAttribute: the portable attribute, given the final
    /// attribute's point mapping when it has none.
    getPortableAttribute(): PointAttribute? {
        const portable = this.portableAttribute;
        const att = this.attribute;
        if (!att.isMappingIdentity() && portable != null && portable.isMappingIdentity()) {
            const n = att.indicesMapSize();
            portable.setExplicitMapping(n);
            for (let i = 0; i < n; ++i) portable.setPointMapEntry(i, att.mappedIndex(i));
        }
        return portable;
    }

    protected initPredictionScheme(ps: PredictionSchemeDecoder): bool {
        const n = ps.getNumParentAttributes();
        for (let i = 0; i < n; ++i) {
            const attId = this.decoder.pointCloud.getNamedAttributeId(ps.getParentAttributeType(i));
            if (attId == -1) return false;
            if (this.decoder.bitstreamVersion() < DRACO_BITSTREAM_VERSION(2, 0)) {
                if (!ps.setParentAttribute(this.decoder.pointCloud.attribute(attId))) return false;
            } else {
                const pa = this.decoder.getPortableAttribute(attId);
                if (pa == null || !ps.setParentAttribute(pa)) return false;
            }
        }
        return true;
    }

    protected decodeValues(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        const att = this.attribute;
        const bytes = pointIds.length * att.byteStride;
        return buffer.bytes(att.bytes, 0, bytes);
    }
}

/// SequentialIntegerAttributeDecoder: int32 values with a prediction scheme.
export class SequentialIntegerAttributeDecoder extends SequentialAttributeDecoder {
    predictionScheme: PredictionSchemeDecoder? = null;

    override transformAttributeToOriginalFormat(pointIds: Int32Array): bool {
        if (this.decoder.bitstreamVersion() < DRACO_BITSTREAM_VERSION(2, 0)) return true;
        return this.storeValues(pointIds.length);
    }

    protected override decodeValues(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        const method = buffer.i8();
        if (buffer.failed) return false;
        if (method < PREDICTION_NONE || method >= NUM_PREDICTION_SCHEMES) return false;
        if (method != PREDICTION_NONE) {
            const transformType = buffer.i8();
            if (buffer.failed) return false;
            if (transformType < PREDICTION_TRANSFORM_NONE || transformType >= NUM_PREDICTION_SCHEME_TRANSFORM_TYPES) return false;
            this.predictionScheme = this.createIntPredictionScheme(method, transformType);
        }
        const ps = this.predictionScheme;
        if (ps != null && !this.initPredictionScheme(ps)) return false;
        if (!this.decodeIntegerValues(pointIds, buffer)) return false;
        if (this.decoder.bitstreamVersion() < DRACO_BITSTREAM_VERSION(2, 0)) {
            if (!this.storeValues(pointIds.length)) return false;
        }
        return true;
    }

    protected createIntPredictionScheme(method: i32, transformType: i32): PredictionSchemeDecoder? {
        if (transformType != PREDICTION_TRANSFORM_WRAP) return null;
        return createPredictionSchemeForDecoder(method, this.attributeId, this.decoder, new PredictionSchemeWrapDecodingTransform());
    }

    protected getNumValueComponents(): i32 { return this.attribute.numComponents; }

    protected decodeIntegerValues(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        const numComponents = this.getNumValueComponents();
        if (numComponents <= 0) return false;
        const numEntries = pointIds.length;
        const numValues = numEntries * numComponents;
        const portable = this.preparePortableAttribute(numEntries, numComponents);
        if (portable.size == 0) return false;
        const data = portable.ints;
        const compressed = buffer.u8();
        if (buffer.failed) return false;
        if (compressed > 0) {
            if (!decodeSymbols(<u32>numValues, numComponents, buffer, data)) return false;
        } else {
            const numBytes = <i32>buffer.u8();
            if (buffer.failed) return false;
            if (<i64>numBytes * <i64>numValues > <i64>buffer.remainingSize()) return false;
            if (numBytes > 4) return false;
            const d = buffer.data;
            let at = buffer.head;
            for (let i = 0; i < numValues; ++i) {
                let v: u32 = 0;
                for (let b = 0; b < numBytes; b++) v |= <u32>d[at + b] << <u32>(8 * b);
                data[i] = <i32>v;
                at += numBytes;
            }
            buffer.advance(numBytes * numValues);
        }
        const ps = this.predictionScheme;
        if (numValues > 0 && (ps == null || !ps.areCorrectionsPositive())) {
            for (let i = 0; i < numValues; i++) data[i] = convertSymbolToSignedInt(<u32>data[i]);
        }
        if (ps != null) {
            if (!ps.decodePredictionData(buffer)) return false;
            if (numValues > 0) {
                if (!ps.computeOriginalValues(data, numValues, numComponents, pointIds)) return false;
            }
        }
        return true;
    }

    /// StoreValues: the int32 portable values into the attribute's type.
    protected storeValues(numValues: i32): bool {
        const att = this.attribute;
        const dt = att.dataType;
        if (dt != DT_UINT8 && dt != DT_INT8 && dt != DT_UINT16 && dt != DT_INT16 && dt != DT_UINT32 && dt != DT_INT32) return false;
        const src = this.portableAttribute!.ints;
        const n = att.numComponents;
        const count = numValues * n;
        if (dt == DT_INT32 || dt == DT_UINT32) {
            for (let i = 0; i < count; i++) att.ints[i] = src[i];
        } else {
            for (let i = 0; i < count; i++) att.setComponent(i / n, i % n, <f64>src[i]);
        }
        return true;
    }

    protected preparePortableAttribute(numEntries: i32, numComponents: i32): PointAttribute {
        const att = new PointAttribute().init(this.attribute.attributeType, numComponents, DT_INT32, false);
        att.setIdentityMapping();
        att.reset(numEntries);
        att.uniqueId = this.attribute.uniqueId;
        this.portableAttribute = att;
        return att;
    }
}

/// SequentialQuantizationAttributeDecoder: quantized floats.
export class SequentialQuantizationAttributeDecoder extends SequentialIntegerAttributeDecoder {
    quantizationTransform: AttributeQuantizationTransform = new AttributeQuantizationTransform();

    override init(decoder: PointCloudDecoder, attributeId: i32): bool {
        if (!super.init(decoder, attributeId)) return false;
        return this.attribute.dataType == DT_FLOAT32;
    }

    protected override decodeIntegerValues(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        if (this.decoder.bitstreamVersion() < DRACO_BITSTREAM_VERSION(2, 0) && !this.decodeQuantizedDataInfo()) return false;
        return super.decodeIntegerValues(pointIds, buffer);
    }

    override decodeDataNeededByPortableTransform(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        if (this.decoder.bitstreamVersion() >= DRACO_BITSTREAM_VERSION(2, 0)) {
            if (!this.decodeQuantizedDataInfo()) return false;
        }
        return true;
    }

    protected override storeValues(numValues: i32): bool {
        return this.quantizationTransform.inverseTransformAttribute(this.getPortableAttribute()!, this.attribute);
    }

    private decodeQuantizedDataInfo(): bool {
        let att = this.getPortableAttribute();
        if (att == null) att = this.attribute;
        return this.quantizationTransform.decodeParameters(att!, this.decoder.buffer);
    }
}

/// SequentialNormalAttributeDecoder: octahedral normals.
export class SequentialNormalAttributeDecoder extends SequentialIntegerAttributeDecoder {
    octahedralTransform: AttributeOctahedronTransform = new AttributeOctahedronTransform();

    override init(decoder: PointCloudDecoder, attributeId: i32): bool {
        if (!super.init(decoder, attributeId)) return false;
        return this.attribute.numComponents == 3 && this.attribute.dataType == DT_FLOAT32;
    }

    protected override getNumValueComponents(): i32 { return 2; }

    protected override decodeIntegerValues(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        if (this.decoder.bitstreamVersion() < DRACO_BITSTREAM_VERSION(2, 0)) {
            if (!this.octahedralTransform.decodeParameters(buffer)) return false;
        }
        return super.decodeIntegerValues(pointIds, buffer);
    }

    override decodeDataNeededByPortableTransform(pointIds: Int32Array, buffer: DecoderBuffer): bool {
        if (this.decoder.bitstreamVersion() >= DRACO_BITSTREAM_VERSION(2, 0)) {
            if (!this.octahedralTransform.decodeParameters(buffer)) return false;
        }
        return true;
    }

    protected override storeValues(numValues: i32): bool {
        return this.octahedralTransform.inverseTransformAttribute(this.getPortableAttribute()!, this.attribute);
    }

    protected override createIntPredictionScheme(method: i32, transformType: i32): PredictionSchemeDecoder? {
        if (transformType == PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON) {
            return createPredictionSchemeForDecoder(method, this.attributeId, this.decoder,
                new PredictionSchemeNormalOctahedronDecodingTransform());
        }
        if (transformType == PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON_CANONICALIZED) {
            return createPredictionSchemeForDecoder(method, this.attributeId, this.decoder,
                new PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform());
        }
        return null;
    }
}
