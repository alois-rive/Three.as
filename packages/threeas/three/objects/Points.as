// three.js Points: a square (or `map`-shaped) sprite at every vertex, sized
// by PointsMaterial.size. Drawn as instanced quads (WebGPU has no point
// size). Indices, if any, are ignored.

import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { PointsMaterial } from "../materials/PointsMaterial";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastPoints } from "./raycasting";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";
import { geometryToLibrary, materialToLibrary } from "./serialize";

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

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("geometry", Dynamic.fromString(geometryToLibrary(this.geometry, meta)));
        object.set("material", Dynamic.fromString(materialToLibrary(this.material, meta)));
    }

    /// Hits within raycaster.params.Points.threshold of a point.
    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastPoints(this, raycaster, intersects);
        return true;
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof Points) {
            const s = source as Points;
            this.geometry = s.geometry;
            this.material = s.material;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Points(this.geometry, this.material).copy(this, recursive);
    }
}
