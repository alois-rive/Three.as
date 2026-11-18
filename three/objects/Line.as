// three.js Line, LineSegments and LineLoop. Lines are one pixel wide (as
// three.js on almost every platform: `linewidth` is ignored).

import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Material } from "../materials/Material";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Vector3 } from "../math/Vector3";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastLine } from "./raycasting";

/// A continuous line through the vertices (a line strip).
export class Line extends Object3D {
    readonly isLine: bool = true;
    geometry: BufferGeometry;
    material: Material;

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new LineBasicMaterial()) {
        super();
        this.type = "Line";
        this.geometry = geometry;
        this.material = material;
    }

    /// Hits within raycaster.params.Line.threshold of the line.
    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastLine(this, raycaster, intersects);
        return true;
    }

    /// Fills the "lineDistance" attribute LineDashedMaterial reads: the
    /// distance along the line at each vertex.
    computeLineDistances(): Line {
        const position = this.geometry.getAttribute("position");
        if (position == null) return this;
        const distances: Array<f64> = [0];
        for (let i = 1; i < position.count; i++) {
            _start.set(position.getX(i - 1), position.getY(i - 1), position.getZ(i - 1));
            _end.set(position.getX(i), position.getY(i), position.getZ(i));
            distances.push(distances[i - 1] + _start.distanceTo(_end));
        }
        this.geometry.setAttribute("lineDistance", new Float32BufferAttribute(distances, 1));
        return this;
    }
}

/// Independent segments: vertices 0-1, 2-3, ...
export class LineSegments extends Line {
    readonly isLineSegments: bool = true;

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new LineBasicMaterial()) {
        super(geometry, material);
        this.type = "LineSegments";
    }

    override computeLineDistances(): Line {
        const position = this.geometry.getAttribute("position");
        if (position == null) return this;
        const distances: Array<f64> = [];
        for (let i = 0; i + 1 < position.count; i += 2) {
            _start.set(position.getX(i), position.getY(i), position.getZ(i));
            _end.set(position.getX(i + 1), position.getY(i + 1), position.getZ(i + 1));
            distances.push(0);
            distances.push(_start.distanceTo(_end));
        }
        this.geometry.setAttribute("lineDistance", new Float32BufferAttribute(distances, 1));
        return this;
    }
}

/// A closed line: the last vertex joins the first.
export class LineLoop extends Line {
    readonly isLineLoop: bool = true;

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new LineBasicMaterial()) {
        super(geometry, material);
        this.type = "LineLoop";
    }
}

const _start: Vector3 = new Vector3();
const _end: Vector3 = new Vector3();
