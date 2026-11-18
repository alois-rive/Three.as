// The geometry an object draws, for bounds and culling (internal). Extended
// as drawable object types are added.

import { Object3D } from "./Object3D";
import { BufferGeometry } from "./BufferGeometry";
import { Mesh } from "../objects/Mesh";

export function geometryOf(object: Object3D): BufferGeometry? {
    if (object instanceof Mesh) return (object as Mesh).geometry;
    return null;
}
