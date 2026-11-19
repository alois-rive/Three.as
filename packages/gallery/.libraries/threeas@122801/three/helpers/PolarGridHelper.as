// three.js PolarGridHelper: `sectors` radial lines and `rings` circles of
// `divisions` segments on the XZ plane, alternating color1 and color2.

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Color } from "../math/Color";

export class PolarGridHelper extends LineSegments {
    constructor(radius: f64 = 10, sectors: i32 = 16, rings: i32 = 8, divisions: i32 = 64,
                color1: u32 = 0x444444, color2: u32 = 0x888888) {
        const c1 = Color.fromHex(color1), c2 = Color.fromHex(color2);
        const vertices: Array<f64> = [];
        const colors: Array<f64> = [];
        if (sectors > 1) {
            for (let i = 0; i < sectors; i++) {
                const v = <f64>i / <f64>sectors * Math.PI * 2;
                const x = Math.sin(v) * radius, z = Math.cos(v) * radius;
                vertices.push(0); vertices.push(0); vertices.push(0);
                vertices.push(x); vertices.push(0); vertices.push(z);
                const c = (i & 1) != 0 ? c1 : c2;
                for (let j = 0; j < 2; j++) { colors.push(c.r); colors.push(c.g); colors.push(c.b); }
            }
        }
        for (let i = 0; i < rings; i++) {
            const c = (i & 1) != 0 ? c1 : c2;
            const r = radius - radius / <f64>rings * <f64>i;
            for (let j = 0; j < divisions; j++) {
                let v = <f64>j / <f64>divisions * Math.PI * 2;
                vertices.push(Math.sin(v) * r); vertices.push(0); vertices.push(Math.cos(v) * r);
                v = <f64>(j + 1) / <f64>divisions * Math.PI * 2;
                vertices.push(Math.sin(v) * r); vertices.push(0); vertices.push(Math.cos(v) * r);
                for (let k = 0; k < 2; k++) { colors.push(c.r); colors.push(c.g); colors.push(c.b); }
            }
        }
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        geometry.setAttribute("color", new Float32BufferAttribute(colors, 3));
        super(geometry, new LineBasicMaterial({ vertexColors: true, toneMapped: false }));
        this.type = "PolarGridHelper";
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
