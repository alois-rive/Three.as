// three.js InstancedBufferAttribute: one item per instance.

import { BufferAttribute } from "./BufferAttribute";
import { Dynamic } from "rive/dynamic";

export class InstancedBufferAttribute extends BufferAttribute {
    readonly isInstancedBufferAttribute: bool = true;
    meshPerAttribute: i32;

    constructor(array: Float32Array, itemSize: i32, normalized: bool = false, meshPerAttribute: i32 = 1) {
        super(array, itemSize, normalized);
        this.meshPerAttribute = meshPerAttribute;
    }

    override clone(): BufferAttribute {
        return new InstancedBufferAttribute(this.array.slice(), this.itemSize, this.normalized, this.meshPerAttribute);
    }

    override toJSON(): Dynamic {
        const data = super.toJSON();
        data.set("meshPerAttribute", Dynamic.fromNumber(<f64>this.meshPerAttribute));
        data.set("isInstancedBufferAttribute", Dynamic.fromBool(true));
        return data;
    }
}
