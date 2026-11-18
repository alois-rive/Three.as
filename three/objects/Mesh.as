// three.js Mesh: a geometry drawn with a material.

import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";

export class Mesh extends Object3D {
    readonly isMesh: bool = true;
    geometry: BufferGeometry;
    /// One material for the whole geometry (material arrays per geometry
    /// group come in M2).
    material: Material;

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new MeshBasicMaterial()) {
        super();
        this.type = "Mesh";
        this.geometry = geometry;
        this.material = material;
    }
}
