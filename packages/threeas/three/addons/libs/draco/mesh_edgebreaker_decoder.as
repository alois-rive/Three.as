// Draco's Edgebreaker mesh decoder (compression/mesh/mesh_edgebreaker_
// decoder.cc, mesh_edgebreaker_decoder_impl.cc, the standard, valence and
// predictive traversal decoders), ported from Google's Draco decoder
// (Apache License 2.0, https://github.com/google/draco) to AnimaScript.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION } from "./decoder_buffer";
import { decodeSymbols } from "./ans";
import { RAnsBitDecoder } from "./bit_decoders";
import { MeshDecoder } from "./point_cloud_decoder";
import {
    CornerTable, MeshAttributeCornerTable, MeshAttributeIndicesEncodingData, INVALID_INDEX, vertexCorners,
} from "./corner_table";
import {
    SequentialAttributeDecodersController, MeshTraversalSequencer, MeshAttributeIndicesEncodingObserver,
    DepthFirstTraverser, MaxPredictionDegreeTraverser, Traverser, PointsSequencer,
} from "./attributes_decoder";

// EdgebreakerTopologyBitPattern.
const TOPOLOGY_C: u32 = 0x0;
const TOPOLOGY_S: u32 = 0x1;
const TOPOLOGY_L: u32 = 0x3;
const TOPOLOGY_R: u32 = 0x5;
const TOPOLOGY_E: u32 = 0x7;
const TOPOLOGY_INVALID: u32 = 9;

const EDGEBREAKER_SYMBOL_TO_TOPOLOGY_ID: StaticArray<u32> = [TOPOLOGY_C, TOPOLOGY_S, TOPOLOGY_L, TOPOLOGY_R, TOPOLOGY_E];

// MeshEdgebreakerConnectivityEncodingMethod.
export const MESH_EDGEBREAKER_STANDARD_ENCODING: i32 = 0;
export const MESH_EDGEBREAKER_PREDICTIVE_ENCODING: i32 = 1;
export const MESH_EDGEBREAKER_VALENCE_ENCODING: i32 = 2;

// MeshTraversalMethod.
const MESH_TRAVERSAL_DEPTH_FIRST: i32 = 0;
const MESH_TRAVERSAL_PREDICTION_DEGREE: i32 = 1;
const NUM_TRAVERSAL_METHODS: i32 = 2;

// MeshAttributeElementType.
const MESH_VERTEX_ATTRIBUTE: i32 = 0;

const RIGHT_FACE_EDGE: u32 = 1;

class TopologySplitEventData {
    splitSymbolId: u32 = 0;
    sourceSymbolId: u32 = 0;
    sourceEdge: u32 = 0;
}

class AttributeData {
    decoderId: i32 = -1;
    connectivityData: MeshAttributeCornerTable = new MeshAttributeCornerTable();
    isConnectivityUsed: bool = true;
    encodingData: MeshAttributeIndicesEncodingData = new MeshAttributeIndicesEncodingData();
    attributeSeamCorners: Array<i32> = [];
}

// ------------------------------------------------------------ traversal decoders

/// MeshEdgebreakerTraversalDecoder: the standard symbols, start faces and
/// attribute seams.
export class MeshEdgebreakerTraversalDecoder {
    buffer: DecoderBuffer = new DecoderBuffer();
    symbolBuffer: DecoderBuffer = new DecoderBuffer();
    startFaceDecoder: RAnsBitDecoder = new RAnsBitDecoder();
    startFaceBuffer: DecoderBuffer = new DecoderBuffer();
    attributeConnectivityDecoders: Array<RAnsBitDecoder> = [];
    numAttributeData: i32 = 0;
    version: i32 = 0;

    init(impl: MeshEdgebreakerDecoderImpl): void {
        const b = impl.decoder.buffer;
        this.version = impl.decoder.bitstreamVersion();
        this.buffer.init(b.data, b.head, b.remainingSize(), b.bitstreamVersion);
    }

    setNumEncodedVertices(n: i32): void {}
    setNumAttributeData(n: i32): void { this.numAttributeData = n; }

    start(out: DecoderBuffer): bool {
        if (!this.decodeTraversalSymbols()) return false;
        if (!this.decodeStartFaces()) return false;
        if (!this.decodeAttributeSeams()) return false;
        out.copyFrom(this.buffer);
        return true;
    }

    decodeStartFaceConfiguration(): bool {
        if (this.buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) {
            return this.startFaceBuffer.decodeLeastSignificantBits32(1) != 0;
        }
        return this.startFaceDecoder.decodeNextBit();
    }

    decodeSymbol(): u32 {
        const symbol = this.symbolBuffer.decodeLeastSignificantBits32(1);
        if (symbol == TOPOLOGY_C) return symbol;
        const suffix = this.symbolBuffer.decodeLeastSignificantBits32(2);
        return symbol | (suffix << 1);
    }

    newActiveCornerReached(corner: i32): void {}
    mergeVertices(dest: i32, source: i32): void {}

    decodeAttributeSeam(attribute: i32): bool {
        return this.attributeConnectivityDecoders[attribute].decodeNextBit();
    }

    done(): void {
        if (this.symbolBuffer.bitMode) this.symbolBuffer.endBitDecoding();
        if (this.buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) this.startFaceBuffer.endBitDecoding();
        else this.startFaceDecoder.endDecoding();
    }

