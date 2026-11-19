// three.js PlaneHelper: a Plane as a size x size outlined square with a
// faint fill (follows the plane every frame).

import { Line } from "../objects/Line";
import { Mesh } from "../objects/Mesh";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Plane } from "../math/Plane";
import { BackSide } from "../constants";

export class PlaneHelper extends Line {
    plane: Plane;
    size: f64;

    constructor(plane: Plane, size: f64 = 1, hex: u32 = 0xffff00) {
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(
            [1, -1, 0, -1, 1, 0, -1, -1, 0, 1, 1, 0, -1, 1, 0, -1, -1, 0, 1, -1, 0, 1, 1, 0], 3));
        geometry.computeBoundingSphere();
        super(geometry, new LineBasicMaterial({ color: hex, toneMapped: false }));
        this.type = "PlaneHelper";
        this.plane = plane;
        this.size = size;
        const fill = new BufferGeometry();
        fill.setAttribute("position", new Float32BufferAttribute(
            [1, 1, 0, -1, 1, 0, -1, -1, 0, 1, 1, 0, -1, -1, 0, 1, -1, 0], 3));
        fill.computeBoundingSphere();
        this.add(new Mesh(fill, new MeshBasicMaterial({
            color: hex, opacity: 0.2, transparent: true, depthWrite: false, toneMapped: false, side: BackSide,
        })));
    }

    override updateMatrixWorld(force: bool = false): void {
        this.position.set(0, 0, 0);
        this.scale.set(0.5 * this.size, 0.5 * this.size, 1);
        this.lookAt<f64>(this.plane.normal.x, this.plane.normal.y, this.plane.normal.z);
        this.translateZ(-this.plane.constant);
        super.updateMatrixWorld(force);
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
