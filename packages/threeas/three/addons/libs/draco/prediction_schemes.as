// Draco's prediction schemes and their transforms (compression/attributes/
// prediction_schemes/, normal_compression_utils.h), decoding side, ported
// from Google's Draco decoder (Apache License 2.0,
// https://github.com/google/draco) to AnimaScript.
//
// Values are int32 (DataTypeT is always int32_t when decoding). The
// corrections and the decoded values share one array, as Draco decodes in
// place (in_corr == out_data); entries are offsets into it.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION, mostSignificantBit } from "./decoder_buffer";
import { PointAttribute, INVALID, POSITION } from "./point_cloud";
import { CornerTableBase, MeshAttributeIndicesEncodingData, INVALID_INDEX, vertexCorners } from "./corner_table";
import { RAnsBitDecoder } from "./bit_decoders";

// PredictionSchemeMethod.
export const PREDICTION_NONE: i32 = -2;
export const PREDICTION_UNDEFINED: i32 = -1;
export const PREDICTION_DIFFERENCE: i32 = 0;
export const MESH_PREDICTION_PARALLELOGRAM: i32 = 1;
export const MESH_PREDICTION_MULTI_PARALLELOGRAM: i32 = 2;
export const MESH_PREDICTION_TEX_COORDS_DEPRECATED: i32 = 3;
export const MESH_PREDICTION_CONSTRAINED_MULTI_PARALLELOGRAM: i32 = 4;
export const MESH_PREDICTION_TEX_COORDS_PORTABLE: i32 = 5;
export const MESH_PREDICTION_GEOMETRIC_NORMAL: i32 = 6;
export const NUM_PREDICTION_SCHEMES: i32 = 7;

// PredictionSchemeTransformType.
export const PREDICTION_TRANSFORM_NONE: i32 = -1;
export const PREDICTION_TRANSFORM_DELTA: i32 = 0;
export const PREDICTION_TRANSFORM_WRAP: i32 = 1;
export const PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON: i32 = 2;
export const PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON_CANONICALIZED: i32 = 3;
export const NUM_PREDICTION_SCHEME_TRANSFORM_TYPES: i32 = 4;

// NormalPredictionMode.
const ONE_TRIANGLE: i32 = 0;
const TRIANGLE_AREA: i32 = 1;

// ------------------------------------------------------------ octahedron

/// OctahedronToolBox (normal_compression_utils.h).
export class OctahedronToolBox {
    quantizationBits: i32 = -1;
    maxQuantizedValue: i32 = -1;
    maxValue: i32 = -1;
    dequantizationScale: f32 = 1;
    centerValue: i32 = -1;

    setQuantizationBits(q: i32): bool {
        if (q < 2 || q > 30) return false;
        this.quantizationBits = q;
        this.maxQuantizedValue = (1 << q) - 1;
        this.maxValue = this.maxQuantizedValue - 1;
        this.dequantizationScale = <f32>2.0 / <f32>this.maxValue;
        this.centerValue = this.maxValue / 2;
        return true;
    }

    isInitialized(): bool { return this.quantizationBits != -1; }

    /// IntegerVectorToQuantizedOctahedralCoords then
    /// CanonicalizeOctahedralCoords; the result in out[0], out[1].
    integerVectorToQuantizedOctahedralCoords(x: i32, y: i32, z: i32, out: Int32Array): void {
        let s: i32, t: i32;
        const center = this.centerValue;
        const maxV = this.maxValue;
        if (x >= 0) {
            s = y + center;
            t = z + center;
        } else {
            s = y < 0 ? abs<i32>(z) : maxV - abs<i32>(z);
            t = z < 0 ? abs<i32>(y) : maxV - abs<i32>(y);
        }
        // CanonicalizeOctahedralCoords.
        if ((s == 0 && t == 0) || (s == 0 && t == maxV) || (s == maxV && t == 0)) {
            s = maxV;
            t = maxV;
        } else if (s == 0 && t > center) {
            t = center - (t - center);
        } else if (s == maxV && t < center) {
            t = center + (center - t);
        } else if (t == maxV && s < center) {
            s = center + (center - s);
        } else if (t == 0 && s > center) {
            s = center - (s - center);
        }
        out[0] = s;
        out[1] = t;
    }

    /// CanonicalizeIntegerVector (in place on v[0..2]).
    canonicalizeIntegerVector(v: Int32Array): void {
        const absSum = <i64>abs<i32>(v[0]) + <i64>abs<i32>(v[1]) + <i64>abs<i32>(v[2]);
        const center = <i64>this.centerValue;
        if (absSum == 0) {
            v[0] = this.centerValue;
        } else {
            v[0] = <i32>((<i64>v[0] * center) / absSum);
            v[1] = <i32>((<i64>v[1] * center) / absSum);
            if (v[2] >= 0) v[2] = this.centerValue - abs<i32>(v[0]) - abs<i32>(v[1]);
            else v[2] = -(this.centerValue - abs<i32>(v[0]) - abs<i32>(v[1]));
        }
    }