    protected decodeTraversalSymbols(): bool {
        this.symbolBuffer.copyFrom(this.buffer);
        const traversalSize = this.symbolBuffer.startBitDecoding(true);
        if (this.symbolBuffer.failed) return false;
        this.buffer.copyFrom(this.symbolBuffer);
        if (traversalSize > <u64>this.buffer.remainingSize()) return false;
        this.buffer.advance(<i32>traversalSize);
        return true;
    }

    protected decodeStartFaces(): bool {
        if (this.buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) {
            this.startFaceBuffer.copyFrom(this.buffer);
            const traversalSize = this.startFaceBuffer.startBitDecoding(true);
            if (this.startFaceBuffer.failed) return false;
            this.buffer.copyFrom(this.startFaceBuffer);
            if (traversalSize > <u64>this.buffer.remainingSize()) return false;
            this.buffer.advance(<i32>traversalSize);
            return true;
        }
        return this.startFaceDecoder.startDecoding(this.buffer);
    }

    protected decodeAttributeSeams(): bool {
        this.attributeConnectivityDecoders = [];
        for (let i = 0; i < this.numAttributeData; ++i) {
            const d = new RAnsBitDecoder();
            if (!d.startDecoding(this.buffer)) return false;
            this.attributeConnectivityDecoders.push(d);
        }
        return true;
    }
}

/// MeshEdgebreakerTraversalValenceDecoder: symbols predicted from vertex
/// valences, one context per valence 2..7.
export class MeshEdgebreakerTraversalValenceDecoder extends MeshEdgebreakerTraversalDecoder {
    cornerTable: CornerTable = new CornerTable();
    numVertices: i32 = 0;
    vertexValences: Int32Array = new Int32Array(0);
    lastSymbol: i32 = -1;
    activeContext: i32 = -1;
    minValence: i32 = 2;
    maxValence: i32 = 7;
    contextSymbols: Array<Int32Array> = [];
    contextCounters: Int32Array = new Int32Array(0);

    override init(impl: MeshEdgebreakerDecoderImpl): void {
        super.init(impl);
        this.cornerTable = impl.cornerTable;
    }

    override setNumEncodedVertices(n: i32): void { this.numVertices = n; }

    override start(out: DecoderBuffer): bool {
        if (this.version < DRACO_BITSTREAM_VERSION(2, 2)) {
            if (!this.decodeTraversalSymbols()) return false;
        }
        if (!this.decodeStartFaces()) return false;
        if (!this.decodeAttributeSeams()) return false;
        out.copyFrom(this.buffer);
        if (this.version < DRACO_BITSTREAM_VERSION(2, 2)) {
            let numSplitSymbols: u32;
            if (this.version < DRACO_BITSTREAM_VERSION(2, 0)) numSplitSymbols = out.u32();
            else numSplitSymbols = out.varintU32();
            if (out.failed || <i64>numSplitSymbols >= <i64>this.numVertices) return false;
            const mode = out.i8();
            if (out.failed || mode != 0) return false;   // EDGEBREAKER_VALENCE_MODE_2_7
        }
        this.minValence = 2;
        this.maxValence = 7;
        if (this.numVertices < 0) return false;
        this.vertexValences = new Int32Array(this.numVertices);
        const numUnique = this.maxValence - this.minValence + 1;
        this.contextSymbols = [];
        this.contextCounters = new Int32Array(numUnique);
        for (let i = 0; i < numUnique; ++i) {
            const numSymbols = out.varintU32();
            if (out.failed) return false;
            if (<i64>numSymbols > <i64>this.cornerTable.numFaces()) return false;
            const symbols = new Int32Array(<i32>numSymbols);
            if (numSymbols > 0) {
                if (!decodeSymbols(numSymbols, 1, out, symbols)) return false;
                this.contextCounters[i] = <i32>numSymbols;
            }
            this.contextSymbols.push(symbols);
        }
        return true;
    }

    override decodeSymbol(): u32 {
        if (this.activeContext != -1) {
            const counter = --this.contextCounters[this.activeContext];
            if (counter < 0) return TOPOLOGY_INVALID;
            const symbolId = <u32>this.contextSymbols[this.activeContext][counter];
            if (symbolId > 4) return TOPOLOGY_INVALID;
            this.lastSymbol = <i32>EDGEBREAKER_SYMBOL_TO_TOPOLOGY_ID[symbolId];
        } else {
            if (this.version < DRACO_BITSTREAM_VERSION(2, 2)) this.lastSymbol = <i32>super.decodeSymbol();
            else this.lastSymbol = <i32>TOPOLOGY_E;
        }
        return <u32>this.lastSymbol;
    }

    override newActiveCornerReached(corner: i32): void {
        const ct = this.cornerTable;
        const next = ct.next(corner);
        const prev = ct.previous(corner);
        const valences = this.vertexValences;
        const s = <u32>this.lastSymbol;
        if (s == TOPOLOGY_C || s == TOPOLOGY_S) {
            valences[ct.vertex(next)] += 1;
            valences[ct.vertex(prev)] += 1;
        } else if (s == TOPOLOGY_R) {
            valences[ct.vertex(corner)] += 1;
            valences[ct.vertex(next)] += 1;
            valences[ct.vertex(prev)] += 2;
        } else if (s == TOPOLOGY_L) {
            valences[ct.vertex(corner)] += 1;
            valences[ct.vertex(next)] += 2;
            valences[ct.vertex(prev)] += 1;
        } else if (s == TOPOLOGY_E) {
            valences[ct.vertex(corner)] += 2;
            valences[ct.vertex(next)] += 2;
            valences[ct.vertex(prev)] += 2;
        }
        const activeValence = valences[ct.vertex(next)];
        const clamped = activeValence < this.minValence ? this.minValence
            : activeValence > this.maxValence ? this.maxValence : activeValence;
        this.activeContext = clamped - this.minValence;
    }

