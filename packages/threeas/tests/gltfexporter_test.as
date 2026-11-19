// GLTFExporter (M11d): scenes written as .glb / .gltf and read back with
// the project's GLTFLoader: rive . --test

import { Tests } from "rive/test";
import { Dynamic } from "rive/dynamic";
import * as THREE from "../three/Three";
import { jget, jat, jnum, jstr, jarr } from "../three/core/JSON";
import { GLTFExporter, GLTFExporterResult, GLTFExporterPlugin, encodePNG } from "../three/addons/exporters/GLTFExporter";
import { GLTFLoader, GLTF } from "../three/addons/loaders/GLTFLoader";
import { MeshoptDecoder } from "../three/addons/libs/meshopt_decoder";
import { unzlibSync } from "../three/addons/libs/fflate";

function near(a: f64, b: f64, eps: f64 = 1e-5): bool {
    return Math.abs(a - b) <= eps;
}

/// Reads the .glb back (or the .gltf text), failing loudly in the result.
function reload(result: GLTFExporterResult): GLTF? {
    const loader = new GLTFLoader();
    const glb = result.glb;
    if (glb != null) return loader.parse(glb);
    return loader.parse(String.UTF8.encode(result.json));
}

function find(root: THREE.Object3D, name: string): THREE.Object3D? {
    return root.getObjectByName(name);
}

/// Bytes of bufferView `index` of a .glb.
function viewBytes(glb: ArrayBuffer, gltf: Dynamic, index: i32): Uint8Array {
    const b = Uint8Array.wrap(glb);
    const jsonLength = <i32>(<u32>b[12] | (<u32>b[13] << 8) | (<u32>b[14] << 16) | (<u32>b[15] << 24));
    const bin = 20 + jsonLength + 8;
    const view = jat(jget(gltf, "bufferViews"), index);
    const offset = <i32>jnum(view, "byteOffset", 0);
    return b.subarray(bin + offset, bin + offset + <i32>jnum(view, "byteLength", 0));
}

function u32BE(b: Uint8Array, o: i32): u32 {
    return (<u32>b[o] << 24) | (<u32>b[o + 1] << 16) | (<u32>b[o + 2] << 8) | <u32>b[o + 3];
}

function strings(value: Dynamic?): Array<string> {
    const out: Array<string> = [];
    const items = Dynamic.asArrayOrNull(value);
    if (items == null) return out;
    for (let i = 0; i < items.length; i++) out.push(Dynamic.asString(items[i]));
    return out;
}

/// A quad: positions, normals, uvs, colours and an index.
function quadGeometry(): THREE.BufferGeometry {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0], 3));
    g.setAttribute("normal", new THREE.Float32BufferAttribute([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1], 3));
    g.setAttribute("uv", new THREE.Float32BufferAttribute([0, 0, 1, 0, 1, 1, 0, 1], 2));
    g.setAttribute("color", new THREE.Float32BufferAttribute([1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1], 3));
    g.setIndex([0, 1, 2, 0, 2, 3]);
    return g;
}

function sceneWithHierarchy(): THREE.Scene {
    const scene = new THREE.Scene();
    scene.name = "World";
    const root = new THREE.Group();
    root.name = "Root";
    root.position.set(1, 2, 3);
    root.rotation.set(0, Math.PI / 2, 0);
    scene.add(root);
    const mesh = new THREE.Mesh(quadGeometry(), new THREE.MeshStandardMaterial({ color: 0xff0000, roughness: 0.25, metalness: 0.5 }));
    mesh.name = "Quad";
    mesh.scale.set(2, 2, 2);
    root.add(mesh);
    const hidden = new THREE.Mesh(quadGeometry(), new THREE.MeshStandardMaterial());
    hidden.name = "Hidden";
    hidden.visible = false;
    root.add(hidden);
    return scene;
}

