// Draco's kd-tree point cloud attributes decoder (compression/attributes/
// kd_tree_attributes_decoder.cc, compression/point_cloud/algorithms/
// dynamic_integer_points_kd_tree_decoder.h), bitstream 2.3, ported from
// Google's Draco decoder (Apache License 2.0,
// https://github.com/google/draco) to AnimaScript. The pre-2.3 kd-tree
// coders (FloatPointsTreeDecoder, IntegerPointsKdTreeDecoder) are not
// ported: such files fail to decode.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION, mostSignificantBit } from "./decoder_buffer";
import { BitDecoder, DirectBitDecoder, RAnsBitDecoder, FoldedBit32Decoder } from "./bit_decoders";
import {
    PointAttribute, dataTypeLength, DT_UINT32, DT_UINT16, DT_UINT8, DT_INT32, DT_INT16, DT_INT8, DT_FLOAT32,
} from "./point_cloud";
import { AttributesDecoder, AttributeQuantizationTransform } from "./attributes_decoder";

class AttributeTuple {
    attribute: PointAttribute;
    offset: i32;
    dataType: i32;
    dataSize: i32;
    numComponents: i32;

    constructor(attribute: PointAttribute, offset: i32, dataType: i32, dataSize: i32, numComponents: i32) {
        this.attribute = attribute;
        this.offset = offset;
        this.dataType = dataType;
        this.dataSize = dataSize;
        this.numComponents = numComponents;
    }
}

/// PointAttributeVectorOutputIterator<uint32_t>: writes each decoded point
/// (all attributes' components side by side) into the attributes.
class PointAttributeVectorOutput {
    attributes: Array<AttributeTuple>;
    pointId: i32 = 0;

    constructor(attributes: Array<AttributeTuple>) {
        this.attributes = attributes;
    }

    write(val: Uint32Array): void {
        for (let a = 0; a < this.attributes.length; a++) {
            const att = this.attributes[a];
            const attribute = att.attribute;
            const avi = attribute.mappedIndex(this.pointId);
            if (avi >= attribute.size) return;
            const at = avi * attribute.byteStride;
            const b = attribute.bytes;
            for (let c = 0; c < att.numComponents; c++) {
                const v = val[att.offset + c];
                const o = at + c * att.dataSize;
                // The low bytes of each uint32, as Draco's memcpy.
                for (let k = 0; k < att.dataSize; k++) b[o + k] = <u8>(v >> <u32>(8 * k));
            }
        }
        this.pointId++;
    }
}

class DecodingStatus {
    numRemainingPoints: u32;
    lastAxis: u32;
    stackPos: u32;

    constructor(numRemainingPoints: u32, lastAxis: u32, stackPos: u32) {
        this.numRemainingPoints = numRemainingPoints;
        this.lastAxis = lastAxis;
        this.stackPos = stackPos;
    }
}

/// DynamicIntegerPointsKdTreeDecoder<compression_level>.
class DynamicIntegerPointsKdTreeDecoder {
    bitLength: u32 = 0;
    numPoints: u32 = 0;
    numDecodedPoints: u32 = 0;
    dimension: u32;
    selectAxis: bool;
    numbersDecoder: BitDecoder;
    remainingBitsDecoder: BitDecoder = new DirectBitDecoder();
    axisDecoder: BitDecoder = new DirectBitDecoder();
    halfDecoder: BitDecoder = new DirectBitDecoder();
    p: Uint32Array;
    axes: Uint32Array;
    baseStack: Array<Uint32Array> = [];
    levelsStack: Array<Uint32Array> = [];

    constructor(level: i32, dimension: u32) {
        this.dimension = dimension;
        // The policies: numbers through rANS from level 2, folded from 4;
        // the split axis is decoded at 6.
        if (level >= 4) this.numbersDecoder = new FoldedBit32Decoder();
        else if (level >= 2) this.numbersDecoder = new RAnsBitDecoder();
        else this.numbersDecoder = new DirectBitDecoder();
        this.selectAxis = level >= 6;
        this.p = new Uint32Array(<i32>dimension);
        this.axes = new Uint32Array(<i32>dimension);
        const n = 32 * <i32>dimension + 1;
        for (let i = 0; i < n; i++) {
            this.baseStack.push(new Uint32Array(<i32>dimension));
            this.levelsStack.push(new Uint32Array(<i32>dimension));
        }
    }

