// three.js InstancedBufferAttribute: one item per instance.

import { BufferAttribute } from "./BufferAttribute";

export class InstancedBufferAttribute extends BufferAttribute {
    readonly isInstancedBufferAttribute: bool = true;
    meshPerAttribute: i32;

    constructor(array: Float32Array, itemSize: i32, normalized: bool = false, meshPerAttribute: i32 = 1) {
        super(array, itemSize, normalized);
        this.meshPerAttribute = meshPerAttribute;
    }
}