    /// QuantizedOctahedralCoordsToUnitVector into out[offset..offset+2].
    quantizedOctahedralCoordsToUnitVector(inS: i32, inT: i32, out: Float32Array, offset: i32): void {
        let y: f32 = <f32>inS * this.dequantizationScale - <f32>1.0;
        let z: f32 = <f32>inT * this.dequantizationScale - <f32>1.0;
        const x: f32 = <f32>1.0 - Mathf.abs(y) - Mathf.abs(z);
        let xOffset: f32 = -x;
        xOffset = xOffset < 0 ? 0 : xOffset;
        y += y < 0 ? xOffset : -xOffset;
        z += z < 0 ? xOffset : -xOffset;
        const normSquared: f32 = x * x + y * y + z * z;
        if (normSquared < <f32>1e-6) {
            out[offset] = 0;
            out[offset + 1] = 0;
            out[offset + 2] = 0;
        } else {
            const d: f32 = <f32>1.0 / Mathf.sqrt(normSquared);
            out[offset] = x * d;
            out[offset + 1] = y * d;
            out[offset + 2] = z * d;
        }
    }

    isInDiamond(s: i32, t: i32): bool {
        return <u32>abs<i32>(s) + <u32>abs<i32>(t) <= <u32>this.centerValue;
    }

    /// InvertDiamond on p[0], p[1].
    invertDiamond(p: Int32Array): void {
        const s = p[0], t = p[1];
        let signS: i32, signT: i32;
        if (s >= 0 && t >= 0) {
            signS = 1;
            signT = 1;
        } else if (s <= 0 && t <= 0) {
            signS = -1;
            signT = -1;
        } else {
            signS = s > 0 ? 1 : -1;
            signT = t > 0 ? 1 : -1;
        }
        // Draco's uint32 arithmetic: the same bits in wrapping i32.
        const cornerS = signS * this.centerValue;
        const cornerT = signT * this.centerValue;
        let us = s + s - cornerS;
        let ut = t + t - cornerT;
        if (signS * signT >= 0) {
            const temp = us;
            us = -ut;
            ut = -temp;
        } else {
            const temp = us;
            us = ut;
            ut = temp;
        }
        us = us + cornerS;
        ut = ut + cornerT;
        p[0] = us / 2;
        p[1] = ut / 2;
    }

    modMax(x: i32): i32 {
        if (x > this.centerValue) return x - this.maxQuantizedValue;
        if (x < -this.centerValue) return x + this.maxQuantizedValue;
        return x;
    }
}

// ------------------------------------------------------------ transforms

/// PredictionSchemeDecodingTransform: the base of the decoding transforms.
export abstract class PredictionSchemeTransform {
    numComponents: i32 = 0;

    init(numComponents: i32): void { this.numComponents = numComponents; }

    /// out[outOff..] = original(pred[predOff..], corr[corrOff..]).
    abstract computeOriginalValue(pred: Int32Array, predOff: i32, corr: Int32Array, corrOff: i32,
                                  out: Int32Array, outOff: i32): void;

    decodeTransformData(buffer: DecoderBuffer): bool { return true; }
    areCorrectionsPositive(): bool { return false; }
    abstract getType(): i32;
    quantizationBits(): i32 { return -1; }
}

/// PredictionSchemeWrapDecodingTransform<int32_t>.
export class PredictionSchemeWrapDecodingTransform extends PredictionSchemeTransform {
    minValue: i32 = 0;
    maxValue: i32 = 0;
    maxDif: i32 = 0;
    maxCorrection: i32 = 0;
    minCorrection: i32 = 0;
    clamped: Int32Array = new Int32Array(0);

    override init(numComponents: i32): void {
        this.numComponents = numComponents;
        this.clamped = new Int32Array(numComponents);
    }

    getType(): i32 { return PREDICTION_TRANSFORM_WRAP; }

    computeOriginalValue(pred: Int32Array, predOff: i32, corr: Int32Array, corrOff: i32,
                         out: Int32Array, outOff: i32): void {
        const n = this.numComponents;
        const clamped = this.clamped;
        const minV = this.minValue, maxV = this.maxValue;
        for (let i = 0; i < n; ++i) {
            const p = pred[predOff + i];
            clamped[i] = p > maxV ? maxV : p < minV ? minV : p;
        }
        for (let i = 0; i < n; ++i) {
            let v = clamped[i] + corr[corrOff + i];
            if (v > maxV) v -= this.maxDif;
            else if (v < minV) v += this.maxDif;
            out[outOff + i] = v;
        }
    }

