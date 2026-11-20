// GLTFLoader breadth (M11a): meshopt, quantization, sparse accessors,
// instancing, material extensions, .gltf with data URIs: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { GLTFLoader, GLTFData, decodeGLTF } from "../three/addons/loaders/GLTFLoader";
import { base64Encode } from "../three/addons/exporters/GLTFExporter";
import { MeshoptDecoder, MeshoptDecoderModule } from "../three/addons/libs/meshopt_decoder";

function find(root: THREE.Object3D, name: string): THREE.Object3D? {
    return root.getObjectByName(name);
}

export class GLTFTests extends Tests {
    override run(): void {
        group("meshopt decoder", () => {
            test("the specification's 4-bit sentinel example", (expect) => {
                // Header 0xa0, one block of 16 one-byte elements (stride 4: four
                // byte streams), header bits 2 for the first stream, zero after.
                const src = new Uint8Array(1 + 1 + 10 + 3 + 32);
                src[0] = 0xa0;
                src[1] = 2;   // group 0: 4-bit sentinels
                const ex: StaticArray<u8> = [0x17, 0x5f, 0xf0, 0xbc, 0x77, 0xa9, 0x21, 0x00, 0x34, 0xb5];
                for (let i = 0; i < 10; i++) src[2 + i] = ex[i];
                // Streams 1-3: one zero header byte each; the tail is zeros.
                const out = new Uint8Array(16 * 4);
                const decoder = new MeshoptDecoderModule();
                const ok = decoder.decodeVertexBuffer(out, 16, 4, src);
                expect.that(decoder.error).is("");
                expect.that(ok).is(true);
                const deltas: StaticArray<i32> = [-1, -4, -3, 26, -91, 0, -6, 6, -4, -4, 5, -5, 1, -1, 0, 0];
                let v = 0;
                let same = true;
                for (let i = 0; i < 16; i++) {
                    v = (v + deltas[i]) & 255;
                    if (<i32>out[i * 4] != v) same = false;
                }
                expect.that(same).is(true);
            });
            test("compressed files need setMeshoptDecoder", (expect) => {
                const bytes = this.blob("features");
                if (bytes == null) return;
                const loader = new GLTFLoader();
                expect.that(loader.parse(bytes!) == null).is(true);
                expect.that(loader.error.includes("setMeshoptDecoder")).is(true);
            });
        });
        group("GLTFLoader extensions", () => {
            test("meshopt geometry, quantized geometry, sparse morphs", (expect) => {
                const bytes = this.blob("features");
                if (bytes == null) return;
                const loader = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder);
                const gltf = loader.parse(bytes!);
                expect.that(loader.error).is("");
                expect.that(loader.warnings.length).is(0);
                if (gltf == null) return;
                const glass = find(gltf.scene, "Glass") as THREE.Mesh;
                const g = glass.geometry;
                const p = g.getAttribute("position")!;
                expect.that(p.count).is(25 * 13);
                // Vertex 0 is (R + r, 0, 0); attributes are lossless.
                expect.that(Math.abs(p.getX(0) - 0.85) < 1e-6).is(true);
                expect.that(Math.abs(p.getY(0)) < 1e-6).is(true);
                // Octahedral normals are unit length.
                const n = g.getAttribute("normal")!;
                let worst: f64 = 0;
                for (let i = 0; i < n.count; i++) {
                    const l = Math.sqrt(n.getX(i) * n.getX(i) + n.getY(i) * n.getY(i) + n.getZ(i) * n.getZ(i));
                    worst = Math.max(worst, Math.abs(l - 1));
                }
                expect.that(worst < 0.02).is(true);
                expect.that(Math.abs(n.getX(0) - 1) < 0.02).is(true);
                // Exponential uvs: 2^-15 steps.
                const uv = g.getAttribute("uv")!;
                expect.that(Math.abs(uv.getX(13) - 1 / 24) < 1e-4).is(true);
                expect.that(Math.abs(uv.getY(1) - 1 / 12) < 1e-4).is(true);
                // Triangles: 576, every index in range, the first triangle's corners.
                const index = g.index!;
                expect.that(index.count).is(576 * 3);
                let inRange = true;
                for (let i = 0; i < index.count; i++) if (index.getX(i) >= <f64>p.count) inRange = false;
                expect.that(inRange).is(true);
                const corners = index.getX(0) + index.getX(1) + index.getX(2);
                expect.that(corners).is(0 + 13 + 1);

                const rings = find(gltf.scene, "Rings");
                expect.that(rings instanceof THREE.LineSegments).is(true);
                const li = (rings as THREE.LineSegments).geometry.index!;
                expect.that(li.getX(0)).is(0);
                expect.that(li.getX(1)).is(1);
                expect.that(li.getX(24)).is(13);   // 12 segments a ring, then the next ring

                const q = find(gltf.scene, "Quantized") as THREE.Mesh;
                const qp = q.geometry.getAttribute("position")!;
                expect.that(Math.abs(qp.getX(0) * 0.9 - 0.85) < 1e-4).is(true);
                expect.that(Math.abs(q.geometry.getAttribute("uv")!.getX(13) - 1 / 24) < 1e-4).is(true);
                const morph = q.geometry.morphAttributes.get("position");
                expect.that(morph.length).is(1);
                expect.that(Math.abs(morph[0].getY(0) - 0.5) < 1e-6).is(true);
                expect.that(Math.abs(morph[0].getX(5) - 0.25) < 1e-6).is(true);
                expect.that(Math.abs(morph[0].getZ(77) + 1) < 1e-6).is(true);
                expect.that(morph[0].getY(1)).is(0);
                expect.that(q.morphTargetInfluences[0]).is(1);
            });
            test("instancing, materials and a quaternion-filtered track", (expect) => {
                const bytes = this.blob("features");
                if (bytes == null) return;
                const gltf = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder).parse(bytes!);
                if (gltf == null) return;
                const row = find(gltf.scene, "Row");
                expect.that(row instanceof THREE.InstancedMesh).is(true);
                const im = row as THREE.InstancedMesh;
                expect.that(im.count).is(5);
                const m = new THREE.Matrix4();
                im.getMatrixAt(4, m);
                expect.that(Math.abs(m.elements[12] - 3.2) < 1e-6).is(true);
                expect.that(Math.abs(m.elements[0] - 0.5) < 1e-6).is(true);
                const c = new THREE.Color();
                im.getColorAt(1, c);
                expect.that(Math.abs(c.g - 0.8) < 1e-6).is(true);

                const glass = (find(gltf.scene, "Glass") as THREE.Mesh).material as THREE.MeshPhysicalMaterial;
                expect.that(glass.transmission).is(1);
                expect.that(Math.abs(glass.thickness - 0.4) < 1e-9).is(true);
                expect.that(Math.abs(glass.attenuationDistance - 0.8) < 1e-9).is(true);
                expect.that(Math.abs(glass.attenuationColor.g - 0.9) < 1e-9).is(true);
                expect.that(Math.abs(glass.ior - 1.45) < 1e-9).is(true);
                expect.that(Math.abs(glass.dispersion - 0.3) < 1e-9).is(true);
                const pearl = (find(gltf.scene, "Quantized") as THREE.Mesh).material as THREE.MeshPhysicalMaterial;
                expect.that(pearl.iridescence).is(1);
                expect.that(pearl.iridescenceThicknessRange[1]).is(600);
                expect.that(Math.abs(pearl.specularIntensity - 0.8) < 1e-9).is(true);
                const brushed = im.material as THREE.MeshPhysicalMaterial;
                expect.that(Math.abs(brushed.anisotropy - 0.8) < 1e-9).is(true);

                expect.that(gltf.animations.length).is(1);
                const track = gltf.animations[0].tracks[0];
                // Key 1: a quarter turn about y, (0, sin 45, 0, cos 45).
                expect.that(Math.abs(track.values[5] - Math.SQRT1_2) < 1e-3).is(true);
                expect.that(Math.abs(track.values[7] - Math.SQRT1_2) < 1e-3).is(true);
                expect.that(Math.abs(track.values[4]) < 1e-3).is(true);
            });
            test("decodeGLTF (the loadAsync job) matches parse", (expect) => {
                const bytes = this.blob("features");
                if (bytes == null) return;
                const decoded = decodeGLTF(bytes!, true, [], [], false);
                expect.that(decoded.error).is("");
                expect.that(decoded.blob != null).is(true);
                expect.that(decoded.offsets.length > 10).is(true);
                const loader = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder);
                const gd = new GLTFData(bytes!, null);   // no decoder: everything comes decoded
                gd.setDecoded(decoded);
                const a = loader.parseData(gd);
                expect.that(loader.error).is("");
                const b = loader.parse(bytes!);
                if (a == null || b == null) return;
                const pa = (find(a.scene, "Glass") as THREE.Mesh).geometry.getAttribute("position")!;
                const pb = (find(b.scene, "Glass") as THREE.Mesh).geometry.getAttribute("position")!;
                expect.that(pa._blob != null).is(true);
                let same = pa.count == pb.count;
                for (let i = 0; i < pa.array.length && same; i++) if (pa.array[i] != pb.array[i]) same = false;
                expect.that(same).is(true);
                const ia = (find(a.scene, "Glass") as THREE.Mesh).geometry.index!;
                expect.that(ia.count).is(576 * 3);
                expect.that(a.animations[0].tracks[0].values.length).is(20);
            });
            test("malformed GLB chunk length fails cleanly", (expect) => {
                const bad = new ArrayBuffer(28);
                const dv = new DataView(bad);
                dv.setUint32(0, 0x46546C67, true);   // glTF
                dv.setUint32(4, 2, true);            // version 2
                dv.setUint32(8, 28, true);           // total length
                dv.setUint32(12, 0xFFFFFFF8, true);  // huge chunk length
                dv.setUint32(16, 0x4E4F534A, true);  // JSON
                const loader = new GLTFLoader();
                expect.that(loader.parse(bad) == null).is(true);
                expect.that(loader.error.length > 0).is(true);
            });
            test(".gltf JSON with a base64 buffer", (expect) => {
                const bytes = this.blob("features_embedded");
                if (bytes == null) return;
                const loader = new GLTFLoader();
                const gltf = loader.parse(bytes!);
                expect.that(loader.error).is("");
                if (gltf == null) return;
                const tri = find(gltf.scene, "Triangle") as THREE.Mesh;
                const p = tri.geometry.getAttribute("position")!;
                expect.that(p.getX(1)).is(1);
                expect.that(p.getY(2)).is(1);
                expect.that(tri.geometry.getAttribute("color")!.getZ(2)).is(1);
            });
            test("multi-primitive and joint-attached morph target animations bind and TANGENT attribute loads", (expect) => {
                // Pack 3 positions (36 B), 3 morph deltas (36 B), 3 tangents VEC4 (48 B),
                // 2 anim times [0, 1] (8 B), 2 anim weights [0, 1] (8 B) = 136 bytes.
                const f = new Float32Array(34);
                // positions (0..8): triangle (0,0,0), (1,0,0), (0,1,0)
                f[3] = 1; f[7] = 1;
                // morph delta (9..17): +1 on Z for all 3 vertices
                f[11] = 1; f[14] = 1; f[17] = 1;
                // tangents (18..29): (1,0,0,1), (0,1,0,-1), (0,0,1,1)
                f[18] = 1; f[21] = 1;
                f[23] = 1; f[25] = -1;
                f[28] = 1; f[29] = 1;
                // anim times (30..31): 0, 1
                f[30] = 0; f[31] = 1;
                // anim weights (32..33): 0, 1
                f[32] = 0; f[33] = 1;
                const uri = "data:application/octet-stream;base64," + base64Encode(Uint8Array.wrap(f.buffer));
                const doc = '{"asset":{"version":"2.0"},'
                    + '"buffers":[{"uri":"' + uri + '","byteLength":136}],'
                    + '"bufferViews":['
                    + '{"buffer":0,"byteOffset":0,"byteLength":36},'
                    + '{"buffer":0,"byteOffset":36,"byteLength":36},'
                    + '{"buffer":0,"byteOffset":72,"byteLength":48},'
                    + '{"buffer":0,"byteOffset":120,"byteLength":8},'
                    + '{"buffer":0,"byteOffset":128,"byteLength":8}],'
                    + '"accessors":['
                    + '{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},'
                    + '{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},'
                    + '{"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"},'
                    + '{"bufferView":3,"componentType":5126,"count":2,"type":"SCALAR"},'
                    + '{"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR"}],'
                    + '"meshes":['
                    + '{"primitives":['
                    + '{"attributes":{"POSITION":0,"TANGENT":2},"targets":[{"POSITION":1}]},'
                    + '{"attributes":{"POSITION":0},"targets":[{"POSITION":1}]}]},'
                    + '{"primitives":[{"attributes":{"POSITION":0},"targets":[{"POSITION":1}]}]}],'
                    + '"skins":[{"joints":[1]}],'
                    + '"nodes":['
                    + '{"name":"MultiFace","mesh":0},'
                    + '{"name":"JointFace","mesh":1}],'
                    + '"scenes":[{"nodes":[0,1]}],"scene":0,'
                    + '"animations":[{"name":"MorphAll",'
                    + '"samplers":[{"input":3,"output":4}],'
                    + '"channels":['
                    + '{"sampler":0,"target":{"node":0,"path":"weights"}},'
                    + '{"sampler":0,"target":{"node":1,"path":"weights"}}]}]}';
                const loader = new GLTFLoader();
                const gltf = loader.parse(String.UTF8.encode(doc));
                expect.that(loader.error).is("");
                expect.that(gltf != null).is(true);
                if (gltf == null) return;
                // Node 0: Group holding 2 uniquely-named Mesh primitives.
                const multi = find(gltf.scene, "MultiFace")!;
                expect.that(multi.children.length).is(2);
                const m0 = multi.children[0] as THREE.Mesh;
                const m1 = multi.children[1] as THREE.Mesh;
                expect.that(m0.name != multi.name && m1.name != multi.name && m0.name != m1.name).is(true);
                // TANGENT attribute loaded on primitive 0.
                const tan = m0.geometry.getAttribute("tangent");
                expect.that(tan != null).is(true);
                if (tan != null) {
                    expect.that(tan.itemSize).is(4);
                    expect.that(tan.count).is(3);
                    expect.that(tan.getX(0) == 1 && tan.getW(0) == 1).is(true);
                    expect.that(tan.getY(1) == 1 && tan.getW(1) == -1).is(true);
                }
                // Node 1: Bone (joint) holding 1 uniquely-named Mesh child.
                const joint = find(gltf.scene, "JointFace")!;
                expect.that(joint instanceof THREE.Bone).is(true);
                expect.that(joint.children.length).is(1);
                const jm = joint.children[0] as THREE.Mesh;
                expect.that(jm.name != joint.name).is(true);
                // Playing the clip animates BOTH multi-primitive meshes AND the joint-attached mesh!
                const mixer = new THREE.AnimationMixer(gltf.scene);
                mixer.clipAction(gltf.animations[0]).play();
                mixer.update(0.5);
                expect.that(Math.abs(m0.morphTargetInfluences[0] - 0.5) < 1e-4).is(true);
                expect.that(Math.abs(m1.morphTargetInfluences[0] - 0.5) < 1e-4).is(true);
                expect.that(Math.abs(jm.morphTargetInfluences[0] - 0.5) < 1e-4).is(true);
            });
        });
    }
}
