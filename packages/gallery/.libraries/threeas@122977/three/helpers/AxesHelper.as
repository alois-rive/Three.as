// three.js AxesHelper: the X (red), Y (green) and Z (blue) axes, `size`
// long.

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Color } from "../math/Color";

export class AxesHelper extends LineSegments {
    constructor(size: f64 = 1) {
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(
            [0, 0, 0, size, 0, 0, 0, 0, 0, 0, size, 0, 0, 0, 0, 0, 0, size], 3));
        geometry.setAttribute("color", new Float32BufferAttribute(
            [1, 0, 0, 1, 0.6, 0, 0, 1, 0, 0.6, 1, 0, 0, 0, 1, 0, 0.6, 1], 3));
        super(geometry, new LineBasicMaterial({ vertexColors: true, toneMapped: false }));
        this.type = "AxesHelper";
    }

    setColors(xAxisColor: Color, yAxisColor: Color, zAxisColor: Color): AxesHelper {
        const a = this.geometry.getAttribute("color")!;
        const cs: StaticArray<Color> = [xAxisColor, xAxisColor, yAxisColor, yAxisColor, zAxisColor, zAxisColor];
        for (let i = 0; i < 6; i++) a.setXYZ(i, cs[i].r, cs[i].g, cs[i].b);
        a.needsUpdate = true;
        return this;
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