export class GLTFExporterTests extends Tests {
    override run(): void {
        group("GLTFExporter", () => {
            test("hierarchy, transforms, uvs, colours and an index", (expect) => {
                const scene = sceneWithHierarchy();
                const result = new GLTFExporter().parse(scene, { binary: true });
                expect.that(result.glb != null).is(true);
                // Invisible objects are left out; matrices by default.
                const nodes = jarr(result.gltf, "nodes");
                expect.that(nodes.length).is(2);
                expect.that(jget(nodes[0], "matrix") != null).is(true);
                expect.that(jstr(jat(jget(result.gltf, "scenes"), 0), "name", "")).is("World");
                // The index fits 16 bits.
                const prim = jat(jget(jat(jget(result.gltf, "meshes"), 0), "primitives"), 0);
                const indices = jat(jget(result.gltf, "accessors"), <i32>jnum(prim, "indices", -1));
                expect.that(jnum(indices, "componentType", 0)).is(5123);
                expect.that(jnum(jget(prim, "attributes"), "COLOR_0", -1) >= 0).is(true);

                const gltf = reload(result);
                expect.that(gltf != null).is(true);
                if (gltf == null) return;
                const root = find(gltf.scene, "Root");
                const quad = find(gltf.scene, "Quad");
                expect.that(root != null && quad != null).is(true);
                expect.that(find(gltf.scene, "Hidden") == null).is(true);
                if (root == null || quad == null) return;
                expect.that(quad.parent === root).is(true);
                expect.that(near(root.position.x, 1) && near(root.position.y, 2) && near(root.position.z, 3)).is(true);
                expect.that(near(root.rotation.y, Math.PI / 2, 1e-4)).is(true);
                expect.that(near(quad.scale.x, 2) && near(quad.scale.z, 2)).is(true);
                const g = (quad as THREE.Mesh).geometry;
                expect.that(g.getAttribute("position")!.count).is(4);
                expect.that(near(g.getAttribute("uv")!.getX(2), 1) && near(g.getAttribute("uv")!.getY(2), 1)).is(true);
                expect.that(near(g.getAttribute("color")!.getZ(2), 1) && near(g.getAttribute("color")!.getX(2), 0)).is(true);
                expect.that(g.index!.count).is(6);
                expect.that(g.index!.getX(5)).is(3);
                const m = (quad as THREE.Mesh).material as THREE.MeshStandardMaterial;
                expect.that(near(m.color.r, 1) && near(m.color.g, 0)).is(true);
                expect.that(near(m.roughness, 0.25) && near(m.metalness, 0.5)).is(true);
            });
            test("trs and onlyVisible options", (expect) => {
                const scene = sceneWithHierarchy();
                const result = new GLTFExporter().parse(scene, { trs: true, onlyVisible: false });
                const nodes = jarr(result.gltf, "nodes");
                expect.that(nodes.length).is(3);
                // Post-order: the root is written last.
                const root = nodes[2];
                expect.that(jstr(root, "name", "")).is("Root");
                expect.that(jget(root, "matrix") == null).is(true);
                const t = Dynamic.asNumbers(jget(root, "translation"));
                expect.that(t[0] == 1 && t[1] == 2 && t[2] == 3).is(true);
                expect.that(Dynamic.asNumbers(jget(nodes[0], "scale"))[1]).is(2);
                // Objects without a scene go in "AuxScene".
                const quad = new THREE.Mesh(quadGeometry(), new THREE.MeshStandardMaterial());
                const objects: Array<THREE.Object3D> = [quad, new THREE.Group()];
                const aux = new GLTFExporter().parse(objects);
                expect.that(jstr(jat(jget(aux.gltf, "scenes"), 0), "name", "")).is("AuxScene");
                expect.that(jarr(aux.gltf, "nodes").length).is(2);
                expect.that(quad.parent == null).is(true);
                // An empty node is an object.
                expect.that(aux.json.includes("\"nodes\":[{\"mesh\":0},{}]")).is(true);
            });
            test("multi-material meshes write a primitive per group", (expect) => {
                const g = quadGeometry();
                g.addGroup(0, 3, 0);
                g.addGroup(3, 3, 1);
                const mesh = new THREE.Mesh(g);
                mesh.name = "Two";
                mesh.materials = [new THREE.MeshStandardMaterial({ color: 0xff0000 }), new THREE.MeshStandardMaterial({ color: 0x0000ff })];
                const scene = new THREE.Scene();
                scene.add(mesh);
                const result = new GLTFExporter().parse(scene, { binary: true });
                const prims = jarr(jat(jget(result.gltf, "meshes"), 0), "primitives");
                expect.that(prims.length).is(2);
                expect.that(jnum(prims[0], "material", -1)).is(0);
                expect.that(jnum(prims[1], "material", -1)).is(1);
                // Both share the attributes.
                expect.that(jnum(jget(prims[0], "attributes"), "POSITION", -1)).is(jnum(jget(prims[1], "attributes"), "POSITION", -2));
                const gltf = reload(result);
                if (gltf == null) {
                    expect.that(false).is(true);
                    return;
                }
                const two = find(gltf.scene, "Two")!;
                expect.that(two.children.length).is(2);
                const a = two.children[0] as THREE.Mesh, b = two.children[1] as THREE.Mesh;
                expect.that(a.geometry.index!.count).is(3);
                expect.that(b.geometry.index!.getX(2)).is(3);
                expect.that(near((a.material as THREE.MeshStandardMaterial).color.r, 1)).is(true);
                expect.that(near((b.material as THREE.MeshStandardMaterial).color.b, 1)).is(true);
                expect.that(near((b.material as THREE.MeshStandardMaterial).color.r, 0)).is(true);
                // Without groups a multi-material mesh is left out, as three.js.
                const bare = new THREE.Mesh(quadGeometry());
                bare.materials = [new THREE.MeshStandardMaterial()];
                const s2 = new THREE.Scene();
                s2.add(bare);
                expect.that(jget(new GLTFExporter().parse(s2).gltf, "meshes") == null).is(true);
            });
            test("morph targets with names and weights", (expect) => {
                const g = quadGeometry();
                const smile = new THREE.Float32BufferAttribute([0, 1, 0, 1, 1, 0, 1, 2, 0, 0, 2, 0], 3);
                smile.name = "smile";
                const frown = new THREE.Float32BufferAttribute([0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1], 3);
                frown.name = "frown";
                g.morphAttributes.set("position", [smile, frown]);
                const mesh = new THREE.Mesh(g, new THREE.MeshStandardMaterial());
                mesh.name = "Face";
                mesh.updateMorphTargets();
                mesh.morphTargetInfluences[0] = 0.25;
                mesh.morphTargetInfluences[1] = 0.5;
                const scene = new THREE.Scene();
                scene.add(mesh);
                const result = new GLTFExporter().parse(scene, { binary: true });
                const meshDef = jat(jget(result.gltf, "meshes"), 0);
                const names = strings(jget(jget(meshDef, "extras"), "targetNames"));
                expect.that(names.length == 2 && names[0] == "smile" && names[1] == "frown").is(true);
                const weights = Dynamic.asNumbers(jget(meshDef, "weights"));
                expect.that(weights[0] == 0.25 && weights[1] == 0.5).is(true);
                const gltf = reload(result);
                if (gltf == null) {
                    expect.that(false).is(true);
                    return;
                }
                const face = find(gltf.scene, "Face") as THREE.Mesh;
                expect.that(face.morphTargetDictionary.get("frown")).is(1);
                expect.that(near(face.morphTargetInfluences[1], 0.5)).is(true);
                // glTF targets are offsets from the base.
                const target = face.geometry.morphAttributes.get("position")[0];
                expect.that(face.geometry.morphTargetsRelative).is(true);
                expect.that(near(target.getY(0), 1) && near(target.getY(2), 1) && near(target.getX(2), 0)).is(true);
            });
            test("a skinned mesh with its skeleton", (expect) => {
                const g = quadGeometry();
                g.setAttribute("skinIndex", new THREE.Float32BufferAttribute([0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], 4));
                g.setAttribute("skinWeight", new THREE.Float32BufferAttribute([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], 4));
                const mesh = new THREE.SkinnedMesh(g, new THREE.MeshStandardMaterial());
                mesh.name = "Skin";
                const hip = new THREE.Bone();
                hip.name = "Hip";
                const knee = new THREE.Bone();
                knee.name = "Knee";
                knee.position.set(0, 1, 0);
                hip.add(knee);
                mesh.add(hip);
                const scene = new THREE.Scene();
                scene.add(mesh);
                scene.updateMatrixWorld(true);
                mesh.bind(new THREE.Skeleton([hip, knee]));
                const result = new GLTFExporter().parse(scene, { binary: true });
                const skins = jarr(result.gltf, "skins");
                expect.that(skins.length).is(1);
                expect.that(Dynamic.asNumbers(jget(skins[0], "joints")).length).is(2);
                const prim = jat(jget(jat(jget(result.gltf, "meshes"), 0), "primitives"), 0);
                const joints = jat(jget(result.gltf, "accessors"), <i32>jnum(jget(prim, "attributes"), "JOINTS_0", -1));
                expect.that(jnum(joints, "componentType", 0)).is(5123);
                const ibm = jat(jget(result.gltf, "accessors"), <i32>jnum(skins[0], "inverseBindMatrices", -1));
                expect.that(jstr(ibm, "type", "")).is("MAT4");
                const gltf = reload(result);
                if (gltf == null) {
                    expect.that(false).is(true);
                    return;
                }
                const skin = find(gltf.scene, "Skin");
                expect.that(skin instanceof THREE.SkinnedMesh).is(true);
                const skeleton = (skin as THREE.SkinnedMesh).skeleton!;
                expect.that(skeleton.bones.length).is(2);
                expect.that(skeleton.bones[1].name).is("Knee");
                expect.that(skeleton.bones[1].parent === skeleton.bones[0]).is(true);
                // The knee's inverse bind matrix moves it back down.
                expect.that(near(<f64>skeleton.boneInverses[1].elements[13], -1)).is(true);
                expect.that(near((skin as THREE.Mesh).geometry.getAttribute("skinIndex")!.getX(2), 1)).is(true);
            });
            test("physical extensions and an unlit material", (expect) => {
                const physical = new THREE.MeshPhysicalMaterial();
                physical.name = "Fancy";
                physical.clearcoat = 0.75;
                physical.clearcoatRoughness = 0.2;
                physical.transmission = 0.5;
                physical.thickness = 1.5;
                physical.attenuationColor.setRGB(1, 0.5, 0.25);
                physical.ior = 1.33;
                physical.specularIntensity = 0.5;
                physical.sheen = 1;
                physical.sheenColor.setRGB(0.25, 0, 0);
                physical.sheenRoughness = 0.4;
                physical.iridescence = 1;
                physical.iridescenceIOR = 1.5;
                physical.anisotropy = 0.3;
                physical.anisotropyRotation = 0.1;
                physical.dispersion = 0.2;
                physical.emissive.setRGB(1, 1, 0);
                physical.emissiveIntensity = 3;
                physical.bumpScale = 2;
                physical.side = THREE.DoubleSide;
                physical.alphaTest = 0.5;
                const basic = new THREE.MeshBasicMaterial({ color: 0x00ff00 });
                basic.name = "Flat";
                basic.transparent = true;
                basic.opacity = 0.5;
                const scene = new THREE.Scene();
                const a = new THREE.Mesh(quadGeometry(), physical);
                a.name = "A";
                const b = new THREE.Mesh(quadGeometry(), basic);
                b.name = "B";
                scene.add(a);
                scene.add(b);
                const result = new GLTFExporter().parse(scene, { binary: true });
                const used = strings(jget(result.gltf, "extensionsUsed"));
                const want: StaticArray<string> = ["KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_ior",
                    "KHR_materials_specular", "KHR_materials_clearcoat", "KHR_materials_dispersion",
                    "KHR_materials_iridescence", "KHR_materials_sheen", "KHR_materials_anisotropy",
                    "KHR_materials_emissive_strength", "EXT_materials_bump", "KHR_materials_unlit"];
                let all = true;
                for (let i = 0; i < want.length; i++) if (used.indexOf(want[i]) < 0) all = false;
                expect.that(all).is(true);
                // Three.js's plugin order inside a material.
                const ext = jget(jat(jget(result.gltf, "materials"), 0), "extensions");
                expect.that(Dynamic.asMap(ext).keys()[0]).is("KHR_materials_transmission");
                expect.that(result.json.includes("\"KHR_materials_unlit\":{}")).is(true);
                const flat = jat(jget(result.gltf, "materials"), 1);
                expect.that(jnum(jget(flat, "pbrMetallicRoughness"), "roughnessFactor", 0)).is(0.9);
                expect.that(jstr(flat, "alphaMode", "")).is("BLEND");

                const gltf = reload(result);
                if (gltf == null) {
                    expect.that(false).is(true);
                    return;
                }
                const pm = (find(gltf.scene, "A") as THREE.Mesh).material;
                expect.that(pm instanceof THREE.MeshPhysicalMaterial).is(true);
                const p = pm as THREE.MeshPhysicalMaterial;
                expect.that(p.name).is("Fancy");
                expect.that(near(p.clearcoat, 0.75) && near(p.clearcoatRoughness, 0.2)).is(true);
                expect.that(near(p.transmission, 0.5) && near(p.thickness, 1.5) && near(p.attenuationColor.g, 0.5)).is(true);
                expect.that(near(p.ior, 1.33) && near(p.specularIntensity, 0.5)).is(true);
                expect.that(near(p.sheenColor.r, 0.25) && near(p.sheenRoughness, 0.4)).is(true);
                expect.that(near(p.iridescence, 1) && near(p.iridescenceIOR, 1.5)).is(true);
                expect.that(near(p.anisotropy, 0.3) && near(p.anisotropyRotation, 0.1)).is(true);
                expect.that(near(p.dispersion, 0.2) && near(p.emissiveIntensity, 3) && near(p.emissive.g, 1)).is(true);
                expect.that(p.side).is(THREE.DoubleSide);
                expect.that(near(p.alphaTest, 0.5)).is(true);
                const bm = (find(gltf.scene, "B") as THREE.Mesh).material;
                expect.that(bm instanceof THREE.MeshBasicMaterial).is(true);
                expect.that(near((bm as THREE.MeshBasicMaterial).color.g, 1) && near(bm.opacity, 0.5)).is(true);
                expect.that(bm.transparent).is(true);
            });
            test("a DataTexture written as PNG", (expect) => {
                // 2 x 2 RGBA, bottom row first (flipY false: written as is).
                const pixels = new Uint8Array(16);
                const values: StaticArray<u8> = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128];
                for (let i = 0; i < 16; i++) pixels[i] = values[i];
                const texture = new THREE.DataTexture(pixels, 2, 2);
                texture.name = "Checker";
                texture.wrapS = THREE.RepeatWrapping;
                texture.wrapT = THREE.MirroredRepeatWrapping;
                texture.repeat.set(2, 3);
                const material = new THREE.MeshStandardMaterial();
                material.map = texture;
                material.normalMap = texture;   // the same image, written once
                const scene = new THREE.Scene();
                scene.add(new THREE.Mesh(quadGeometry(), material));
                const result = new GLTFExporter().parse(scene, { binary: true });
                const gltf = result.gltf;
                const images = jarr(gltf, "images");
                expect.that(images.length).is(1);
                expect.that(jstr(images[0], "mimeType", "")).is("image/png");
                const textures = jarr(gltf, "textures");
                expect.that(textures.length).is(1);
                expect.that(jstr(textures[0], "name", "")).is("Checker");
                expect.that(jnum(textures[0], "source", -1)).is(0);
                const sampler = jat(jget(gltf, "samplers"), <i32>jnum(textures[0], "sampler", -1));
                expect.that(jnum(sampler, "wrapS", 0)).is(10497);
                expect.that(jnum(sampler, "wrapT", 0)).is(33648);
                expect.that(jnum(sampler, "magFilter", 0)).is(9728);
                const info = jget(jget(jat(jget(gltf, "materials"), 0), "pbrMetallicRoughness"), "baseColorTexture");
                expect.that(jnum(info, "texCoord", -1)).is(0);
                const scale = Dynamic.asNumbers(jget(jget(jget(info, "extensions"), "KHR_texture_transform"), "scale"));
                expect.that(scale[0] == 2 && scale[1] == 3).is(true);
                expect.that(strings(jget(gltf, "extensionsUsed")).indexOf("KHR_texture_transform") >= 0).is(true);

                const png = viewBytes(result.glb!, gltf, <i32>jnum(images[0], "bufferView", -1));
                const signature: StaticArray<u8> = [137, 80, 78, 71, 13, 10, 26, 10];
                let signed = true;
                for (let i = 0; i < 8; i++) if (png[i] != signature[i]) signed = false;
                expect.that(signed).is(true);
                expect.that(u32BE(png, 8)).is(13);
                expect.that(u32BE(png, 12)).is(0x49484452);   // IHDR
                expect.that(u32BE(png, 16)).is(2);
                expect.that(u32BE(png, 20)).is(2);
                expect.that(<i32>png[24]).is(8);
                expect.that(<i32>png[25]).is(6);
                // IDAT inflates to the rows, each after a filter byte.
                const idatLength = <i32>u32BE(png, 33);
                expect.that(u32BE(png, 37)).is(0x49444154);
                const raw = unzlibSync(png.subarray(41, 41 + idatLength));
                expect.that(raw.length).is(18);
                expect.that(<i32>raw[0]).is(0);
                expect.that(<i32>raw[1]).is(255);
                expect.that(<i32>raw[10]).is(0);
                expect.that(<i32>raw[13]).is(255);   // second row: blue
                expect.that(<i32>raw[17]).is(128);
                // The .gltf has the image as a data: URI.
                const text = new GLTFExporter().parse(scene).gltf;
                expect.that(jstr(jat(jget(text, "images"), 0), "uri", "").startsWith("data:image/png;base64,iVBORw0KGgo")).is(true);
            });
            test("metalness and roughness maps merge; images without pixels", (expect) => {
                const metal = new Uint8Array(4 * 4), rough = new Uint8Array(4);
                for (let i = 0; i < 4; i++) metal[i * 4 + 2] = <u8>(i * 60);   // blue
                rough[1] = 200; rough[3] = 255;                                 // 1 x 1, green
                const material = new THREE.MeshStandardMaterial();
                material.metalnessMap = new THREE.DataTexture(metal, 2, 2);
                material.roughnessMap = new THREE.DataTexture(rough, 1, 1);
                material.emissiveMap = new THREE.Texture();   // a Rive image's place: no pixels
                const fromUrl = new THREE.Texture();
                fromUrl.source.url = "data:image/png;base64,iVBORw0KGgo=";
                material.aoMap = fromUrl;
                const scene = new THREE.Scene();
                scene.add(new THREE.Mesh(quadGeometry(), material));
                const result = new GLTFExporter().parse(scene, { binary: true });
                const gltf = result.gltf;
                expect.that(jarr(gltf, "images").length).is(2);
                const def = jat(jget(gltf, "materials"), 0);
                expect.that(jget(def, "emissiveTexture") == null).is(true);
                expect.that(jnum(jget(def, "occlusionTexture"), "index", -1)).is(1);
                const url = jat(jget(gltf, "images"), 1);
                expect.that(jstr(url, "mimeType", "")).is("image/png");
                const urlBytes = viewBytes(result.glb!, gltf, <i32>jnum(url, "bufferView", -1));
                expect.that(<i32>urlBytes[1]).is(80);   // "P" of the PNG signature
                let warned = false;
                for (let i = 0; i < result.warnings.length; i++) if (result.warnings[i].includes("without pixels")) warned = true;
                expect.that(warned).is(true);
                // The merged texture: 2 x 2, blue from metalness, green from roughness.
                const mr = jget(jget(def, "pbrMetallicRoughness"), "metallicRoughnessTexture");
                const image = jat(jget(gltf, "images"), <i32>jnum(jat(jget(gltf, "textures"), <i32>jnum(mr, "index", -1)), "source", -1));
                const png = viewBytes(result.glb!, gltf, <i32>jnum(image, "bufferView", -1));
                expect.that(u32BE(png, 16)).is(2);
                const raw = unzlibSync(png.subarray(41, 41 + <i32>u32BE(png, 33)));
                expect.that(<i32>raw[1]).is(0);
                expect.that(<i32>raw[2]).is(200);
                expect.that(<i32>raw[3 + 4]).is(60);
                expect.that(<i32>raw[1 + 9 + 4 + 2]).is(180);
            });
            test("userData as extras, custom extensions and plugins", (expect) => {
                const scene = new THREE.Scene();
                const mesh = new THREE.Mesh(quadGeometry(), new THREE.MeshStandardMaterial());
                mesh.userData.set("hp", Dynamic.fromNumber(3));
                const custom = Dynamic.newTable();
                const ext = Dynamic.newTable();
                ext.set("level", Dynamic.fromNumber(2));
                custom.set("VENDOR_thing", ext);
                mesh.userData.set("gltfExtensions", custom);
                mesh.material.userData.set("tag", Dynamic.fromString("shiny"));
                scene.add(mesh);
                const exporter = new GLTFExporter();
                const plugin = new NodeCounter();
                exporter.register(plugin);
                const result = exporter.parse(scene, { includeCustomExtensions: true });
                const node = jat(jget(result.gltf, "nodes"), 0);
                expect.that(jnum(jget(node, "extras"), "hp", 0)).is(3);
                expect.that(jget(jget(node, "extras"), "gltfExtensions") == null).is(true);
                expect.that(jnum(jget(jget(node, "extensions"), "VENDOR_thing"), "level", 0)).is(2);
                expect.that(strings(jget(result.gltf, "extensionsUsed")).indexOf("VENDOR_thing") >= 0).is(true);
                expect.that(jstr(jget(jat(jget(result.gltf, "materials"), 0), "extras"), "tag", "")).is("shiny");
                expect.that(plugin.nodes).is(1);
                expect.that(jnum(jget(jget(node, "extensions"), "TEST_counter"), "n", 0)).is(1);
                // Without the option, gltfExtensions stay in extras; unregistered, the plugin is not run.
                exporter.unregister(plugin);
                const plain = exporter.parse(scene);
                const plainNode = jat(jget(plain.gltf, "nodes"), 0);
                expect.that(jget(jget(plainNode, "extras"), "gltfExtensions") != null).is(true);
                expect.that(jget(plainNode, "extensions") == null).is(true);
                expect.that(plugin.nodes).is(1);
            });
            test("PNG rows flip with flipY and unpremultiply", (expect) => {
                const pixels = new Uint8Array(8);
                pixels[0] = 10; pixels[3] = 255;          // row 0
                pixels[4] = 64; pixels[7] = 128;          // row 1: half alpha, premultiplied
                const png = encodePNG(pixels, 1, 2, true, true);
                const raw = unzlibSync(png.subarray(41, 41 + <i32>u32BE(png, 33)));
                expect.that(<i32>raw[1]).is(128);   // row 1 first, 64 / 0.5
                expect.that(<i32>raw[4]).is(128);
                expect.that(<i32>raw[6]).is(10);
                // The CRC of IEND is the well-known AE426082.
                expect.that(u32BE(png, png.length - 4)).is(0xAE426082);
            });
            test("a camera, a spot light and an InstancedMesh with colours", (expect) => {
                const scene = new THREE.Scene();
                const camera = new THREE.PerspectiveCamera(50, 1.5, 0.1, 100);
                camera.name = "Cam";
                camera.position.set(0, 0, 5);
                scene.add(camera);
                const spot = new THREE.SpotLight(0xffffff, 3, 10, Math.PI / 6, 0.5, 2);
                spot.name = "Spot";
                spot.add(spot.target);
                spot.target.position.set(0, 0, -1);
                scene.add(spot);
                const instanced = new THREE.InstancedMesh(quadGeometry(), new THREE.MeshStandardMaterial(), 3);
                instanced.name = "Many";
                const m = new THREE.Matrix4();
                const c = new THREE.Color();
                for (let i = 0; i < 3; i++) {
                    instanced.setMatrixAt(i, m.makeTranslation(<f64>i * 2, 0, 0));
                    instanced.setColorAt(i, c.setRGB(<f64>i / 2, 0, 1));
                }
                scene.add(instanced);
                const result = new GLTFExporter().parse(scene, { binary: true });
                expect.that(result.warnings.length).is(0);
                const cam = jat(jget(result.gltf, "cameras"), 0);
                expect.that(jstr(cam, "type", "")).is("perspective");
                expect.that(near(jnum(jget(cam, "perspective"), "yfov", 0), 50 * Math.PI / 180)).is(true);
                const light = jat(jget(jget(jget(result.gltf, "extensions"), "KHR_lights_punctual"), "lights"), 0);
                expect.that(jstr(light, "type", "")).is("spot");
                expect.that(near(jnum(jget(light, "spot"), "innerConeAngle", 0), Math.PI / 12)).is(true);
                expect.that(jnum(light, "range", 0)).is(10);
                expect.that(strings(jget(result.gltf, "extensionsRequired")).indexOf("EXT_mesh_gpu_instancing") >= 0).is(true);

                const gltf = reload(result);
                if (gltf == null) {
                    expect.that(false).is(true);
                    return;
                }
                expect.that(gltf.cameras.length).is(1);
                const pc = gltf.cameras[0] as THREE.PerspectiveCamera;
                expect.that(near(pc.fov, 50) && near(pc.aspect, 1.5) && near(pc.far, 100)).is(true);
                let spotLight: THREE.SpotLight? = null;
                const node = find(gltf.scene, "Spot")!;
                if (node instanceof THREE.SpotLight) spotLight = node as THREE.SpotLight;
                expect.that(spotLight != null).is(true);
                if (spotLight != null) {
                    expect.that(near(spotLight.angle, Math.PI / 6) && near(spotLight.penumbra, 0.5)).is(true);
                    expect.that(near(spotLight.intensity, 3) && near(spotLight.distance, 10)).is(true);
                }
                const many = find(gltf.scene, "Many");
                expect.that(many instanceof THREE.InstancedMesh).is(true);
                const im = many as THREE.InstancedMesh;
                expect.that(im.count).is(3);
                im.getMatrixAt(2, m);
                expect.that(near(<f64>m.elements[12], 4)).is(true);
                im.getColorAt(1, c);
                expect.that(near(c.r, 0.5) && near(c.b, 1)).is(true);
            });
            test("an animation clip with position, quaternion and morph tracks", (expect) => {
                const g = quadGeometry();
                const smile = new THREE.Float32BufferAttribute([0, 1, 0, 1, 1, 0, 1, 2, 0, 0, 2, 0], 3);
                smile.name = "smile";
                const frown = new THREE.Float32BufferAttribute([0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1], 3);
                frown.name = "frown";
                g.morphAttributes.set("position", [smile, frown]);
                const mesh = new THREE.Mesh(g, new THREE.MeshStandardMaterial());
                mesh.name = "Face";
                mesh.updateMorphTargets();
                const scene = new THREE.Scene();
                scene.add(mesh);
                const tracks: Array<THREE.KeyframeTrack> = [
                    new THREE.VectorKeyframeTrack("Face.position", [0, 1], [0, 0, 0, 0, 2, 0]),
                    new THREE.QuaternionKeyframeTrack("Face.quaternion", [0, 2], [0, 0, 0, 1, 0, 1, 0, 0]),
                    new THREE.NumberKeyframeTrack("Face.morphTargetInfluences[smile]", [0, 1], [0, 1]),
                    new THREE.NumberKeyframeTrack("Face.morphTargetInfluences[frown]", [0.5, 2], [1, 0]),
                    new THREE.VectorKeyframeTrack("Nobody.position", [0], [0, 0, 0]),
                ];
                const clip = new THREE.AnimationClip("Wave", -1, tracks);
                const result = new GLTFExporter().parse(scene, { binary: true, animations: [clip] });
                // Animations force TRS.
                expect.that(jget(jat(jget(result.gltf, "nodes"), 0), "matrix") == null).is(true);
                const anim = jat(jget(result.gltf, "animations"), 0);
                expect.that(jstr(anim, "name", "")).is("Wave");
                const channels = jarr(anim, "channels");
                expect.that(channels.length).is(3);
                expect.that(jstr(jget(channels[2], "target"), "path", "")).is("weights");
                expect.that(result.warnings.length).is(1);   // Nobody.position
                // The clip itself is left as it was.
                expect.that(clip.tracks.length).is(5);
                const sampler = jat(jget(anim, "samplers"), 2);
                const input = jat(jget(result.gltf, "accessors"), <i32>jnum(sampler, "input", -1));
                const output = jat(jget(result.gltf, "accessors"), <i32>jnum(sampler, "output", -1));
                expect.that(jnum(input, "count", 0)).is(4);   // 0, 0.5, 1, 2
                expect.that(jnum(output, "count", 0)).is(8);

                const gltf = reload(result);
                if (gltf == null) {
                    expect.that(false).is(true);
                    return;
                }
                expect.that(gltf.animations.length).is(1);
                const loaded = gltf.animations[0];
                let position: THREE.KeyframeTrack? = null;
                let frownTrack: THREE.KeyframeTrack? = null;
                let rotation: THREE.KeyframeTrack? = null;
                for (let i = 0; i < loaded.tracks.length; i++) {
                    const t = loaded.tracks[i];
                    if (t.name == "Face.position") position = t;
                    if (t.name == "Face.quaternion") rotation = t;
                    if (t.name == "Face.morphTargetInfluences[1]") frownTrack = t;
                }
                expect.that(position != null && rotation != null && frownTrack != null).is(true);
                if (position == null || rotation == null || frownTrack == null) return;
                expect.that(near(<f64>position.values[4], 2)).is(true);
                expect.that(near(<f64>rotation.values[5], 1)).is(true);
                // frown: 0 before its first key at 0.5 (held), 1 at 0.5, 0.75 at 1, 0 at 2.
                expect.that(frownTrack.times.length).is(4);
                expect.that(near(<f64>frownTrack.values[0], 1)).is(true);
                expect.that(near(<f64>frownTrack.values[2], 0.6666667, 1e-4)).is(true);
                expect.that(near(<f64>frownTrack.values[3], 0)).is(true);
            });
            test("mergeMorphTargetTracks and findNode", (expect) => {
                const mesh = new THREE.Mesh(quadGeometry(), new THREE.MeshStandardMaterial());
                mesh.name = "Face";
                mesh.morphTargetInfluences = [0, 0];
                mesh.morphTargetDictionary.set("a", 0);
                mesh.morphTargetDictionary.set("b", 1);
                const root = new THREE.Group();
                root.add(mesh);
                expect.that(THREE.PropertyBinding.findNode(root, "Face") === mesh).is(true);
                expect.that(THREE.PropertyBinding.findNode(root, "") === root).is(true);
                expect.that(THREE.PropertyBinding.findNode(root, mesh.uuid) === mesh).is(true);
                expect.that(THREE.PropertyBinding.findNode(root, "Nobody") == null).is(true);
                const parsed = THREE.PropertyBinding.parseTrackName("Skin.bones[Arm].position");
                expect.that(parsed.objectName).is("bones");
                expect.that(parsed.objectIndex).is("Arm");
                expect.that(parsed.propertyName).is("position");
                const clip = new THREE.AnimationClip("m", -1, [
                    new THREE.NumberKeyframeTrack("Face.morphTargetInfluences[a]", [0, 1], [0, 1]),
                    new THREE.NumberKeyframeTrack("Face.morphTargetInfluences[1]", [0, 1], [1, 0]),
                ]);
                const merged = GLTFExporter.Utils.mergeMorphTargetTracks(clip, root);
                expect.that(merged.tracks.length).is(1);
                const t = merged.tracks[0];
                expect.that(t.name).is("Face.morphTargetInfluences");
                expect.that(t.values.length).is(4);
                expect.that(<f64>t.values[1]).is(1);
                expect.that(<f64>t.values[2]).is(1);
                // insertKeyframe adds an interpolated key and keeps order.
                const track = new THREE.NumberKeyframeTrack("x", [0, 1], [0, 10]);
                expect.that(GLTFExporter.Utils.insertKeyframe(track, 0.5)).is(1);
                expect.that(near(<f64>track.values[1], 5)).is(true);
                expect.that(GLTFExporter.Utils.insertKeyframe(track, 0.5004)).is(1);
                expect.that(GLTFExporter.Utils.insertKeyframe(track, 2)).is(3);
                expect.that(track.times.length).is(4);
            });
            test("the .gltf JSON with a data: URI buffer, re-parsed", (expect) => {
                const scene = sceneWithHierarchy();
                const result = new GLTFExporter().parse(scene);
                expect.that(result.glb == null).is(true);
                expect.that(result.json.startsWith("{\"asset\":{\"version\":\"2.0\"")).is(true);
                const buffer = jat(jget(result.gltf, "buffers"), 0);
                expect.that(jstr(buffer, "uri", "").startsWith("data:application/octet-stream;base64,")).is(true);
                // Re-read from the text alone.
                const parsed = THREE.JSON.parse(result.json);
                expect.that(parsed != null).is(true);
                const gltf = new GLTFLoader().parse(String.UTF8.encode(result.json));
                expect.that(gltf != null).is(true);
                if (gltf == null) return;
                const quad = find(gltf.scene, "Quad") as THREE.Mesh;
                expect.that(quad.geometry.getAttribute("position")!.count).is(4);
                expect.that(near(quad.geometry.getAttribute("position")!.getX(2), 1)).is(true);
                expect.that(quad.geometry.index!.getX(4)).is(2);
                // parseAsync settles at once.
                expect.that(new GLTFExporter().parseAsync(scene).getStatus()).is("Fulfilled");
            });
            test("the Models example's features.glb, exported and reloaded", (expect) => {
                const bytes = this.blob("features");
                if (bytes == null) return;
                const loader = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder);
                const source = loader.parse(bytes!);
                expect.that(source != null).is(true);
                if (source == null) return;
                const result = new GLTFExporter().parse(source.scene, { binary: true, animations: source.animations });
                expect.that(result.glb != null).is(true);
                // Plain accessors: no meshopt or quantization in the output.
                const used = strings(jget(result.gltf, "extensionsUsed"));
                expect.that(used.indexOf("EXT_meshopt_compression") < 0).is(true);
                const copy = new GLTFLoader().parse(result.glb!);
                expect.that(copy != null).is(true);
                if (copy == null) return;
                // Same meshes, with the same vertex counts and names.
                const before: Array<THREE.Mesh> = [], after: Array<THREE.Mesh> = [];
                collectMeshes(source.scene, before);
                collectMeshes(copy.scene, after);
                expect.that(after.length).is(before.length);
                let same = after.length == before.length;
                for (let i = 0; same && i < before.length; i++) {
                    if (before[i].name != after[i].name) same = false;
                    const a = before[i].geometry.getAttribute("position")!, b = after[i].geometry.getAttribute("position")!;
                    if (a.count != b.count || !near(a.getX(a.count - 1), b.getX(b.count - 1), 1e-6)) same = false;
                    const ia = before[i].geometry.index, ib = after[i].geometry.index;
                    if ((ia == null) != (ib == null)) same = false;
                    else if (ia != null && ib != null && ia.count != ib.count) same = false;
                    if (before[i].material.type != after[i].material.type) same = false;
                }
                expect.that(same).is(true);
                expect.that(copy.animations.length).is(source.animations.length);
                const glass = find(copy.scene, "Glass") as THREE.Mesh;
                expect.that(glass.geometry.getAttribute("position")!.count).is(25 * 13);
                // Material extensions, instancing and morph targets survive.
                const was = (find(source.scene, "Glass") as THREE.Mesh).material as THREE.MeshPhysicalMaterial;
                const now = glass.material as THREE.MeshPhysicalMaterial;
                expect.that(was.transmission > 0 && near(now.transmission, was.transmission)).is(true);
                expect.that(near(now.ior, was.ior) && near(now.thickness, was.thickness)).is(true);
                expect.that(strings(jget(result.gltf, "extensionsRequired")).indexOf("EXT_mesh_gpu_instancing") >= 0).is(true);
                const quantized = find(copy.scene, "Quantized") as THREE.Mesh;
                expect.that(quantized.geometry.morphAttributes.size).is(1);
            });
        });
    }
}

/// A plugin adding an extension to every node.
class NodeCounter extends GLTFExporterPlugin {
    nodes: i32 = 0;

    constructor() {
        super();
        this.name = "TEST_counter";
    }

    override writeNode(object: THREE.Object3D, nodeDef: Dynamic): void {
        this.nodes++;
        const ext = Dynamic.newTable();
        ext.set("n", Dynamic.fromNumber(<f64>this.nodes));
        let extensions = nodeDef.get("extensions");
        if (extensions == null) {
            extensions = Dynamic.newTable();
            nodeDef.set("extensions", extensions);
        }
        extensions.set(this.name, ext);
        this.writer!.extensionsUsed.set(this.name, true);
    }
}

function collectMeshes(object: THREE.Object3D, out: Array<THREE.Mesh>): void {
    if (object instanceof THREE.Mesh) out.push(object as THREE.Mesh);
    for (let i = 0; i < object.children.length; i++) collectMeshes(object.children[i], out);
}