    override mergeVertices(dest: i32, source: i32): void {
        this.vertexValences[dest] += this.vertexValences[source];
    }
}

/// MeshEdgebreakerTraversalPredictiveDecoder (deprecated; kept for
/// backwards compatibility, as Draco).
export class MeshEdgebreakerTraversalPredictiveDecoder extends MeshEdgebreakerTraversalDecoder {
    cornerTable: CornerTable = new CornerTable();
    numVertices: i32 = 0;
    vertexValences: Int32Array = new Int32Array(0);
    predictionDecoder: RAnsBitDecoder = new RAnsBitDecoder();
    lastSymbol: i32 = -1;
    predictedSymbol: i32 = -1;

    override init(impl: MeshEdgebreakerDecoderImpl): void {
        super.init(impl);
        this.cornerTable = impl.cornerTable;
    }

    override setNumEncodedVertices(n: i32): void { this.numVertices = n; }

    override start(out: DecoderBuffer): bool {
        if (!super.start(out)) return false;
        const numSplitSymbols = out.i32();
        if (out.failed || numSplitSymbols < 0 || numSplitSymbols >= this.numVertices) return false;
        this.vertexValences = new Int32Array(this.numVertices);
        return this.predictionDecoder.startDecoding(out);
    }

    override decodeSymbol(): u32 {
        if (this.predictedSymbol != -1) {
            if (this.predictionDecoder.decodeNextBit()) {
                this.lastSymbol = this.predictedSymbol;
                return <u32>this.predictedSymbol;
            }
        }
        this.lastSymbol = <i32>super.decodeSymbol();
        return <u32>this.lastSymbol;
    }

    override newActiveCornerReached(corner: i32): void {
        const ct = this.cornerTable;
        const next = ct.next(corner);
        const prev = ct.previous(corner);
        const valences = this.vertexValences;
        const s = <u32>this.lastSymbol;
        if (s == TOPOLOGY_C || s == TOPOLOGY_S) {
            valences[ct.vertex(next)] += 1;
            valences[ct.vertex(prev)] += 1;
        } else if (s == TOPOLOGY_R) {
            valences[ct.vertex(corner)] += 1;
            valences[ct.vertex(next)] += 1;
            valences[ct.vertex(prev)] += 2;
        } else if (s == TOPOLOGY_L) {
            valences[ct.vertex(corner)] += 1;
            valences[ct.vertex(next)] += 2;
            valences[ct.vertex(prev)] += 1;
        } else if (s == TOPOLOGY_E) {
            valences[ct.vertex(corner)] += 2;
            valences[ct.vertex(next)] += 2;
            valences[ct.vertex(prev)] += 2;
        }
        if (s == TOPOLOGY_C || s == TOPOLOGY_R) {
            const pivot = ct.vertex(ct.next(corner));
            this.predictedSymbol = valences[pivot] < 6 ? <i32>TOPOLOGY_R : <i32>TOPOLOGY_C;
        } else {
            this.predictedSymbol = -1;
        }
    }

    override mergeVertices(dest: i32, source: i32): void {
        this.vertexValences[dest] += this.vertexValences[source];
    }
}

// ------------------------------------------------------------ the decoder

/// MeshEdgebreakerDecoderImpl.
export class MeshEdgebreakerDecoderImpl {
    decoder: MeshEdgebreakerDecoder;
    traversalDecoder: MeshEdgebreakerTraversalDecoder;
    cornerTable: CornerTable = new CornerTable();
    topologySplitData: Array<TopologySplitEventData> = [];
    numHoleEvents: i32 = 0;
    initFaceConfigurations: Array<bool> = [];
    initCorners: Array<i32> = [];
    isVertHole: Uint8Array = new Uint8Array(0);
    numEncodedVertices: i32 = 0;
    posEncodingData: MeshAttributeIndicesEncodingData = new MeshAttributeIndicesEncodingData();
    posDataDecoderId: i32 = -1;
    attributeData: Array<AttributeData> = [];
    vertexCornersScratch: Array<i32> = [];

    constructor(decoder: MeshEdgebreakerDecoder, traversalDecoder: MeshEdgebreakerTraversalDecoder) {
        this.decoder = decoder;
        this.traversalDecoder = traversalDecoder;
    }

    getAttributeCornerTable(attId: i32): MeshAttributeCornerTable? {
        for (let i = 0; i < this.attributeData.length; ++i) {
            const decoderId = this.attributeData[i].decoderId;
            if (decoderId < 0 || decoderId >= this.decoder.numAttributesDecoders()) continue;
            const dec = this.decoder.attributesDecoder(decoderId);
            if (dec == null) continue;
            const n = dec.getNumAttributes();
            for (let j = 0; j < n; ++j) {
                if (dec.getAttributeId(j) == attId) {
                    if (this.attributeData[i].isConnectivityUsed) return this.attributeData[i].connectivityData;
                    return null;
                }
            }
        }
        return null;
    }

    getAttributeEncodingData(attId: i32): MeshAttributeIndicesEncodingData {
        for (let i = 0; i < this.attributeData.length; ++i) {
            const decoderId = this.attributeData[i].decoderId;
            if (decoderId < 0 || decoderId >= this.decoder.numAttributesDecoders()) continue;
            const dec = this.decoder.attributesDecoder(decoderId);
            if (dec == null) continue;
            const n = dec.getNumAttributes();
            for (let j = 0; j < n; ++j) {
                if (dec.getAttributeId(j) == attId) return this.attributeData[i].encodingData;
            }
        }
        return this.posEncodingData;
    }

