// three.js GridHelper: a size x size grid on the XZ plane, `divisions`
// cells across; the centre lines in color1, the rest in color2.

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Color } from "../math/Color";

export class GridHelper extends LineSegments {
    constructor(size: f64 = 10, divisions: i32 = 10, color1: u32 = 0x444444, color2: u32 = 0x888888) {
        const c1 = Color.fromHex(color1), c2 = Color.fromHex(color2);
        const center = divisions / 2;
        const step = size / <f64>divisions;
        const half = size / 2;
        const vertices: Array<f64> = [];
        const colors: Array<f64> = [];
        let k = -half;
        for (let i = 0; i <= divisions; i++) {
            vertices.push(-half); vertices.push(0); vertices.push(k);
            vertices.push(half); vertices.push(0); vertices.push(k);
            vertices.push(k); vertices.push(0); vertices.push(-half);
            vertices.push(k); vertices.push(0); vertices.push(half);
            const c = i == center ? c1 : c2;
            for (let j = 0; j < 4; j++) { colors.push(c.r); colors.push(c.g); colors.push(c.b); }
            k += step;
        }
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        geometry.setAttribute("color", new Float32BufferAttribute(colors, 3));
        super(geometry, new LineBasicMaterial({ vertexColors: true, toneMapped: false }));
        this.type = "GridHelper";
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
