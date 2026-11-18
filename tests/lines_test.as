// Wide lines: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { LineGeometry } from "../three/addons/lines/LineGeometry";
import { LineMaterial } from "../three/addons/lines/LineMaterial";
import { Line2 } from "../three/addons/lines/LineSegments2";
import { MaterialUniforms, KIND_WIDE_LINE } from "../three/materials/MaterialUniforms";

export class LinesTests extends Tests {
    override run(): void {
        group("Line2", () => {
            test("a strip becomes segments with bounds and distances", (expect) => {
                const g = new LineGeometry();
                g.setPositions([0, 0, 0, 3, 0, 0, 3, 4, 0]);
                expect.that(g.getAttribute("instanceStart")!.count).is(2);
                expect.that(<f64>g.getAttribute("instanceEnd")!.array[3]).is(3);
                expect.that(Math.abs(g.boundingSphere!.radius - 2.5) < 1e-6).is(true);
                const line = new Line2(g, new LineMaterial({ linewidth: 4, dashed: true }));
                line.computeLineDistances();
                expect.that(<f64>g.getAttribute("instanceDistanceEnd")!.array[1]).is(7);
                const u = new MaterialUniforms();
                line.material.fillUniforms(u);
                expect.that(u.kind).is(KIND_WIDE_LINE);
                expect.that(u.size).is(4);
                expect.that(u.dashed).is(true);
            });
        });
    }
}
