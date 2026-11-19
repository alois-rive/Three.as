// Geometry generators: counts match three.js, triangles face outwards
// (counter-clockwise front faces agree with the vertex normals), normals
// are unit length. rive . --test

import { Expect, Tests } from "rive/test";
import { Vector3 } from "../three/math/Vector3";
import { BufferGeometry } from "../three/core/BufferGeometry";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { SphereGeometry } from "../three/geometries/SphereGeometry";
import { PlaneGeometry } from "../three/geometries/PlaneGeometry";
import { CircleGeometry } from "../three/geometries/CircleGeometry";
import { RingGeometry } from "../three/geometries/RingGeometry";
import { CylinderGeometry } from "../three/geometries/CylinderGeometry";
import { ConeGeometry } from "../three/geometries/ConeGeometry";
import { TorusGeometry } from "../three/geometries/TorusGeometry";
import { TorusKnotGeometry } from "../three/geometries/TorusKnotGeometry";
import { LatheGeometry } from "../three/geometries/LatheGeometry";
import { CapsuleGeometry } from "../three/geometries/CapsuleGeometry";
import {
    IcosahedronGeometry, OctahedronGeometry, TetrahedronGeometry, DodecahedronGeometry,
} from "../three/geometries/PolyhedronGeometry";
import { EdgesGeometry } from "../three/geometries/EdgesGeometry";
import { WireframeGeometry } from "../three/geometries/WireframeGeometry";

@editTime
function counts(expect: Expect, g: BufferGeometry, vertices: i32, indices: i32): void {
    expect.that(<f64>g.getAttribute("position")!.count).is(<f64>vertices);
    const index = g.index;
    expect.that(<f64>(index != null ? index.count : -1)).is(<f64>indices);
}

/// The number of non-degenerate triangles whose counter-clockwise face
/// normal points against the average of their vertex normals.
@editTime
function inwardFaces(g: BufferGeometry): i32 {
    const p = g.getAttribute("position")!;
    const n = g.getAttribute("normal")!;
    const index = g.index;
    const count = index != null ? index.count : p.count;
    const a = new Vector3(), b = new Vector3(), c = new Vector3(), face = new Vector3(), avg = new Vector3();
    let bad = 0;
    for (let t = 0; t + 2 < count; t += 3) {
        const i0 = index != null ? index.getX(t) : t;
        const i1 = index != null ? index.getX(t + 1) : t + 1;
        const i2 = index != null ? index.getX(t + 2) : t + 2;
        a.set(p.getX(i0), p.getY(i0), p.getZ(i0));
        b.set(p.getX(i1), p.getY(i1), p.getZ(i1));
        c.set(p.getX(i2), p.getY(i2), p.getZ(i2));
        face.subVectors(c, b).cross(a.clone().sub(b));
        if (face.lengthSq() < 1e-14) continue;
        avg.set(n.getX(i0) + n.getX(i1) + n.getX(i2), n.getY(i0) + n.getY(i1) + n.getY(i2),
            n.getZ(i0) + n.getZ(i1) + n.getZ(i2));
        if (face.dot(avg) <= 0) bad++;
    }
    return bad;
}

@editTime
function nonUnitNormals(g: BufferGeometry): i32 {
    const n = g.getAttribute("normal")!;
    let bad = 0;
    for (let i = 0; i < n.count; i++) {
        const l = Math.sqrt(n.getX(i) * n.getX(i) + n.getY(i) * n.getY(i) + n.getZ(i) * n.getZ(i));
        if (Math.abs(l - 1) > 1e-4) bad++;
    }
    return bad;
}

@editTime
function wellFormed(expect: Expect, g: BufferGeometry): void {
    expect.that(<f64>inwardFaces(g)).is(0);
    expect.that(<f64>nonUnitNormals(g)).is(0);
    expect.that(<f64>g.getAttribute("uv")!.count).is(<f64>g.getAttribute("position")!.count);
}