    override decodeTransformData(buffer: DecoderBuffer): bool {
        const minValue = buffer.i32();
        const maxValue = buffer.i32();
        if (buffer.failed || minValue > maxValue) return false;
        this.minValue = minValue;
        this.maxValue = maxValue;
        // InitCorrectionBounds.
        const dif = <i64>maxValue - <i64>minValue;
        if (dif < 0 || dif >= 0x7FFFFFFF) return false;
        this.maxDif = 1 + <i32>dif;
        this.maxCorrection = this.maxDif / 2;
        this.minCorrection = -this.maxCorrection;
        if ((this.maxDif & 1) == 0) this.maxCorrection -= 1;
        return true;
    }
}

/// PredictionSchemeNormalOctahedronTransformBase.
export abstract class NormalOctahedronTransformBase extends PredictionSchemeTransform {
    toolBox: OctahedronToolBox = new OctahedronToolBox();
    point: Int32Array = new Int32Array(2);

    override init(numComponents: i32): void {}
    override areCorrectionsPositive(): bool { return true; }
    override quantizationBits(): i32 { return this.toolBox.quantizationBits; }

    setMaxQuantizedValue(maxQuantizedValue: i32): bool {
        if (maxQuantizedValue % 2 == 0) return false;
        const q = mostSignificantBit(<u32>maxQuantizedValue) + 1;
        return this.toolBox.setQuantizationBits(q);
    }
}

/// PredictionSchemeNormalOctahedronDecodingTransform (bitstreams < 2.2's
/// normals; kept for backwards compatibility, as Draco).
export class PredictionSchemeNormalOctahedronDecodingTransform extends NormalOctahedronTransformBase {
    getType(): i32 { return PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON; }

    override decodeTransformData(buffer: DecoderBuffer): bool {
        const maxQuantizedValue = buffer.i32();
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) buffer.i32();   // center_value
        if (buffer.failed) return false;
        return this.setMaxQuantizedValue(maxQuantizedValue);
    }

    computeOriginalValue(pred: Int32Array, predOff: i32, corr: Int32Array, corrOff: i32,
                         out: Int32Array, outOff: i32): void {
        const tb = this.toolBox;
        const center = tb.centerValue;
        const p = this.point;
        p[0] = pred[predOff] - center;
        p[1] = pred[predOff + 1] - center;
        const c0 = corr[corrOff], c1 = corr[corrOff + 1];
        const inDiamond = tb.isInDiamond(p[0], p[1]);
        if (!inDiamond) tb.invertDiamond(p);
        p[0] = tb.modMax(p[0] + c0);
        p[1] = tb.modMax(p[1] + c1);
        if (!inDiamond) tb.invertDiamond(p);
        out[outOff] = p[0] + center;
        out[outOff + 1] = p[1] + center;
    }
}

/// PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform.
export class PredictionSchemeNormalOctahedronCanonicalizedDecodingTransform extends NormalOctahedronTransformBase {
    getType(): i32 { return PREDICTION_TRANSFORM_NORMAL_OCTAHEDRON_CANONICALIZED; }

    override decodeTransformData(buffer: DecoderBuffer): bool {
        const maxQuantizedValue = buffer.i32();
        buffer.i32();   // center_value
        if (buffer.failed) return false;
        if (!this.setMaxQuantizedValue(maxQuantizedValue)) return false;
        const q = this.toolBox.quantizationBits;
        return q >= 2 && q <= 30;
    }

    computeOriginalValue(pred: Int32Array, predOff: i32, corr: Int32Array, corrOff: i32,
                         out: Int32Array, outOff: i32): void {
        const tb = this.toolBox;
        const center = tb.centerValue;
        const p = this.point;
        p[0] = pred[predOff] - center;
        p[1] = pred[predOff + 1] - center;
        const c0 = corr[corrOff], c1 = corr[corrOff + 1];
        const inDiamond = tb.isInDiamond(p[0], p[1]);
        if (!inDiamond) tb.invertDiamond(p);
        const inBottomLeft = isInBottomLeft(p[0], p[1]);
        const rotationCount = getRotationCount(p[0], p[1]);
        if (!inBottomLeft) rotatePoint(p, rotationCount);
        p[0] = tb.modMax(p[0] + c0);
        p[1] = tb.modMax(p[1] + c1);
        if (!inBottomLeft) rotatePoint(p, (4 - rotationCount) % 4);
        if (!inDiamond) tb.invertDiamond(p);
        out[outOff] = p[0] + center;
        out[outOff + 1] = p[1] + center;
    }
}

function getRotationCount(x: i32, y: i32): i32 {
    if (x == 0) {
        if (y == 0) return 0;
        return y > 0 ? 3 : 1;
    }
    if (x > 0) return y >= 0 ? 2 : 1;
    return y <= 0 ? 0 : 3;
}

