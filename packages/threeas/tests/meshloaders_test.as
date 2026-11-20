// STLLoader, PLYLoader and OBJLoader: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { STLLoader, decodeSTL, buildSTLFromDecoded } from "../three/addons/loaders/STLLoader";
import { PLYLoader, decodePLY, buildPLYFromDecoded } from "../three/addons/loaders/PLYLoader";
import { OBJLoader, decodeOBJ, buildOBJFromDecoded } from "../three/addons/loaders/OBJLoader";

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
            test("decodeSTL (job path) matches parse and attaches Blob", (expect) => {
                const bin = this.blob("pyramid_binary");
                if (bin != null) {
                    const a = new STLLoader().parse(bin!);
                    const decoded = decodeSTL(bin!);
                    expect.that(decoded.blob != null).is(true);
                    const b = buildSTLFromDecoded(decoded);
                    const pa = a.getAttribute("position")!, pb = b.getAttribute("position")!;
                    expect.that(pb.count).is(pa.count);
                    expect.that(pb._blob != null).is(true);
                    for (let i = 0; i < pa.array.length; i++) expect.that(<f64>pb.array[i]).is(<f64>pa.array[i]);
                    expect.that(b.hasColors).is(true);
                    pb.needsUpdate = true;
                    expect.that(pb._blob == null).is(true);
                }
                const asc = this.blob("pyramid_ascii");
                if (asc != null) {
                    const decoded = decodeSTL(asc!);
                    const b = buildSTLFromDecoded(decoded);
                    expect.that(b.groups.length).is(2);
                    expect.that(b.groupNames[1]).is("sides");
                }
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
            test("binary little endian (BinaryReader) and decodePLY job path", (expect) => {
                const hdr = "ply\nformat binary_little_endian 1.0\nelement vertex 3\n"
                    + "property float x\nproperty float y\nproperty float z\n"
                    + "element face 1\nproperty list uchar int vertex_indices\nend_header\n";
                const hBytes = Uint8Array.wrap(String.UTF8.encode(hdr));
                const total = hBytes.length + 3 * 12 + 1 + 3 * 4;
                const buf = new ArrayBuffer(total);
                const u8 = Uint8Array.wrap(buf);
                u8.set(hBytes, 0);
                const dv = new DataView(buf, hBytes.length);
                dv.setFloat32(0, 0, true); dv.setFloat32(4, 0, true); dv.setFloat32(8, 0, true);
                dv.setFloat32(12, 2, true); dv.setFloat32(16, 0, true); dv.setFloat32(20, 0, true);
                dv.setFloat32(24, 0, true); dv.setFloat32(28, 3, true); dv.setFloat32(32, 0, true);
                dv.setUint8(36, 3);
                dv.setInt32(37, 0, true); dv.setInt32(41, 1, true); dv.setInt32(45, 2, true);
                const sync = new PLYLoader().parse(buf);
                const decoded = decodePLY(buf);
                expect.that(decoded.blob != null).is(true);
                const asyncGeo = buildPLYFromDecoded(decoded);
                expect.that(sync.getAttribute("position")!.count).is(3);
                expect.that(asyncGeo.getAttribute("position")!.count).is(3);
                expect.that(asyncGeo.getAttribute("position")!._blob != null).is(true);
                expect.that(asyncGeo.getAttribute("position")!.getX(1)).is(2);
                expect.that(asyncGeo.getAttribute("position")!.getY(2)).is(3);
                expect.that(asyncGeo.index!.count).is(3);
                expect.that(asyncGeo.index!.getX(2)).is(2);
            });
        });
        group("OBJLoader", () => {
            test("decodeOBJ (job path) matches parse and attaches Blob", (expect) => {
                const src = "o tri\nusemtl red\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\n"
                    + "vn 0 0 1\nf 1/1/1 2/2/1 3/3/1\n";
                const a = new OBJLoader().parse(src);
                const decoded = decodeOBJ(src);
                expect.that(decoded.blob != null).is(true);
                const b = buildOBJFromDecoded(decoded);
                expect.that(b.children.length).is(a.children.length);
                const ma = a.children[0] as THREE.Mesh;
                const mb = b.children[0] as THREE.Mesh;
                expect.that(mb.name).is("tri");
                expect.that(mb.material.name).is("red");
                const pa = ma.geometry.getAttribute("position")!;
                const pb = mb.geometry.getAttribute("position")!;
                expect.that(pb._blob != null).is(true);
                expect.that(mb.geometry.getAttribute("uv")!._blob != null).is(true);
                for (let i = 0; i < pa.array.length; i++) expect.that(<f64>pb.array[i]).is(<f64>pa.array[i]);
            });
        });
    }
}
