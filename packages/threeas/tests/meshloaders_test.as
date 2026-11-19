// STLLoader and PLYLoader: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { STLLoader } from "../three/addons/loaders/STLLoader";
import { PLYLoader } from "../three/addons/loaders/PLYLoader";

export class MeshLoaderTests extends Tests {
    override run(): void {
        group("STLLoader", () => {
            test("binary, with Magics colours", (expect) => {
                const bytes = this.blob("pyramid_binary");
                if (bytes == null) return;
                const g = new STLLoader().parse(bytes!);
                expect.that(g.getAttribute("position")!.count).is(18);
                expect.that(g.hasColors).is(true);
                expect.that(g.alpha).is(1);
                const c = g.getAttribute("color")!;
                // Face 2 is pure-ish red (31, 4, 4 in 5 bits), linear.
                expect.that(c.getX(6) > 0.99 && c.getY(6) < 0.02).is(true);
                // Face 0 takes the header colour (200, 120, 40), linearized.
                expect.that(Math.abs(c.getX(0) - new THREE.Color().setRGB(200 / 255, 0, 0, THREE.SRGBColorSpace).r) < 1e-6).is(true);
                // The base's normal points down.
                expect.that(Math.abs(g.getAttribute("normal")!.getY(0) + 1) < 1e-6).is(true);
            });
            test("ASCII, two solids as groups", (expect) => {
                const bytes = this.blob("pyramid_ascii");
                if (bytes == null) return;
                const g = new STLLoader().parse(bytes!);
                expect.that(g.getAttribute("position")!.count).is(18);
                expect.that(g.groups.length).is(2);
                expect.that(g.groups[1].start).is(6);
                expect.that(g.groups[1].count).is(12);
                expect.that(g.groupNames[0]).is("base");
                expect.that(g.groupNames[1]).is("sides");
                expect.that(g.getAttribute("position")!.getY(8)).is(1.5);
            });
        });
        group("PLYLoader", () => {
            test("ASCII: normals, colours, quads, custom properties", (expect) => {
                const bytes = this.blob("cube_ascii");
                if (bytes == null) return;
                const loader = new PLYLoader();
                const custom = new Map<string, Array<string>>();
                custom.set("quality", ["quality"]);
                loader.setCustomPropertyNameMapping(custom);
                const g = loader.parse(bytes!);
                expect.that(g.getAttribute("position")!.count).is(8);
                expect.that(g.index!.count).is(36);
                expect.that(g.getAttribute("normal") != null).is(true);
                expect.that(g.getAttribute("color")!.getX(7)).is(1);
                expect.that(g.getAttribute("quality")!.getX(7)).is(2.5);
            });
            test("binary big endian, uvs, ushort lists", (expect) => {
                const bytes = this.blob("quad_binary");
                if (bytes == null) return;
                const g = new PLYLoader().parse(bytes!);
                expect.that(g.getAttribute("position")!.count).is(4);
                expect.that(g.index!.count).is(6);
                expect.that(g.index!.getX(5)).is(3);
                expect.that(g.getAttribute("position")!.getX(1)).is(1);
                expect.that(g.getAttribute("uv")!.getY(2)).is(1);
            });
        });
    }
}
