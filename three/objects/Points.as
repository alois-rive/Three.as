// three.js Points: a square (or `map`-shaped) sprite at every vertex, sized
// by PointsMaterial.size. Drawn as instanced quads (WebGPU has no point
// size). Indices, if any, are ignored.

import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { PointsMaterial } from "../materials/PointsMaterial";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastPoints } from "./raycasting";

export class Points extends Object3D {
    readonly isPoints: bool = true;
    geometry: BufferGeometry;
    material: Material;

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new PointsMaterial()) {
        super();
        this.type = "Points";
        this.geometry = geometry;
        this.material = material;
    }

    /// Hits within raycaster.params.Points.threshold of a point.
    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastPoints(this, raycaster, intersects);
        return true;
    }
}
