// three.js Mesh: a geometry drawn with a material, or with one material per
// geometry group.

import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastMesh } from "./raycasting";

export class Mesh extends Object3D {
    readonly isMesh: bool = true;
    geometry: BufferGeometry;
    /// The material of the whole geometry, when `materials` is empty.
    material: Material;
    /// One material per geometry group, indexed by the group's
    /// materialIndex: three.js's `material` array (a field cannot be
    /// "Material or array" here). Groups without a material are not drawn.
    materials: Array<Material> = [];
    /// Morph target weights, one per geometry.morphAttributes entry.
    morphTargetInfluences: Array<f64> = [];
    /// Morph target names to indices.
    morphTargetDictionary: Map<string, i32> = new Map<string, i32>();

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new MeshBasicMaterial()) {
        super();
        this.type = "Mesh";
        this.geometry = geometry;
        this.material = material;
    }

    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastMesh(this, raycaster, intersects, this.matrixWorld, -1);
        return true;
    }
}