function rotatePoint(p: Int32Array, rotationCount: i32): void {
    const x = p[0], y = p[1];
    if (rotationCount == 1) {
        p[0] = y;
        p[1] = -x;
    } else if (rotationCount == 2) {
        p[0] = -x;
        p[1] = -y;
    } else if (rotationCount == 3) {
        p[0] = -y;
        p[1] = x;
    }
}

function isInBottomLeft(x: i32, y: i32): bool {
    if (x == 0 && y == 0) return true;
    return x < 0 && y <= 0;
}

// ------------------------------------------------------------ schemes

/// MeshPredictionSchemeData: the connectivity a mesh scheme predicts over.
export class MeshPredictionSchemeData {
    cornerTable: CornerTableBase;
    /// vertex_to_data_map and data_to_corner_map, in here.
    encodingData: MeshAttributeIndicesEncodingData;

    constructor(cornerTable: CornerTableBase, encodingData: MeshAttributeIndicesEncodingData) {
        this.cornerTable = cornerTable;
        this.encodingData = encodingData;
    }
}

/// PredictionSchemeDecoder<int32_t, Transform>.
export abstract class PredictionSchemeDecoder {
    attribute: PointAttribute;
    transform: PredictionSchemeTransform;

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform) {
        this.attribute = attribute;
        this.transform = transform;
    }

    decodePredictionData(buffer: DecoderBuffer): bool {
        return this.transform.decodeTransformData(buffer);
    }

    /// Decodes in place: `data` holds the corrections and receives the values.
    abstract computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool;

    getNumParentAttributes(): i32 { return 0; }
    getParentAttributeType(i: i32): i32 { return INVALID; }
    setParentAttribute(att: PointAttribute): bool { return false; }
    areCorrectionsPositive(): bool { return this.transform.areCorrectionsPositive(); }
    abstract getPredictionMethod(): i32;
}

/// PredictionSchemeDeltaDecoder.
export class PredictionSchemeDeltaDecoder extends PredictionSchemeDecoder {
    getPredictionMethod(): i32 { return PREDICTION_DIFFERENCE; }

    computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool {
        const t = this.transform;
        t.init(numComponents);
        const zero = new Int32Array(numComponents);
        t.computeOriginalValue(zero, 0, data, 0, data, 0);
        for (let i = numComponents; i < size; i += numComponents) {
            t.computeOriginalValue(data, i - numComponents, data, i, data, i);
        }
        return true;
    }
}

/// ComputeParallelogramPrediction: false when not every vertex of the
/// opposite triangle is decoded yet.
function computeParallelogramPrediction(dataEntryId: i32, ci: i32, table: CornerTableBase,
                                        vertexToDataMap: Int32Array, inData: Int32Array,
                                        numComponents: i32, out: Int32Array, outOff: i32): bool {
    const oci = table.opposite(ci);
    if (oci == INVALID_INDEX) return false;
    const vertOpp = vertexToDataMap[table.vertex(oci)];
    const vertNext = vertexToDataMap[table.vertex(table.next(oci))];
    const vertPrev = vertexToDataMap[table.vertex(table.previous(oci))];
    if (vertOpp < dataEntryId && vertNext < dataEntryId && vertPrev < dataEntryId) {
        const oppOff = vertOpp * numComponents;
        const nextOff = vertNext * numComponents;
        const prevOff = vertPrev * numComponents;
        for (let c = 0; c < numComponents; ++c) {
            out[outOff + c] = (inData[nextOff + c] + inData[prevOff + c]) - inData[oppOff + c];
        }
        return true;
    }
    return false;
}

/// MeshPredictionSchemeParallelogramDecoder.
export class MeshPredictionSchemeParallelogramDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform, meshData: MeshPredictionSchemeData) {
        super(attribute, transform);
        this.meshData = meshData;
    }

    getPredictionMethod(): i32 { return MESH_PREDICTION_PARALLELOGRAM; }

    computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool {
        const t = this.transform;
        t.init(numComponents);
        const table = this.meshData.cornerTable;
        const vertexToDataMap = this.meshData.encodingData.vertexToEncodedAttributeValueIndexMap;
        const dataToCorner = this.meshData.encodingData.encodedAttributeValueIndexToCornerMap;
        const pred = new Int32Array(numComponents);
        t.computeOriginalValue(pred, 0, data, 0, data, 0);
        const n = dataToCorner.length;
        for (let p = 1; p < n; ++p) {
            const cornerId = dataToCorner[p];
            const dst = p * numComponents;
            if (!computeParallelogramPrediction(p, cornerId, table, vertexToDataMap, data, numComponents, pred, 0)) {
                t.computeOriginalValue(data, (p - 1) * numComponents, data, dst, data, dst);
            } else {
                t.computeOriginalValue(pred, 0, data, dst, data, dst);
            }
        }
        return true;
    }
}