    createAttributesDecoder(attDecoderId: i32): bool {
        const buffer = this.decoder.buffer;
        const attDataId = buffer.i8();
        const decoderType = <i32>buffer.u8();
        if (buffer.failed) return false;
        if (attDataId >= 0) {
            if (attDataId >= this.attributeData.length) return false;
            if (this.attributeData[attDataId].decoderId >= 0) return false;
            this.attributeData[attDataId].decoderId = attDecoderId;
        } else {
            if (this.posDataDecoderId >= 0) return false;
            this.posDataDecoderId = attDecoderId;
        }
        let traversalMethod = MESH_TRAVERSAL_DEPTH_FIRST;
        if (this.decoder.bitstreamVersion() >= DRACO_BITSTREAM_VERSION(1, 2)) {
            traversalMethod = <i32>buffer.u8();
            if (buffer.failed || traversalMethod >= NUM_TRAVERSAL_METHODS) return false;
        }
        const mesh = this.decoder.mesh;
        let sequencer: PointsSequencer;
        if (decoderType == MESH_VERTEX_ATTRIBUTE) {
            let encodingData: MeshAttributeIndicesEncodingData;
            if (attDataId < 0) {
                encodingData = this.posEncodingData;
            } else {
                encodingData = this.attributeData[attDataId].encodingData;
                this.attributeData[attDataId].isConnectivityUsed = false;
            }
            const s = new MeshTraversalSequencer(mesh, encodingData);
            const observer = new MeshAttributeIndicesEncodingObserver(mesh, s, encodingData);
            let traverser: Traverser;
            if (traversalMethod == MESH_TRAVERSAL_PREDICTION_DEGREE) {
                traverser = new MaxPredictionDegreeTraverser(this.cornerTable, observer);
            } else if (traversalMethod == MESH_TRAVERSAL_DEPTH_FIRST) {
                traverser = new DepthFirstTraverser(this.cornerTable, observer);
            } else {
                return false;
            }
            s.setTraverser(traverser);
            sequencer = s;
        } else {
            if (traversalMethod != MESH_TRAVERSAL_DEPTH_FIRST) return false;
            if (attDataId < 0) return false;
            const encodingData = this.attributeData[attDataId].encodingData;
            const table = this.attributeData[attDataId].connectivityData;
            const s = new MeshTraversalSequencer(mesh, encodingData);
            const observer = new MeshAttributeIndicesEncodingObserver(mesh, s, encodingData);
            s.setTraverser(new DepthFirstTraverser(table, observer));
            sequencer = s;
        }
        return this.decoder.setAttributesDecoder(attDecoderId, new SequentialAttributeDecodersController(sequencer));
    }

