// three.js Box3Helper: a Box3, drawn as its edges (follows the box every
// frame).

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Box3 } from "../math/Box3";

export class Box3Helper extends LineSegments {
    box: Box3;

    constructor(box: Box3, color: u32 = 0xffff00) {
        const geometry = new BufferGeometry();
        geometry.setIndex([0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]);
        geometry.setAttribute("position", new Float32BufferAttribute(
            [1, 1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1, 1, 1, -1, -1, 1, -1, -1, -1, -1, 1, -1, -1], 3));
        super(geometry, new LineBasicMaterial({ color: color, toneMapped: false }));
        this.box = box;
        this.type = "Box3Helper";
        this.geometry.computeBoundingSphere();
    }

    override updateMatrixWorld(force: bool = false): void {
        const box = this.box;
        if (box.isEmpty()) return;
        box.getCenter(this.position);
        box.getSize(this.scale);
        this.scale.multiplyScalar(0.5);
        super.updateMatrixWorld(force);
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