/// MeshPredictionSchemeMultiParallelogramDecoder (backwards compatibility).
export class MeshPredictionSchemeMultiParallelogramDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform, meshData: MeshPredictionSchemeData) {
        super(attribute, transform);
        this.meshData = meshData;
    }

    getPredictionMethod(): i32 { return MESH_PREDICTION_MULTI_PARALLELOGRAM; }

    computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool {
        const t = this.transform;
        t.init(numComponents);
        const pred = new Int32Array(numComponents);
        const para = new Int32Array(numComponents);
        t.computeOriginalValue(pred, 0, data, 0, data, 0);
        const table = this.meshData.cornerTable;
        const vertexToDataMap = this.meshData.encodingData.vertexToEncodedAttributeValueIndexMap;
        const dataToCorner = this.meshData.encodingData.encodedAttributeValueIndexToCornerMap;
        const n = dataToCorner.length;
        for (let p = 1; p < n; ++p) {
            const startCorner = dataToCorner[p];
            let corner = startCorner;
            let numParallelograms = 0;
            for (let i = 0; i < numComponents; ++i) pred[i] = 0;
            while (corner != INVALID_INDEX) {
                if (computeParallelogramPrediction(p, corner, table, vertexToDataMap, data, numComponents, para, 0)) {
                    for (let c = 0; c < numComponents; ++c) pred[c] = pred[c] + para[c];
                    ++numParallelograms;
                }
                corner = table.swingRight(corner);
                if (corner == startCorner) corner = INVALID_INDEX;
            }
            const dst = p * numComponents;
            if (numParallelograms == 0) {
                t.computeOriginalValue(data, (p - 1) * numComponents, data, dst, data, dst);
            } else {
                for (let c = 0; c < numComponents; ++c) pred[c] = pred[c] / numParallelograms;
                t.computeOriginalValue(pred, 0, data, dst, data, dst);
            }
        }
        return true;
    }
}

const kMaxNumParallelograms: i32 = 4;

/// MeshPredictionSchemeConstrainedMultiParallelogramDecoder.
export class MeshPredictionSchemeConstrainedMultiParallelogramDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;
    isCreaseEdge: Array<Uint8Array> = [];

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform, meshData: MeshPredictionSchemeData) {
        super(attribute, transform);
        this.meshData = meshData;
        for (let i = 0; i < kMaxNumParallelograms; i++) this.isCreaseEdge.push(new Uint8Array(0));
    }

    getPredictionMethod(): i32 { return MESH_PREDICTION_CONSTRAINED_MULTI_PARALLELOGRAM; }

    override decodePredictionData(buffer: DecoderBuffer): bool {
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) {
            const mode = buffer.u8();
            if (buffer.failed || mode != 0) return false;   // OPTIMAL_MULTI_PARALLELOGRAM
        }
        for (let i = 0; i < kMaxNumParallelograms; ++i) {
            const numFlags = buffer.varintU32();
            if (buffer.failed) return false;
            if (<i64>numFlags > <i64>this.meshData.cornerTable.numCorners()) return false;
            if (numFlags > 0) {
                const flags = new Uint8Array(<i32>numFlags);
                const decoder = new RAnsBitDecoder();
                if (!decoder.startDecoding(buffer)) return false;
                for (let j = 0; j < <i32>numFlags; ++j) flags[j] = decoder.decodeNextBit() ? 1 : 0;
                decoder.endDecoding();
                this.isCreaseEdge[i] = flags;
            }
        }
        return super.decodePredictionData(buffer);
    }

    computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool {
        const t = this.transform;
        t.init(numComponents);
        const predVals = new Int32Array(kMaxNumParallelograms * numComponents);
        t.computeOriginalValue(predVals, 0, data, 0, data, 0);
        const table = this.meshData.cornerTable;
        const vertexToDataMap = this.meshData.encodingData.vertexToEncodedAttributeValueIndexMap;
        const dataToCorner = this.meshData.encodingData.encodedAttributeValueIndexToCornerMap;
        const isCreaseEdgePos = new Int32Array(kMaxNumParallelograms);
        const multiPred = new Int32Array(numComponents);
        const n = dataToCorner.length;
        for (let p = 1; p < n; ++p) {
            const startCorner = dataToCorner[p];
            let corner = startCorner;
            let numParallelograms = 0;
            let firstPass = true;
            while (corner != INVALID_INDEX) {
                if (computeParallelogramPrediction(p, corner, table, vertexToDataMap, data, numComponents,
                        predVals, numParallelograms * numComponents)) {
                    ++numParallelograms;
                    if (numParallelograms == kMaxNumParallelograms) break;
                }
                if (firstPass) corner = table.swingLeft(corner);
                else corner = table.swingRight(corner);
                if (corner == startCorner) break;
                if (corner == INVALID_INDEX && firstPass) {
                    firstPass = false;
                    corner = table.swingRight(startCorner);
                }
            }
            let numUsed = 0;
            if (numParallelograms > 0) {
                for (let i = 0; i < numComponents; ++i) multiPred[i] = 0;
                for (let i = 0; i < numParallelograms; ++i) {
                    const context = numParallelograms - 1;
                    const pos = isCreaseEdgePos[context]++;
                    const flags = this.isCreaseEdge[context];
                    if (flags.length <= pos) return false;
                    if (flags[pos] == 0) {
                        ++numUsed;
                        for (let j = 0; j < numComponents; ++j) multiPred[j] = multiPred[j] + predVals[i * numComponents + j];
                    }
                }
            }
            const dst = p * numComponents;
            if (numUsed == 0) {
                t.computeOriginalValue(data, (p - 1) * numComponents, data, dst, data, dst);
            } else {
                for (let c = 0; c < numComponents; ++c) multiPred[c] = multiPred[c] / numUsed;
                t.computeOriginalValue(multiPred, 0, data, dst, data, dst);
            }
        }
        return true;
    }
}