    decodeConnectivity(): bool {
        const decoder = this.decoder;
        const buffer = decoder.buffer;
        const version = decoder.bitstreamVersion();
        if (version < DRACO_BITSTREAM_VERSION(2, 2)) {
            if (version < DRACO_BITSTREAM_VERSION(2, 0)) buffer.u32();   // num_new_verts
            else buffer.varintU32();
        }
        let numEncodedVertices: u32;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numEncodedVertices = buffer.u32();
        else numEncodedVertices = buffer.varintU32();
        this.numEncodedVertices = <i32>numEncodedVertices;
        let numFaces: u32;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numFaces = buffer.u32();
        else numFaces = buffer.varintU32();
        if (buffer.failed) return false;
        if (numFaces > 0x7FFFFFFF / 3) return false;
        if (<u64>numEncodedVertices > <u64>numFaces * 3) return false;
        const minNumFaceEdges = <u64>(3 * numFaces / 2);
        const nv64 = <u64>numEncodedVertices;
        const maxNumVertexEdges = nv64 * (nv64 - 1) / 2;
        if (maxNumVertexEdges < minNumFaceEdges) return false;
        const numAttributeData = <i32>buffer.u8();
        let numEncodedSymbols: u32;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numEncodedSymbols = buffer.u32();
        else numEncodedSymbols = buffer.varintU32();
        if (buffer.failed) return false;
        if (numFaces < numEncodedSymbols) return false;
        const maxEncodedFaces = <u64>numEncodedSymbols + <u64>(numEncodedSymbols / 3);
        if (<u64>numFaces > maxEncodedFaces) return false;
        let numEncodedSplitSymbols: u32;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numEncodedSplitSymbols = buffer.u32();
        else numEncodedSplitSymbols = buffer.varintU32();
        if (buffer.failed) return false;
        if (numEncodedSplitSymbols > numEncodedSymbols) return false;

        this.cornerTable = new CornerTable();
        this.topologySplitData = [];
        this.numHoleEvents = 0;
        this.initFaceConfigurations = [];
        this.initCorners = [];
        this.attributeData = [];
        for (let i = 0; i < numAttributeData; i++) this.attributeData.push(new AttributeData());
        const maxVertices = this.numEncodedVertices + <i32>numEncodedSplitSymbols;
        if (!this.cornerTable.reset(<i32>numFaces, maxVertices)) return false;
        this.isVertHole = new Uint8Array(maxVertices);
        this.isVertHole.fill(1);

        let topologySplitDecodedBytes = -1;
        if (version < DRACO_BITSTREAM_VERSION(2, 2)) {
            let encodedConnectivitySize: u32;
            if (version < DRACO_BITSTREAM_VERSION(2, 0)) encodedConnectivitySize = buffer.u32();
            else encodedConnectivitySize = buffer.varintU32();
            if (buffer.failed) return false;
            if (encodedConnectivitySize == 0 || <i64>encodedConnectivitySize > <i64>buffer.remainingSize()) return false;
            const eventBuffer = new DecoderBuffer().init(buffer.data, buffer.head + <i32>encodedConnectivitySize,
                buffer.remainingSize() - <i32>encodedConnectivitySize, buffer.bitstreamVersion);
            topologySplitDecodedBytes = this.decodeHoleAndTopologySplitEvents(eventBuffer);
            if (topologySplitDecodedBytes == -1) return false;
        } else {
            if (this.decodeHoleAndTopologySplitEvents(buffer) == -1) return false;
        }

        const traversal = this.traversalDecoder;
        traversal.init(this);
        traversal.setNumEncodedVertices(maxVertices);
        traversal.setNumAttributeData(numAttributeData);
        const traversalEndBuffer = new DecoderBuffer();
        if (!traversal.start(traversalEndBuffer)) return false;

        const numConnectivityVerts = this.decodeConnectivitySymbols(<i32>numEncodedSymbols);
        if (numConnectivityVerts == -1) return false;

        buffer.init(traversalEndBuffer.data, traversalEndBuffer.head, traversalEndBuffer.remainingSize(),
            buffer.bitstreamVersion);
        if (version < DRACO_BITSTREAM_VERSION(2, 2)) buffer.advance(topologySplitDecodedBytes);

        const ct = this.cornerTable;
        if (this.attributeData.length > 0) {
            const nc = ct.numCorners();
            if (version < DRACO_BITSTREAM_VERSION(2, 1)) {
                for (let ci = 0; ci < nc; ci += 3) this.decodeAttributeConnectivitiesOnFaceLegacy(ci);
            } else {
                for (let ci = 0; ci < nc; ci += 3) this.decodeAttributeConnectivitiesOnFace(ci);
            }
        }
        traversal.done();

        for (let i = 0; i < this.attributeData.length; ++i) {
            const data = this.attributeData[i];
            data.connectivityData.initEmpty(ct);
            const seams = data.attributeSeamCorners;
            for (let k = 0; k < seams.length; k++) data.connectivityData.addSeamEdge(seams[k]);
            if (!data.connectivityData.recomputeVertices()) return false;
        }
        this.posEncodingData.init(ct.numVertices());
        for (let i = 0; i < this.attributeData.length; ++i) {
            let attConnectivityVerts = this.attributeData[i].connectivityData.numVertices();
            if (attConnectivityVerts < ct.numVertices()) attConnectivityVerts = ct.numVertices();
            this.attributeData[i].encodingData.init(attConnectivityVerts);
        }
        return this.assignPointsToCorners(numConnectivityVerts);
    }

    private isTopologySplit(encoderSymbolId: i32, out: StaticArray<i32>): bool {
        const data = this.topologySplitData;
        if (data.length == 0) return false;
        const back = data[data.length - 1];
        if (<i64>back.sourceSymbolId > <i64>encoderSymbolId) {
            out[1] = -1;
            return true;
        }
        if (<i64>back.sourceSymbolId != <i64>encoderSymbolId) return false;
        out[0] = <i32>back.sourceEdge;
        out[1] = <i32>back.splitSymbolId;
        data.pop();
        return true;
    }