    decodePoints(buffer: DecoderBuffer, out: PointAttributeVectorOutput, maxPoints: u32): bool {
        this.bitLength = buffer.u32();
        if (buffer.failed || this.bitLength > 32) return false;
        this.numPoints = buffer.u32();
        if (buffer.failed) return false;
        if (this.numPoints == 0) return true;
        if (this.numPoints > maxPoints) return false;
        this.numDecodedPoints = 0;
        if (!this.numbersDecoder.startDecoding(buffer)) return false;
        if (!this.remainingBitsDecoder.startDecoding(buffer)) return false;
        if (!this.axisDecoder.startDecoding(buffer)) return false;
        if (!this.halfDecoder.startDecoding(buffer)) return false;
        if (!this.decodeInternal(this.numPoints, out)) return false;
        return true;
    }

    private getAxis(numRemainingPoints: u32, levels: Uint32Array, lastAxis: u32): u32 {
        if (!this.selectAxis) return (lastAxis + 1) % this.dimension;
        let bestAxis: u32 = 0;
        if (numRemainingPoints < 64) {
            for (let axis: u32 = 1; axis < this.dimension; ++axis) {
                if (levels[bestAxis] > levels[axis]) bestAxis = axis;
            }
        } else {
            bestAxis = this.axisDecoder.decodeLeastSignificantBits32(4);
        }
        return bestAxis;
    }

    private decodeInternal(numPoints: u32, out: PointAttributeVectorOutput): bool {
        const dim = this.dimension;
        this.baseStack[0].fill(0);
        this.levelsStack[0].fill(0);
        const statusStack: Array<DecodingStatus> = [new DecodingStatus(numPoints, 0, 0)];
        while (statusStack.length > 0) {
            const status = statusStack.pop();
            const numRemainingPoints = status.numRemainingPoints;
            const lastAxis = status.lastAxis;
            const stackPos = <i32>status.stackPos;
            const oldBase = this.baseStack[stackPos];
            const levels = this.levelsStack[stackPos];
            if (numRemainingPoints > numPoints) return false;
            const axis = this.getAxis(numRemainingPoints, levels, lastAxis);
            if (axis >= dim) return false;
            const level = levels[axis];
            if (this.bitLength - level == 0) {
                for (let i: u32 = 0; i < numRemainingPoints; i++) {
                    out.write(oldBase);
                    ++this.numDecodedPoints;
                }
                continue;
            }
            if (numRemainingPoints <= 2) {
                const axes = this.axes;
                const p = this.p;
                axes[0] = axis;
                for (let i: u32 = 1; i < dim; i++) axes[i] = (axes[i - 1] + 1) % dim;
                for (let i: u32 = 0; i < numRemainingPoints; ++i) {
                    for (let j: u32 = 0; j < dim; j++) {
                        const a = axes[j];
                        p[a] = 0;
                        const numRemainingBits = this.bitLength - levels[a];
                        if (numRemainingBits != 0) {
                            p[a] = this.remainingBitsDecoder.decodeLeastSignificantBits32(<i32>numRemainingBits);
                            if (this.remainingBitsDecoder.failed) return false;
                        }
                        p[a] = oldBase[a] | p[a];
                    }
                    out.write(p);
                    ++this.numDecodedPoints;
                }
                continue;
            }
            if (this.numDecodedPoints > this.numPoints) return false;
            const numRemainingBits = <i32>(this.bitLength - level);
            const modifier: u32 = <u32>1 << <u32>(numRemainingBits - 1);
            if (stackPos + 1 >= this.baseStack.length) return false;
            const newBase = this.baseStack[stackPos + 1];
            newBase.set(oldBase);
            newBase[axis] += modifier;
            const incomingBits = mostSignificantBit(numRemainingPoints);
            const number = this.numbersDecoder.decodeLeastSignificantBits32(incomingBits);
            let firstHalf: u32 = numRemainingPoints / 2;
            if (firstHalf < number) return false;
            firstHalf -= number;
            let secondHalf: u32 = numRemainingPoints - firstHalf;
            if (firstHalf != secondHalf) {
                if (!this.halfDecoder.decodeNextBit()) {
                    const t = firstHalf;
                    firstHalf = secondHalf;
                    secondHalf = t;
                }
            }
            levels[axis] += 1;
            this.levelsStack[stackPos + 1].set(levels);
            if (firstHalf != 0) statusStack.push(new DecodingStatus(firstHalf, axis, <u32>stackPos));
            if (secondHalf != 0) statusStack.push(new DecodingStatus(secondHalf, axis, <u32>(stackPos + 1)));
        }
        return true;
    }
}

/// KdTreeAttributesDecoder.
export class KdTreeAttributesDecoder extends AttributesDecoder {
    attributeQuantizationTransforms: Array<AttributeQuantizationTransform> = [];
    minSignedValues: Array<i32> = [];
    quantizedPortableAttributes: Array<PointAttribute> = [];

