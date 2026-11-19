// Addon geometries and fonts: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { RoundedBoxGeometry } from "../three/addons/geometries/RoundedBoxGeometry";
import { ParametricGeometry } from "../three/addons/geometries/ParametricGeometry";
import { klein } from "../three/addons/geometries/ParametricFunctions";
import { ConvexGeometry } from "../three/addons/geometries/ConvexGeometry";
import { ConvexHull } from "../three/addons/math/ConvexHull";
import { DecalGeometry } from "../three/addons/geometries/DecalGeometry";
import { FontLoader } from "../three/addons/loaders/FontLoader";
import { TextGeometry, TextGeometryParameters } from "../three/addons/geometries/TextGeometry";

// A typeface with one glyph: a square with a square hole.
const TYPEFACE = '{"glyphs":{"O":{"ha":120,"o":"m 0 0 l 0 100 l 100 100 l 100 0 l 0 0 m 25 25 l 75 25 l 75 75 l 25 75 l 25 25"}},'
    + '"resolution":100,"ascender":100,"boundingBox":{"yMin":0,"yMax":100},"underlineThickness":0}';

export class GeometriesPlusTests extends Tests {
    override run(): void {
        group("addon geometries", () => {
            test("RoundedBoxGeometry keeps its extent", (expect) => {
                const g = new RoundedBoxGeometry(2, 1, 1, 3, 0.2);
                g.computeBoundingBox();
                const b = g.boundingBox!;
                expect.that(Math.abs(b.max.x - 1) < 1e-5 && Math.abs(b.max.y - 0.5) < 1e-5).is(true);
                expect.that(g.index == null).is(true);
            });
            test("ParametricGeometry grid", (expect) => {
                const g = new ParametricGeometry(klein, 10, 6);
                expect.that(g.getAttribute("position")!.count).is(11 * 7);
                expect.that(g.index!.count).is(10 * 6 * 6);
            });
            test("ConvexHull of a cube's corners and inner points", (expect) => {
                const pts: Array<THREE.Vector3> = [];
                for (let i = 0; i < 8; i++) pts.push(new THREE.Vector3(<f64>(i & 1), <f64>((i >> 1) & 1), <f64>((i >> 2) & 1)));
                pts.push(new THREE.Vector3(0.5, 0.5, 0.5));
                pts.push(new THREE.Vector3(0.2, 0.7, 0.4));
                const hull = new ConvexHull().setFromPoints(pts);
                expect.that(hull.faces.length).is(12);
                expect.that(hull.containsPoint(new THREE.Vector3(0.5, 0.5, 0.5))).is(true);
                expect.that(hull.containsPoint(new THREE.Vector3(1.5, 0.5, 0.5))).is(false);
                const g = new ConvexGeometry(pts);
                expect.that(g.getAttribute("position")!.count).is(36);
            });
            test("DecalGeometry cuts a plane to its box", (expect) => {
                const mesh = new THREE.Mesh(new THREE.PlaneGeometry(10, 10, 10, 10));
                const g = new DecalGeometry(mesh, new THREE.Vector3(0, 0, 0), new THREE.Euler(), new THREE.Vector3(2, 2, 2));
                g.computeBoundingBox();
                const b = g.boundingBox!;
                expect.that(b.max.x <= 1.0001 && b.min.x >= -1.0001 && b.max.x > 0.99).is(true);
                expect.that(g.getAttribute("uv")!.count > 0).is(true);
            });
        });
        group("fonts", () => {
            test("FontLoader and TextGeometry", (expect) => {
                const loader = new FontLoader();
                const font = loader.parse(TYPEFACE);
                expect.that(loader.error).is("");
                if (font == null) return;
                const shapes = font.generateShapes("OO", 1);
                expect.that(shapes.length).is(2);
                expect.that(shapes[0].holes.length).is(1);
                const p = new TextGeometryParameters();
                p.font = font;
                p.size = 1;
                p.depth = 0.2;
                const g = new TextGeometry("O", p);
                g.computeBoundingBox();
                expect.that(Math.abs(g.boundingBox!.max.z - 0.2) < 1e-5).is(true);
            });
        });
    }
}