    /// DecodeConnectivity(num_symbols): the number of vertices, or -1.
    private decodeConnectivitySymbols(numSymbols: i32): i32 {
        const ct = this.cornerTable;
        const traversal = this.traversalDecoder;
        const activeCornerStack: Array<i32> = [];
        const topologySplitActiveCorners = new Map<i32, i32>();
        const invalidVertices: Array<i32> = [];
        const removeInvalidVertices = this.attributeData.length == 0;
        const maxNumVertices = this.isVertHole.length;
        const split = new StaticArray<i32>(2);
        let numFaces = 0;
        for (let symbolId = 0; symbolId < numSymbols; ++symbolId) {
            const face = numFaces++;
            let checkTopologySplit = false;
            const symbol = traversal.decodeSymbol();
            if (symbol == TOPOLOGY_C) {
                if (activeCornerStack.length == 0) return -1;
                const cornerA = activeCornerStack[activeCornerStack.length - 1];
                const vertexX = ct.vertex(ct.next(cornerA));
                const cornerB = ct.next(ct.leftMostCorner(vertexX));
                if (cornerA == cornerB) return -1;
                if (ct.opposite(cornerA) != INVALID_INDEX || ct.opposite(cornerB) != INVALID_INDEX) return -1;
                const corner = 3 * face;
                this.setOppositeCorners(cornerA, corner + 1);
                this.setOppositeCorners(cornerB, corner + 2);
                const vertAPrev = ct.vertex(ct.previous(cornerA));
                const vertBNext = ct.vertex(ct.next(cornerB));
                if (vertexX == vertAPrev || vertexX == vertBNext) return -1;
                ct.mapCornerToVertex(corner, vertexX);
                ct.mapCornerToVertex(corner + 1, vertBNext);
                ct.mapCornerToVertex(corner + 2, vertAPrev);
                ct.setLeftMostCorner(vertAPrev, corner + 2);
                this.isVertHole[vertexX] = 0;
                activeCornerStack[activeCornerStack.length - 1] = corner;
            } else if (symbol == TOPOLOGY_R || symbol == TOPOLOGY_L) {
                if (activeCornerStack.length == 0) return -1;
                const cornerA = activeCornerStack[activeCornerStack.length - 1];
                if (ct.opposite(cornerA) != INVALID_INDEX) return -1;
                const corner = 3 * face;
                let oppCorner: i32, cornerL: i32, cornerR: i32;
                if (symbol == TOPOLOGY_R) {
                    oppCorner = corner + 2;
                    cornerL = corner + 1;
                    cornerR = corner;
                } else {
                    oppCorner = corner + 1;
                    cornerL = corner;
                    cornerR = corner + 2;
                }
                this.setOppositeCorners(oppCorner, cornerA);
                const newVert = ct.addNewVertex();
                if (ct.numVertices() > maxNumVertices) return -1;
                ct.mapCornerToVertex(oppCorner, newVert);
                ct.setLeftMostCorner(newVert, oppCorner);
                const vertexR = ct.vertex(ct.previous(cornerA));
                ct.mapCornerToVertex(cornerR, vertexR);
                ct.setLeftMostCorner(vertexR, cornerR);
                ct.mapCornerToVertex(cornerL, ct.vertex(ct.next(cornerA)));
                activeCornerStack[activeCornerStack.length - 1] = corner;
                checkTopologySplit = true;
            } else if (symbol == TOPOLOGY_S) {
                if (activeCornerStack.length == 0) return -1;
                const cornerB = activeCornerStack.pop();
                if (topologySplitActiveCorners.has(symbolId)) {
                    activeCornerStack.push(topologySplitActiveCorners.get(symbolId));
                }
                if (activeCornerStack.length == 0) return -1;
                const cornerA = activeCornerStack[activeCornerStack.length - 1];
                if (cornerA == cornerB) return -1;
                if (ct.opposite(cornerA) != INVALID_INDEX || ct.opposite(cornerB) != INVALID_INDEX) return -1;
                const corner = 3 * face;
                this.setOppositeCorners(cornerA, corner + 2);
                this.setOppositeCorners(cornerB, corner + 1);
                const vertexP = ct.vertex(ct.previous(cornerA));
                ct.mapCornerToVertex(corner, vertexP);
                ct.mapCornerToVertex(corner + 1, ct.vertex(ct.next(cornerA)));
                const vertBPrev = ct.vertex(ct.previous(cornerB));
                ct.mapCornerToVertex(corner + 2, vertBPrev);
                ct.setLeftMostCorner(vertBPrev, corner + 2);
                let cornerN = ct.next(cornerB);
                const vertexN = ct.vertex(cornerN);
                traversal.mergeVertices(vertexP, vertexN);
                ct.setLeftMostCorner(vertexP, ct.leftMostCorner(vertexN));
                const firstCorner = cornerN;
                while (cornerN != INVALID_INDEX) {
                    ct.mapCornerToVertex(cornerN, vertexP);
                    cornerN = ct.swingLeft(cornerN);
                    if (cornerN == firstCorner) return -1;
                }
                ct.makeVertexIsolated(vertexN);
                if (removeInvalidVertices) invalidVertices.push(vertexN);
                activeCornerStack[activeCornerStack.length - 1] = corner;
            } else if (symbol == TOPOLOGY_E) {
                const corner = 3 * face;
                const firstVert = ct.addNewVertex();
                ct.mapCornerToVertex(corner, firstVert);
                ct.mapCornerToVertex(corner + 1, ct.addNewVertex());
                ct.mapCornerToVertex(corner + 2, ct.addNewVertex());
                if (ct.numVertices() > maxNumVertices) return -1;
                ct.setLeftMostCorner(firstVert, corner);
                ct.setLeftMostCorner(firstVert + 1, corner + 1);
                ct.setLeftMostCorner(firstVert + 2, corner + 2);
                activeCornerStack.push(corner);
                checkTopologySplit = true;
            } else {
                return -1;
            }
            traversal.newActiveCornerReached(activeCornerStack[activeCornerStack.length - 1]);
            if (checkTopologySplit) {
                const encoderSymbolId = numSymbols - symbolId - 1;
                while (this.isTopologySplit(encoderSymbolId, split)) {
                    const encoderSplitSymbolId = split[1];
                    if (encoderSplitSymbolId < 0) return -1;
                    const actTopCorner = activeCornerStack[activeCornerStack.length - 1];
                    const newActiveCorner = <u32>split[0] == RIGHT_FACE_EDGE ? ct.next(actTopCorner) : ct.previous(actTopCorner);
                    const decoderSplitSymbolId = numSymbols - encoderSplitSymbolId - 1;
                    topologySplitActiveCorners.set(decoderSplitSymbolId, newActiveCorner);
                }
            }
        }
        if (ct.numVertices() > maxNumVertices) return -1;
        while (activeCornerStack.length > 0) {
            const corner = activeCornerStack.pop();
            const interiorFace = traversal.decodeStartFaceConfiguration();
            if (interiorFace) {
                if (numFaces >= ct.numFaces()) return -1;
                const cornerA = corner;
                const vertN = ct.vertex(ct.next(cornerA));
                const cornerB = ct.next(ct.leftMostCorner(vertN));
                const vertX = ct.vertex(ct.next(cornerB));
                const cornerC = ct.next(ct.leftMostCorner(vertX));
                if (corner == cornerB || corner == cornerC || cornerB == cornerC) return -1;
                if (ct.opposite(corner) != INVALID_INDEX || ct.opposite(cornerB) != INVALID_INDEX
                    || ct.opposite(cornerC) != INVALID_INDEX) return -1;
                const vertP = ct.vertex(ct.next(cornerC));
                const face = numFaces++;
                const newCorner = 3 * face;
                this.setOppositeCorners(newCorner, corner);
                this.setOppositeCorners(newCorner + 1, cornerB);
                this.setOppositeCorners(newCorner + 2, cornerC);
                ct.mapCornerToVertex(newCorner, vertX);
                ct.mapCornerToVertex(newCorner + 1, vertP);
                ct.mapCornerToVertex(newCorner + 2, vertN);
                for (let ci = 0; ci < 3; ++ci) this.isVertHole[ct.vertex(newCorner + ci)] = 0;
                this.initFaceConfigurations.push(true);
                this.initCorners.push(newCorner);
            } else {
                this.initFaceConfigurations.push(false);
                this.initCorners.push(corner);
            }
        }
        if (numFaces != ct.numFaces()) return -1;
        let numVertices = ct.numVertices();
        const corners = this.vertexCornersScratch;
        for (let k = 0; k < invalidVertices.length; k++) {
            const invalidVert = invalidVertices[k];
            let srcVert = numVertices - 1;
            while (ct.leftMostCorner(srcVert) == INVALID_INDEX) {
                srcVert = --numVertices - 1;
            }
            if (srcVert < invalidVert) continue;
            vertexCorners(ct, ct.leftMostCorner(srcVert), corners);
            for (let c = 0; c < corners.length; c++) {
                const cid = corners[c];
                if (ct.vertex(cid) != srcVert) return -1;
                ct.mapCornerToVertex(cid, invalidVert);
            }
            ct.setLeftMostCorner(invalidVert, ct.leftMostCorner(srcVert));
            ct.makeVertexIsolated(srcVert);
            this.isVertHole[invalidVert] = this.isVertHole[srcVert];
            this.isVertHole[srcVert] = 0;
            numVertices--;
        }
        return numVertices;
    }

