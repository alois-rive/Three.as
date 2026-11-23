// three.js examples/jsm/helpers/OctreeHelper.js: the boxes of an Octree's
// nodes as lines. Call `update()` after the octree was rebuilt.

import { LineSegments } from "../../objects/Line";
import { BufferGeometry } from "../../core/BufferGeometry";
import { Float32BufferAttribute } from "../../core/BufferAttribute";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { Octree } from "../math/Octree";

export class OctreeHelper extends LineSegments {
    /// The octree shown.
    octree: Octree;
    /// The lines' colour (as given to the constructor).
    color: u32;

    constructor(octree: Octree, color: u32 = 0xffff00) {
        super(new BufferGeometry(), new LineBasicMaterial({ color: color, toneMapped: false }));
        this.octree = octree;
        this.color = color;
        this.type = "OctreeHelper";
        this.update();
    }

    /// Rebuilds the lines from the octree's boxes.
    update(): void {
        const vertices: Array<f64> = [];

        traverseBoxes(this.octree.subTrees, vertices);

        this.geometry.dispose();
        this.geometry = new BufferGeometry();
        this.geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
    }

    /// Disposes the geometry and the material.
    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}

// three.js's inner traverse function (no closures).
function traverseBoxes(tree: Array<Octree>, vertices: Array<f64>): void {
    for (let i = 0; i < tree.length; i++) {
        const box = tree[i].box;
        if (box == null) continue;
        const min = box.min;
        const max = box.max;

        vertices.push(max.x); vertices.push(max.y); vertices.push(max.z); vertices.push(min.x); vertices.push(max.y); vertices.push(max.z); // 0, 1
        vertices.push(min.x); vertices.push(max.y); vertices.push(max.z); vertices.push(min.x); vertices.push(min.y); vertices.push(max.z); // 1, 2
        vertices.push(min.x); vertices.push(min.y); vertices.push(max.z); vertices.push(max.x); vertices.push(min.y); vertices.push(max.z); // 2, 3
        vertices.push(max.x); vertices.push(min.y); vertices.push(max.z); vertices.push(max.x); vertices.push(max.y); vertices.push(max.z); // 3, 0

        vertices.push(max.x); vertices.push(max.y); vertices.push(min.z); vertices.push(min.x); vertices.push(max.y); vertices.push(min.z); // 4, 5
        vertices.push(min.x); vertices.push(max.y); vertices.push(min.z); vertices.push(min.x); vertices.push(min.y); vertices.push(min.z); // 5, 6
        vertices.push(min.x); vertices.push(min.y); vertices.push(min.z); vertices.push(max.x); vertices.push(min.y); vertices.push(min.z); // 6, 7
        vertices.push(max.x); vertices.push(min.y); vertices.push(min.z); vertices.push(max.x); vertices.push(max.y); vertices.push(min.z); // 7, 4

        vertices.push(max.x); vertices.push(max.y); vertices.push(max.z); vertices.push(max.x); vertices.push(max.y); vertices.push(min.z); // 0, 4
        vertices.push(min.x); vertices.push(max.y); vertices.push(max.z); vertices.push(min.x); vertices.push(max.y); vertices.push(min.z); // 1, 5
        vertices.push(min.x); vertices.push(min.y); vertices.push(max.z); vertices.push(min.x); vertices.push(min.y); vertices.push(min.z); // 2, 6
        vertices.push(max.x); vertices.push(min.y); vertices.push(max.z); vertices.push(max.x); vertices.push(min.y); vertices.push(min.z); // 3, 7

        traverseBoxes(tree[i].subTrees, vertices);
    }
}
