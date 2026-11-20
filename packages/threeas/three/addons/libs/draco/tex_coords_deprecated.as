// Draco's MeshPredictionSchemeTexCoordsDecoder (compression/attributes/
// prediction_schemes/mesh_prediction_scheme_tex_coords_decoder.h): the
// float tex-coord predictor of bitstreams before the portable one, kept for
// backwards compatibility as Draco does. Ported from Google's Draco decoder
// (Apache License 2.0, https://github.com/google/draco) to AnimaScript.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION } from "./decoder_buffer";
import { PointAttribute, POSITION } from "./point_cloud";
import {
    PredictionSchemeDecoder, PredictionSchemeTransform, MeshPredictionSchemeData, MESH_PREDICTION_TEX_COORDS_DEPRECATED,
} from "./prediction_schemes";
import { RAnsBitDecoder } from "./bit_decoders";

const INT_MAX: f64 = 2147483647;
const INT_MIN: f64 = -2147483648;

export class MeshPredictionSchemeTexCoordsDecoder extends PredictionSchemeDecoder {
    meshData: MeshPredictionSchemeData;
    version: i32;
    posAttribute: PointAttribute? = null;
    orientations: Array<bool> = [];
    predicted: Int32Array = new Int32Array(2);
    tip: StaticArray<f32> = new StaticArray<f32>(3);
    nextPos: StaticArray<f32> = new StaticArray<f32>(3);
    prevPos: StaticArray<f32> = new StaticArray<f32>(3);

    constructor(attribute: PointAttribute, transform: PredictionSchemeTransform, meshData: MeshPredictionSchemeData,
                version: i32) {
        super(attribute, transform);
        this.meshData = meshData;
        this.version = version;
    }

    getPredictionMethod(): i32 { return MESH_PREDICTION_TEX_COORDS_DEPRECATED; }
    override getNumParentAttributes(): i32 { return 1; }
    override getParentAttributeType(i: i32): i32 { return POSITION; }

    override setParentAttribute(att: PointAttribute): bool {
        if (att.attributeType != POSITION || att.numComponents != 3) return false;
        this.posAttribute = att;
        return true;
    }

    override decodePredictionData(buffer: DecoderBuffer): bool {
        let numOrientations: u32;
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) numOrientations = buffer.u32();
        else numOrientations = buffer.varintU32();
        if (buffer.failed || numOrientations == 0) return false;
        if (<i64>numOrientations > <i64>this.meshData.cornerTable.numCorners()) return false;
        const orientations = new Array<bool>(<i32>numOrientations);
        let last = true;
        const decoder = new RAnsBitDecoder();
        if (!decoder.startDecoding(buffer)) return false;
        for (let i = 0; i < <i32>numOrientations; ++i) {
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
            const dst = p * 2;
            t.computeOriginalValue(this.predicted, 0, data, dst, data, dst);
        }
        return true;
    }

    private position(entryToPointIdMap: Int32Array, dataId: i32, out: StaticArray<f32>): void {
        const pos = this.posAttribute!;
        const avi = pos.mappedIndex(entryToPointIdMap[dataId]);
        out[0] = <f32>pos.component(avi, 0);
        out[1] = <f32>pos.component(avi, 1);
        out[2] = <f32>pos.component(avi, 2);
    }

    private computePredictedValue(cornerId: i32, data: Int32Array, dataId: i32, entryToPointIdMap: Int32Array): bool {
        const table = this.meshData.cornerTable;
        const vertexToDataMap = this.meshData.encodingData.vertexToEncodedAttributeValueIndexMap;
        const nextDataId = vertexToDataMap[table.vertex(table.next(cornerId))];
        const prevDataId = vertexToDataMap[table.vertex(table.previous(cornerId))];
        const predicted = this.predicted;
        if (prevDataId < dataId && nextDataId < dataId) {
            const nU = <f32>data[nextDataId * 2], nV = <f32>data[nextDataId * 2 + 1];
            const pU = <f32>data[prevDataId * 2], pV = <f32>data[prevDataId * 2 + 1];
            if (pU == nU && pV == nV) {
                predicted[0] = <i32>pU;
                predicted[1] = <i32>pV;
                return true;
            }
            const tip = this.tip, next = this.nextPos, prev = this.prevPos;
            this.position(entryToPointIdMap, dataId, tip);
            this.position(entryToPointIdMap, nextDataId, next);
            this.position(entryToPointIdMap, prevDataId, prev);
            const pn0: f32 = prev[0] - next[0], pn1: f32 = prev[1] - next[1], pn2: f32 = prev[2] - next[2];
            const cn0: f32 = tip[0] - next[0], cn1: f32 = tip[1] - next[1], cn2: f32 = tip[2] - next[2];
            let pnNorm2Squared: f32 = 0;
            pnNorm2Squared += pn0 * pn0;
            pnNorm2Squared += pn1 * pn1;
            pnNorm2Squared += pn2 * pn2;
            let s: f32, t: f32;
            if (this.version < DRACO_BITSTREAM_VERSION(1, 2) || pnNorm2Squared > 0) {
                let dot: f32 = 0;
                dot += pn0 * cn0;
                dot += pn1 * cn1;
                dot += pn2 * cn2;
                s = dot / pnNorm2Squared;
                const d0: f32 = cn0 - pn0 * s, d1: f32 = cn1 - pn1 * s, d2: f32 = cn2 - pn2 * s;
                let sq: f32 = 0;
                sq += d0 * d0;
                sq += d1 * d1;
                sq += d2 * d2;
                t = Mathf.sqrt(sq / pnNorm2Squared);
            } else {
                s = 0;
                t = 0;
            }
            const pnU: f32 = pU - nU, pnV: f32 = pV - nV;
            const pnus: f32 = pnU * s + nU;
            const pnut: f32 = pnU * t;
            const pnvs: f32 = pnV * s + nV;
            const pnvt: f32 = pnV * t;
            if (this.orientations.length == 0) return false;
            const orientation = this.orientations.pop();
            let u: f32, v: f32;
            if (orientation) {
                u = pnus - pnvt;
                v = pnvs + pnut;
            } else {
                u = pnus + pnvt;
                v = pnvs - pnut;
            }
            predicted[0] = roundToInt(u);
            predicted[1] = roundToInt(v);
            return true;
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

function roundToInt(x: f32): i32 {
    const u = Math.floor(<f64>x + 0.5);
    if (isNaN(u) || u > INT_MAX || u < INT_MIN) return <i32>INT_MIN;
    return <i32>u;
}