    private setOppositeCorners(c0: i32, c1: i32): void {
        this.cornerTable.setOppositeCorner(c0, c1);
        this.cornerTable.setOppositeCorner(c1, c0);
    }

    /// DecodeHoleAndTopologySplitEvents: the bytes read, or -1.
    private decodeHoleAndTopologySplitEvents(buffer: DecoderBuffer): i32 {
        const version = this.decoder.bitstreamVersion();
        let numTopologySplits: u32;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numTopologySplits = buffer.u32();
        else numTopologySplits = buffer.varintU32();
        if (buffer.failed) return -1;
        if (numTopologySplits > 0) {
            if (<i64>numTopologySplits > <i64>this.cornerTable.numFaces()) return -1;
            if (version < DRACO_BITSTREAM_VERSION(1, 2)) {
                for (let i: u32 = 0; i < numTopologySplits; ++i) {
                    const e = new TopologySplitEventData();
                    e.splitSymbolId = buffer.u32();
                    e.sourceSymbolId = buffer.u32();
                    e.sourceEdge = buffer.u8() & 1;
                    if (buffer.failed) return -1;
                    this.topologySplitData.push(e);
                }
            } else {
                let lastSourceSymbolId: u32 = 0;
                for (let i: u32 = 0; i < numTopologySplits; ++i) {
                    const e = new TopologySplitEventData();
                    let delta = buffer.varintU32();
                    e.sourceSymbolId = delta + lastSourceSymbolId;
                    delta = buffer.varintU32();
                    if (buffer.failed) return -1;
                    if (delta > e.sourceSymbolId) return -1;
                    e.splitSymbolId = e.sourceSymbolId - delta;
                    lastSourceSymbolId = e.sourceSymbolId;
                    this.topologySplitData.push(e);
                }
                buffer.startBitDecoding(false);
                for (let i: u32 = 0; i < numTopologySplits; ++i) {
                    let edgeData: u32;
                    if (version < DRACO_BITSTREAM_VERSION(2, 2)) edgeData = buffer.decodeLeastSignificantBits32(2);
                    else edgeData = buffer.decodeLeastSignificantBits32(1);
                    this.topologySplitData[i].sourceEdge = edgeData & 1;
                }
                buffer.endBitDecoding();
            }
        }
        let numHoleEvents: u32 = 0;
        if (version < DRACO_BITSTREAM_VERSION(2, 0)) numHoleEvents = buffer.u32();
        else if (version < DRACO_BITSTREAM_VERSION(2, 1)) numHoleEvents = buffer.varintU32();
        if (buffer.failed) return -1;
        if (numHoleEvents > 0) {
            // Hole events are read and dropped, as Draco does.
            if (version < DRACO_BITSTREAM_VERSION(1, 2)) {
                for (let i: u32 = 0; i < numHoleEvents; ++i) buffer.i32();
            } else {
                for (let i: u32 = 0; i < numHoleEvents; ++i) buffer.varintU32();
            }
            if (buffer.failed) return -1;
            this.numHoleEvents = <i32>numHoleEvents;
        }
        return buffer.decodedSize();
    }

    private decodeAttributeConnectivitiesOnFaceLegacy(corner: i32): void {
        const ct = this.cornerTable;
        const corners = [corner, ct.next(corner), ct.previous(corner)];
        for (let c = 0; c < 3; ++c) {
            const oppCorner = ct.opposite(corners[c]);
            if (oppCorner == INVALID_INDEX) {
                for (let i = 0; i < this.attributeData.length; ++i) this.attributeData[i].attributeSeamCorners.push(corners[c]);
                continue;
            }
            for (let i = 0; i < this.attributeData.length; ++i) {
                if (this.traversalDecoder.decodeAttributeSeam(i)) this.attributeData[i].attributeSeamCorners.push(corners[c]);
            }
        }
    }

