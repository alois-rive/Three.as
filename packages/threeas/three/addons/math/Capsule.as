// three.js examples/jsm/math/Capsule.js: a capsule, the segment `start` to
// `end` swept by a sphere of `radius`. Octree (addons/math/Octree)
// collides one with a world; games_fps's player is one.

import { Vector3 } from "../../math/Vector3";
import { Box3 } from "../../math/Box3";

export class Capsule {
    /// The start of the capsule's segment.
    start: Vector3;
    /// The end of the capsule's segment.
    end: Vector3;
    /// The capsule's radius.
    radius: f64;

    constructor(start: Vector3 = new Vector3(0, 0, 0), end: Vector3 = new Vector3(0, 1, 0), radius: f64 = 1) {
        this.start = start;
        this.end = end;
        this.radius = radius;
    }

    /// A new capsule with this one's values.
    clone(): Capsule {
        return new Capsule().copy(this);
    }

    /// Sets the start, end and radius (the vectors are copied).
    set(start: Vector3, end: Vector3, radius: f64): Capsule {
        this.start.copy(start);
        this.end.copy(end);
        this.radius = radius;
        return this;
    }

    copy(capsule: Capsule): Capsule {
        this.start.copy(capsule.start);
        this.end.copy(capsule.end);
        this.radius = capsule.radius;
        return this;
    }

    /// The centre of the capsule's segment, in `target`.
    getCenter(target: Vector3): Vector3 {
        return target.copy(this.end).add(this.start).multiplyScalar(0.5);
    }

    /// Moves the capsule by `v`.
    translate(v: Vector3): Capsule {
        this.start.add(v);
        this.end.add(v);
        return this;
    }

    /// Whether the capsule may intersect `box`: its segment, grown by the
    /// radius, overlaps the box in each axis-aligned projection (xy, xz,
    /// yz). Conservative, as three.js's: a broad phase for Octree.
    intersectsBox(box: Box3): bool {
        return (
            checkAABBAxis(
                this.start.x, this.start.y, this.end.x, this.end.y,
                box.min.x, box.max.x, box.min.y, box.max.y,
                this.radius) &&
            checkAABBAxis(
                this.start.x, this.start.z, this.end.x, this.end.z,
                box.min.x, box.max.x, box.min.z, box.max.z,
                this.radius) &&
            checkAABBAxis(
                this.start.y, this.start.z, this.end.y, this.end.z,
                box.min.y, box.max.y, box.min.z, box.max.z,
                this.radius)
        );
    }
}

function checkAABBAxis(p1x: f64, p1y: f64, p2x: f64, p2y: f64,
        minx: f64, maxx: f64, miny: f64, maxy: f64, radius: f64): bool {
    return (
        (minx - p1x < radius || minx - p2x < radius) &&
        (p1x - maxx < radius || p2x - maxx < radius) &&
        (miny - p1y < radius || miny - p2y < radius) &&
        (p1y - maxy < radius || p2y - maxy < radius)
    );
}