/// The position of entry `dataId` as int64s (GetPositionForEntryId).
function positionForEntry(pos: PointAttribute, entryToPointIdMap: Int32Array, dataId: i32, out: StaticArray<i64>): void {
    const avi = pos.mappedIndex(entryToPointIdMap[dataId]);
    out[0] = pos.componentI64(avi, 0);
    out[1] = pos.componentI64(avi, 1);
    out[2] = pos.componentI64(avi, 2);
}

function absI64(v: i64): i64 { return v < 0 ? -v : v; }

/// IntSqrt (core/math_utils.h).
function intSqrt(number: u64): u64 {
    if (number == 0) return 0;
    let actNumber = number;
    let squareRoot: u64 = 1;
    while (actNumber >= 2) {
        squareRoot *= 2;
        actNumber /= 4;
    }
    do {
        squareRoot = (squareRoot + number / squareRoot) / 2;
    } while (squareRoot * squareRoot > number);
    return squareRoot;
}

const I64_MAX: i64 = 9223372036854775807;

/// MeshPredictionSchemeTexCoordsPortableDecoder (with its predictor).
export class MeshPredictionSchemeTexCoordsPortableDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;
    posAttribute: PointAttribute? = null;
    orientations: Array<bool> = [];
    predicted: Int32Array = new Int32Array(2);
    tip: StaticArray<i64> = new StaticArray<i64>(3);
    nextPos: StaticArray<i64> = new StaticArray<i64>(3);
    prevPos: StaticArray<i64> = new StaticArray<i64>(3);

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform, meshData: MeshPredictionSchemeData) {
        super(attribute, transform);
        this.meshData = meshData;
    }

    getPredictionMethod(): i32 { return MESH_PREDICTION_TEX_COORDS_PORTABLE; }
    override getNumParentAttributes(): i32 { return 1; }
    override getParentAttributeType(i: i32): i32 { return POSITION; }

    override setParentAttribute(att: PointAttribute): bool {
        if (att.attributeType != POSITION || att.numComponents != 3) return false;
        this.posAttribute = att;
        return true;
    }

    override decodePredictionData(buffer: DecoderBuffer): bool {
        const numOrientations = buffer.i32();
        if (buffer.failed || numOrientations < 0) return false;
        // One orientation at most per corner (Draco would try to allocate any count).
        if (numOrientations > this.meshData.cornerTable.numCorners()) return false;
        const orientations = new Array<bool>(numOrientations);
        let last = true;
        const decoder = new RAnsBitDecoder();
        if (!decoder.startDecoding(buffer)) return false;
        for (let i = 0; i < numOrientations; ++i) {
            if (!decoder.decodeNextBit()) last = !last;
            orientations[i] = last;
        }
        decoder.endDecoding();
        this.orientations = orientations;
        return super.decodePredictionData(buffer);
    }

    computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool {
        if (numComponents != 2 || this.posAttribute == null) return false;
        const t = this.transform;
        t.init(numComponents);
        const dataToCorner = this.meshData.encodingData.encodedAttributeValueIndexToCornerMap;
        const n = dataToCorner.length;
        for (let p = 0; p < n; ++p) {
            if (!this.computePredictedValue(dataToCorner[p], data, p, entryToPointIdMap)) return false;
            const dst = p * numComponents;
            t.computeOriginalValue(this.predicted, 0, data, dst, data, dst);
        }
        return true;
    }

    private computePredictedValue(cornerId: i32, data: Int32Array, dataId: i32, entryToPointIdMap: Int32Array): bool {
        const table = this.meshData.cornerTable;
        const vertexToDataMap = this.meshData.encodingData.vertexToEncodedAttributeValueIndexMap;
        const nextVert = table.vertex(table.next(cornerId));
        const prevVert = table.vertex(table.previous(cornerId));
        const nextDataId = vertexToDataMap[nextVert];
        const prevDataId = vertexToDataMap[prevVert];
        const predicted = this.predicted;
        if (prevDataId < dataId && nextDataId < dataId) {
            const nU = <i64>data[nextDataId * 2], nV = <i64>data[nextDataId * 2 + 1];
            const pU = <i64>data[prevDataId * 2], pV = <i64>data[prevDataId * 2 + 1];
            if (pU == nU && pV == nV) {
                predicted[0] = <i32>pU;
                predicted[1] = <i32>pV;
                return true;
            }
            const pos = this.posAttribute!;
            const tip = this.tip, next = this.nextPos, prev = this.prevPos;
            positionForEntry(pos, entryToPointIdMap, dataId, tip);
            positionForEntry(pos, entryToPointIdMap, nextDataId, next);
            positionForEntry(pos, entryToPointIdMap, prevDataId, prev);
            const pn0 = prev[0] - next[0], pn1 = prev[1] - next[1], pn2 = prev[2] - next[2];
            const pnNorm2Squared = <u64>(pn0 * pn0 + pn1 * pn1 + pn2 * pn2);
            if (pnNorm2Squared != 0) {
                const cn0 = tip[0] - next[0], cn1 = tip[1] - next[1], cn2 = tip[2] - next[2];
                const cnDotPn: i64 = pn0 * cn0 + pn1 * cn1 + pn2 * cn2;
                const pnU = pU - nU, pnV = pV - nV;
                const nUvAbsMax = max<i64>(absI64(nU), absI64(nV));
                if (<u64>nUvAbsMax > <u64>I64_MAX / pnNorm2Squared) return false;
                const pnUvAbsMax = max<i64>(absI64(pnU), absI64(pnV));
                if (pnUvAbsMax != 0 && absI64(cnDotPn) > I64_MAX / pnUvAbsMax) return false;
                const norm = <i64>pnNorm2Squared;
                const xU = nU * norm + cnDotPn * pnU;
                const xV = nV * norm + cnDotPn * pnV;
                const pnAbsMax = max<i64>(max<i64>(absI64(pn0), absI64(pn1)), absI64(pn2));
                if (pnAbsMax != 0 && absI64(cnDotPn) > I64_MAX / pnAbsMax) return false;
                const x0 = next[0] + (cnDotPn * pn0) / norm;
                const x1 = next[1] + (cnDotPn * pn1) / norm;
                const x2 = next[2] + (cnDotPn * pn2) / norm;
                const d0 = tip[0] - x0, d1 = tip[1] - x1, d2 = tip[2] - x2;
                const cxNorm2Squared = <u64>(d0 * d0 + d1 * d1 + d2 * d2);
                const normSquared = <i64>intSqrt(cxNorm2Squared * pnNorm2Squared);
                const cxU = pnV * normSquared;
                const cxV = -pnU * normSquared;
                if (this.orientations.length == 0) return false;
                const orientation = this.orientations.pop();
                let predU: i64, predV: i64;
                if (orientation) {
                    predU = (xU + cxU) / norm;
                    predV = (xV + cxV) / norm;
                } else {
                    predU = (xU - cxU) / norm;
                    predV = (xV - cxV) / norm;
                }
                predicted[0] = <i32>predU;
                predicted[1] = <i32>predV;
                return true;
            }
        }
        let dataOffset = 0;
        if (prevDataId < dataId) {
            dataOffset = prevDataId * 2;
        } else if (nextDataId < dataId) {
            dataOffset = nextDataId * 2;
        } else {
            if (dataId > 0) {
                dataOffset = (dataId - 1) * 2;
            } else {
                predicted[0] = 0;
                predicted[1] = 0;
                return true;
            }
        }
        predicted[0] = data[dataOffset];
        predicted[1] = data[dataOffset + 1];
        return true;
    }
}