    private decodeAttributeConnectivitiesOnFace(corner: i32): void {
        const ct = this.cornerTable;
        const srcFace = corner / 3;
        for (let c = 0; c < 3; ++c) {
            const cc = c == 0 ? corner : c == 1 ? ct.next(corner) : ct.previous(corner);
            const oppCorner = ct.opposite(cc);
            if (oppCorner == INVALID_INDEX) {
                for (let i = 0; i < this.attributeData.length; ++i) this.attributeData[i].attributeSeamCorners.push(cc);
                continue;
            }
            if (oppCorner / 3 < srcFace) continue;
            for (let i = 0; i < this.attributeData.length; ++i) {
                if (this.traversalDecoder.decodeAttributeSeam(i)) this.attributeData[i].attributeSeamCorners.push(cc);
            }
        }
    }

    private assignPointsToCorners(numConnectivityVerts: i32): bool {
        const ct = this.cornerTable;
        const mesh = this.decoder.mesh;
        mesh.setNumFaces(ct.numFaces());
        const numFaces = mesh.numFaces;
        if (this.attributeData.length == 0) {
            for (let f = 0; f < numFaces; ++f) {
                const c = 3 * f;
                mesh.setFace(f, ct.vertex(c), ct.vertex(c + 1), ct.vertex(c + 2));
            }
            mesh.numPoints = numConnectivityVerts;
            return true;
        }
        const pointToCornerMap: Array<i32> = [];
        const cornerToPointMap = new Int32Array(ct.numCorners());
        const nv = ct.numVertices();
        const attData = this.attributeData;
        for (let v = 0; v < nv; ++v) {
            let c = ct.leftMostCorner(v);
            if (c == INVALID_INDEX) continue;
            let dedupFirstCorner = c;
            if (this.isVertHole[v] == 0) {
                for (let i = 0; i < attData.length; ++i) {
                    const cd = attData[i].connectivityData;
                    if (!cd.isCornerOnSeam(c)) continue;
                    const vertId = cd.vertex(c);
                    let actC = ct.swingRight(c);
                    let seamFound = false;
                    while (actC != c) {
                        if (actC == INVALID_INDEX) return false;
                        if (cd.vertex(actC) != vertId) {
                            dedupFirstCorner = actC;
                            seamFound = true;
                            break;
                        }
                        actC = ct.swingRight(actC);
                    }
                    if (seamFound) break;
                }
            }
            c = dedupFirstCorner;
            cornerToPointMap[c] = pointToCornerMap.length;
            pointToCornerMap.push(c);
            let prevC = c;
            c = ct.swingRight(c);
            while (c != INVALID_INDEX && c != dedupFirstCorner) {
                let attributeSeam = false;
                for (let i = 0; i < attData.length; ++i) {
                    const cd = attData[i].connectivityData;
                    if (cd.vertex(c) != cd.vertex(prevC)) {
                        attributeSeam = true;
                        break;
                    }
                }
                if (attributeSeam) {
                    cornerToPointMap[c] = pointToCornerMap.length;
                    pointToCornerMap.push(c);
                } else {
                    cornerToPointMap[c] = cornerToPointMap[prevC];
                }
                prevC = c;
                c = ct.swingRight(c);
            }
        }
        for (let f = 0; f < numFaces; ++f) {
            mesh.setFace(f, cornerToPointMap[3 * f], cornerToPointMap[3 * f + 1], cornerToPointMap[3 * f + 2]);
        }
        mesh.numPoints = pointToCornerMap.length;
        return true;
    }
}

/// MeshEdgebreakerDecoder.
export class MeshEdgebreakerDecoder extends MeshDecoder {
    impl: MeshEdgebreakerDecoderImpl? = null;

    override getCornerTable(): CornerTable? {
        const impl = this.impl;
        return impl != null ? impl.cornerTable : null;
    }

    override getAttributeCornerTable(attId: i32): MeshAttributeCornerTable? {
        const impl = this.impl;
        return impl != null ? impl.getAttributeCornerTable(attId) : null;
    }

    override getAttributeEncodingData(attId: i32): MeshAttributeIndicesEncodingData? {
        const impl = this.impl;
        return impl != null ? impl.getAttributeEncodingData(attId) : null;
    }

    protected override initializeDecoder(): bool {
        const type = <i32>this.buffer.u8();
        if (this.buffer.failed) return false;
        let traversal: MeshEdgebreakerTraversalDecoder? = null;
        if (type == MESH_EDGEBREAKER_STANDARD_ENCODING) traversal = new MeshEdgebreakerTraversalDecoder();
        else if (type == MESH_EDGEBREAKER_PREDICTIVE_ENCODING) traversal = new MeshEdgebreakerTraversalPredictiveDecoder();
        else if (type == MESH_EDGEBREAKER_VALENCE_ENCODING) traversal = new MeshEdgebreakerTraversalValenceDecoder();
        if (traversal == null) return false;
        this.impl = new MeshEdgebreakerDecoderImpl(this, traversal);
        return true;
    }

    override createAttributesDecoder(id: i32): bool {
        return this.impl!.createAttributesDecoder(id);
    }

    protected override decodeConnectivity(): bool {
        return this.impl!.decodeConnectivity();
    }
}