export class GeometryTests extends Tests {
    override run(): void {
        group("counts", () => {
            test("circle", (expect) => { counts(expect, new CircleGeometry(1, 8), 10, 24); });
            test("ring", (expect) => { counts(expect, new RingGeometry(0.5, 1, 8, 2), 27, 96); });
            test("cylinder", (expect) => {
                const g = new CylinderGeometry(1, 1, 1, 8, 1);
                counts(expect, g, 52, 96);
                expect.that(<f64>g.groups.length).is(3);
            });
            test("cone", (expect) => {
                const g = new ConeGeometry(1, 1, 8);
                counts(expect, g, 35, 48);
                expect.that(<f64>g.groups.length).is(2);
            });
            test("torus", (expect) => { counts(expect, new TorusGeometry(1, 0.4, 4, 8), 45, 192); });
            test("torus knot", (expect) => { counts(expect, new TorusKnotGeometry(1, 0.4, 16, 4), 85, 384); });
            test("lathe", (expect) => { counts(expect, new LatheGeometry(), 39, 144); });
            test("capsule", (expect) => { counts(expect, new CapsuleGeometry(1, 1, 4, 8, 1), 90, 432); });
            test("polyhedra are triangle soups", (expect) => {
                counts(expect, new IcosahedronGeometry(1, 0), 60, -1);
                counts(expect, new IcosahedronGeometry(1, 1), 240, -1);
                counts(expect, new OctahedronGeometry(), 24, -1);
                counts(expect, new TetrahedronGeometry(), 12, -1);
                counts(expect, new DodecahedronGeometry(), 108, -1);
            });
            test("edges of a box: its 12 edges", (expect) => {
                expect.that(<f64>new EdgesGeometry(new BoxGeometry()).getAttribute("position")!.count).is(24);
            });
            test("wireframe of a box: 12 edges and 6 diagonals", (expect) => {
                expect.that(<f64>new WireframeGeometry(new BoxGeometry()).getAttribute("position")!.count).is(36);
            });
        });

        group("well formed", () => {
            test("box", (expect) => { wellFormed(expect, new BoxGeometry(1, 2, 3, 2, 2, 2)); });
            test("sphere", (expect) => { wellFormed(expect, new SphereGeometry(1, 12, 8)); });
            test("plane", (expect) => { wellFormed(expect, new PlaneGeometry(2, 2, 3, 3)); });
            test("circle", (expect) => { wellFormed(expect, new CircleGeometry(1, 12)); });
            test("ring", (expect) => { wellFormed(expect, new RingGeometry(0.5, 1, 12, 3)); });
            test("cylinder", (expect) => { wellFormed(expect, new CylinderGeometry(0.5, 1, 2, 12, 3)); });
            test("cone", (expect) => { wellFormed(expect, new ConeGeometry(1, 2, 12, 2)); });
            test("torus", (expect) => { wellFormed(expect, new TorusGeometry(1, 0.3, 8, 16)); });
            test("torus knot", (expect) => { wellFormed(expect, new TorusKnotGeometry(1, 0.3, 64, 8)); });
            test("lathe", (expect) => {
                // As three.js, the last profile point's normal is left
                // unnormalized: check winding only.
                expect.that(<f64>inwardFaces(new LatheGeometry())).is(0);
            });
            test("capsule", (expect) => { wellFormed(expect, new CapsuleGeometry(0.5, 1, 4, 12, 2)); });
            test("icosahedron", (expect) => {
                wellFormed(expect, new IcosahedronGeometry(1, 0));
                wellFormed(expect, new IcosahedronGeometry(1, 2));
            });
            test("octahedron", (expect) => { wellFormed(expect, new OctahedronGeometry(1, 1)); });
            test("tetrahedron", (expect) => { wellFormed(expect, new TetrahedronGeometry()); });
            test("dodecahedron", (expect) => { wellFormed(expect, new DodecahedronGeometry()); });
            test("polyhedron vertices lie on the radius", (expect) => {
                const p = new IcosahedronGeometry(2, 1).getAttribute("position")!;
                let bad = 0;
                for (let i = 0; i < p.count; i++) {
                    const l = Math.sqrt(p.getX(i) * p.getX(i) + p.getY(i) * p.getY(i) + p.getZ(i) * p.getZ(i));
                    if (Math.abs(l - 2) > 1e-4) bad++;
                }
                expect.that(<f64>bad).is(0);
            });
        });
        group("computeTangents", () => {
            test("a plane's tangents follow +u, right handed", (expect) => {
                const g = new PlaneGeometry(2, 2, 2, 2);
                g.computeTangents();
                const t = g.getAttribute("tangent");
                expect.that(t != null).is(true);
                if (t == null) return;
                expect.that(<f64>t.itemSize).is(4);
                for (let v = 0; v < t.count; v++) {
                    expect.that(Math.abs(<f64>t.array[v * 4] - 1) < 1e-6 && Math.abs(<f64>t.array[v * 4 + 1]) < 1e-6
                        && <f64>t.array[v * 4 + 3] == 1).is(true);
                }
            });
        });
    }
}
