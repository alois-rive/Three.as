// Loaders that need no Context: rive . --test

import { Tests } from "rive/test";
import { OBJLoader } from "../three/addons/loaders/OBJLoader";
import { Mesh } from "../three/objects/Mesh";
import { LineSegments } from "../three/objects/Line";

const OBJ: string = `# a quad, a triangle with negative indices, a line
o Quad
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vn 0 0 1
usemtl Red
f 1/1/1 2/2/1 3/3/1 4/4/1
o Tri
v 2 0 0 1 0 0
v 3 0 0 0 1 0
v 2 1 0 0 0 1
f -3 -2 -1
o Wire
l 1 3
`;

export class LoaderTests extends Tests {
    override run(): void {
        group("OBJLoader", () => {
            test("objects, fans, negative indices, colours, lines", (expect) => {
                const group = new OBJLoader().parse(OBJ);
                expect.that(<f64>group.children.length).is(3);
                const quad = group.children[0] as Mesh;
                expect.that(quad.name).is("Quad");
                expect.that(<f64>quad.geometry.getAttribute("position")!.count).is(6);   // two triangles
                expect.that(quad.geometry.hasAttribute("uv")).is(true);
                expect.that(quad.material.name).is("Red");
                const tri = group.children[1] as Mesh;
                expect.that(tri.geometry.hasAttribute("color")).is(true);
                expect.that(tri.geometry.getAttribute("position")!.getX(0)).is(2);
                expect.that(tri.geometry.hasAttribute("normal")).is(true);   // computed
                expect.that(group.children[2] instanceof LineSegments).is(true);
            });
        });
    }
}