/// MeshPredictionSchemeGeometricNormalDecoder (with the area predictor).
export class MeshPredictionSchemeGeometricNormalDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;
    posAttribute: PointAttribute? = null;
    toolBox: OctahedronToolBox = new OctahedronToolBox();
    flipNormalBitDecoder: RAnsBitDecoder = new RAnsBitDecoder();
    normalPredictionMode: i32 = TRIANGLE_AREA;
    corners: Array<i32> = [];
    cent: StaticArray<i64> = new StaticArray<i64>(3);
    nextPos: StaticArray<i64> = new StaticArray<i64>(3);
    prevPos: StaticArray<i64> = new StaticArray<i64>(3);

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform, meshData: MeshPredictionSchemeData) {
        super(attribute, transform);
        this.meshData = meshData;
    }

    getPredictionMethod(): i32 { return MESH_PREDICTION_GEOMETRIC_NORMAL; }
    override getNumParentAttributes(): i32 { return 1; }
    override getParentAttributeType(i: i32): i32 { return POSITION; }

    override setParentAttribute(att: PointAttribute): bool {
        if (att.attributeType != POSITION || att.numComponents != 3) return false;
        this.posAttribute = att;
        return true;
    }

    override decodePredictionData(buffer: DecoderBuffer): bool {
        if (!this.transform.decodeTransformData(buffer)) return false;
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) {
            const mode = <i32>buffer.u8();
            if (buffer.failed || mode > TRIANGLE_AREA) return false;
            this.normalPredictionMode = mode;
        }
        return this.flipNormalBitDecoder.startDecoding(buffer);
    }

    computeOriginalValues(data: Int32Array, size: i32, numComponents: i32, entryToPointIdMap: Int32Array): bool {
        if (!this.toolBox.setQuantizationBits(this.transform.quantizationBits())) return false;
        if (this.posAttribute == null || numComponents != 2) return false;
        const dataToCorner = this.meshData.encodingData.encodedAttributeValueIndexToCornerMap;
        const n = dataToCorner.length;
        const normal = new Int32Array(3);
        const oct = new Int32Array(2);
        for (let dataId = 0; dataId < n; ++dataId) {
            this.computePredictedValue(dataToCorner[dataId], normal, entryToPointIdMap);
            this.toolBox.canonicalizeIntegerVector(normal);
            if (this.flipNormalBitDecoder.decodeNextBit()) {
                normal[0] = -normal[0];
                normal[1] = -normal[1];
                normal[2] = -normal[2];
            }
            this.toolBox.integerVectorToQuantizedOctahedralCoords(normal[0], normal[1], normal[2], oct);
            const off = dataId * 2;
            this.transform.computeOriginalValue(oct, 0, data, off, data, off);
        }
        this.flipNormalBitDecoder.endDecoding();
        return true;
    }

    private positionForCorner(ci: i32, entryToPointIdMap: Int32Array, out: StaticArray<i64>): void {
        const table = this.meshData.cornerTable;
        const dataId = this.meshData.encodingData.vertexToEncodedAttributeValueIndexMap[table.vertex(ci)];
        positionForEntry(this.posAttribute!, entryToPointIdMap, dataId, out);
    }

    /// MeshPredictionSchemeGeometricNormalPredictorArea::ComputePredictedValue.
    private computePredictedValue(cornerId: i32, prediction: Int32Array, entryToPointIdMap: Int32Array): void {
        const table = this.meshData.cornerTable;
        const cent = this.cent, posNext = this.nextPos, posPrev = this.prevPos;
        this.positionForCorner(cornerId, entryToPointIdMap, cent);
        let n0: i64 = 0, n1: i64 = 0, n2: i64 = 0;
        const corners = this.corners;
        vertexCorners(table, cornerId, corners);
        for (let k = 0; k < corners.length; k++) {
            let cNext: i32, cPrev: i32;
            if (this.normalPredictionMode == ONE_TRIANGLE) {
                cNext = table.next(cornerId);
                cPrev = table.previous(cornerId);
            } else {
                cNext = table.next(corners[k]);
                cPrev = table.previous(corners[k]);
            }
            this.positionForCorner(cNext, entryToPointIdMap, posNext);
            this.positionForCorner(cPrev, entryToPointIdMap, posPrev);
            const dn0 = posNext[0] - cent[0], dn1 = posNext[1] - cent[1], dn2 = posNext[2] - cent[2];
            const dp0 = posPrev[0] - cent[0], dp1 = posPrev[1] - cent[1], dp2 = posPrev[2] - cent[2];
            n0 += dn1 * dp2 - dn2 * dp1;
            n1 += dn2 * dp0 - dn0 * dp2;
            n2 += dn0 * dp1 - dn1 * dp0;
        }
        const upperBound: i64 = 1 << 29;
        if (this.normalPredictionMode == ONE_TRIANGLE) {
            const absSum = <i32>absSum3(n0, n1, n2);
            if (<i64>absSum > upperBound) {
                const quotient = <i64>(absSum / <i32>upperBound);
                n0 /= quotient;
                n1 /= quotient;
                n2 /= quotient;
            }
        } else {
            const absSum = absSum3(n0, n1, n2);
            if (absSum > upperBound) {
                const quotient = absSum / upperBound;
                n0 /= quotient;
                n1 /= quotient;
                n2 /= quotient;
            }
        }
        prediction[0] = <i32>n0;
        prediction[1] = <i32>n1;
        prediction[2] = <i32>n2;
    }
}

/// VectorD::AbsSum (saturating at the int64 maximum).
function absSum3(a: i64, b: i64, c: i64): i64 {
    let result: i64 = 0;
    const v = new StaticArray<i64>(3);
    v[0] = absI64(a);
    v[1] = absI64(b);
    v[2] = absI64(c);
    for (let i = 0; i < 3; i++) {
        if (result > I64_MAX - v[i]) return I64_MAX;
        result += v[i];
    }
    return result;
}