    protected decodePortableAttributes(buffer: DecoderBuffer): bool {
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 3)) return true;
        const compressionLevel = <i32>buffer.u8();
        if (buffer.failed) return false;
        const numPoints = this.pointCloud.numPoints;
        const numAttributes = this.getNumAttributes();
        let totalDimensionality = 0;
        const atts: Array<AttributeTuple> = [];
        for (let i = 0; i < numAttributes; ++i) {
            const att = this.pointCloud.attribute(this.getAttributeId(i));
            att.reset(numPoints);
            att.setIdentityMapping();
            let target: PointAttribute;
            const dt = att.dataType;
            if (dt == DT_UINT32 || dt == DT_UINT16 || dt == DT_UINT8) {
                target = att;
            } else if (dt == DT_INT32 || dt == DT_INT16 || dt == DT_INT8) {
                for (let c = 0; c < att.numComponents; ++c) this.minSignedValues.push(0);
                target = att;
            } else if (dt == DT_FLOAT32) {
                const port = new PointAttribute().init(att.attributeType, att.numComponents, DT_UINT32, false);
                port.setIdentityMapping();
                port.reset(numPoints);
                this.quantizedPortableAttributes.push(port);
                target = port;
            } else {
                return false;
            }
            const dataSize = max<i32>(0, dataTypeLength(target.dataType));
            atts.push(new AttributeTuple(target, totalDimensionality, target.dataType, dataSize, target.numComponents));
            totalDimensionality += target.numComponents;
        }
        if (compressionLevel < 0 || compressionLevel > 6) return false;
        const out = new PointAttributeVectorOutput(atts);
        const decoder = new DynamicIntegerPointsKdTreeDecoder(compressionLevel, <u32>totalDimensionality);
        if (!decoder.decodePoints(buffer, out, <u32>numPoints) || decoder.numDecodedPoints != <u32>numPoints) return false;
        return true;
    }

    protected override decodeDataNeededByPortableTransforms(buffer: DecoderBuffer): bool {
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 3)) return false;   // pre-2.3 kd-trees: not ported
        for (let i = 0; i < this.getNumAttributes(); ++i) {
            const att = this.pointCloud.attribute(this.getAttributeId(i));
            if (att.dataType == DT_FLOAT32) {
                const n = att.numComponents;
                const minValue = new Float32Array(n);
                for (let c = 0; c < n; c++) minValue[c] = buffer.f32();
                const maxValueDif = buffer.f32();
                const bits = <i32>buffer.u8();
                if (buffer.failed || bits > 31) return false;
                const transform = new AttributeQuantizationTransform();
                if (!transform.setParameters(bits, minValue, maxValueDif)) return false;
                this.attributeQuantizationTransforms.push(transform);
            }
        }
        for (let i = 0; i < this.minSignedValues.length; ++i) {
            this.minSignedValues[i] = buffer.varintI32();
            if (buffer.failed) return false;
        }
        return true;
    }

    protected override transformAttributesToOriginalFormat(): bool {
        if (this.quantizedPortableAttributes.length == 0 && this.minSignedValues.length == 0) return true;
        let numQuantized = 0;
        let numSignedComponents = 0;
        for (let i = 0; i < this.getNumAttributes(); ++i) {
            const att = this.pointCloud.attribute(this.getAttributeId(i));
            const dt = att.dataType;
            if (dt == DT_INT32 || dt == DT_INT16 || dt == DT_INT8) {
                const n = att.numComponents;
                for (let v = 0; v < att.size; v++) {
                    for (let c = 0; c < n; c++) {
                        // The stored unsigned value, then offset by the minimum.
                        const size = dataTypeLength(dt);
                        const at = v * att.byteStride + c * size;
                        let u: u32 = 0;
                        for (let k = 0; k < size; k++) u |= <u32>att.bytes[at + k] << <u32>(8 * k);
                        if (u > 0x7FFFFFFF) return false;
                        att.setComponent(v, c, <f64>(<i32>u + this.minSignedValues[numSignedComponents + c]));
                    }
                }
                numSignedComponents += n;
            } else if (dt == DT_FLOAT32) {
                const src = this.quantizedPortableAttributes[numQuantized];
                const transform = this.attributeQuantizationTransforms[numQuantized];
                numQuantized++;
                const maxQuantizedValue = <i32>((<u32>1 << <u32>transform.quantizationBits) - 1);
                if (maxQuantizedValue <= 0) return false;
                const delta: f32 = transform.range / <f32>maxQuantizedValue;
                const n = att.numComponents;
                const count = src.size * n;
                const s = src.ints;
                const out = att.floats;
                for (let k = 0; k < count; k++) out[k] = <f32>s[k] * delta + transform.minValues[k % n];
            }
        }
        return true;
    }
}
