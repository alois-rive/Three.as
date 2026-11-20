// FBXLoader (M11d): binary and ASCII parsing, geometry, transforms,
// materials, skins, blend shapes, animation and NURBS curves: rive . --test
// Fixtures: tools/make_fbx_samples.py, and examples/assets/fbx_nurbs.fbx,
// three.js r170 examples/models/fbx/nurbs.fbx (public domain, CC0, per that
// folder's README).

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import {
    FBXLoader, BinaryParser, TextParser, isFbxFormatBinary, isFbxFormatASCII, getFbxVersion,
    convertArrayBufferToString, getEulerOrder, convertFBXTimeToSeconds, FBX_BYTES, FBX_STRING, inflateFBX,
} from "../three/addons/loaders/FBXLoader";
import { NURBSCurve } from "../three/addons/curves/NURBSCurve";

function near(a: f64, b: f64, eps: f64 = 1e-4): bool {
    return Math.abs(a - b) <= eps;
}

function srgbToLinear(c: f64): f64 {
    return c < 0.04045 ? c * 0.0773993808 : Math.pow(c * 0.9478672986 + 0.0521327014, 2.4);
}

function find(root: THREE.Object3D, name: string): THREE.Object3D? {
    return root.getObjectByName(name);
}

function trackNamed(clip: THREE.AnimationClip, name: string): THREE.KeyframeTrack? {
    for (let i = 0; i < clip.tracks.length; i++) {
        if (clip.tracks[i].name == name) return clip.tracks[i];
    }
    return null;
}

export class FBXTests extends Tests {
    override run(): void {
        group("FBX formats", () => {
            test("binary and ASCII detection, versions, time", (expect) => {
                const binary = this.blob("fbx_scene");
                const ascii = this.blob("fbx_ascii");
                if (binary == null || ascii == null) return;
                expect.that(isFbxFormatBinary(binary!)).is(true);
                expect.that(isFbxFormatBinary(ascii!)).is(false);
                const text = convertArrayBufferToString(ascii!);
                expect.that(isFbxFormatASCII(text)).is(true);
                expect.that(getFbxVersion(text)).is(7400);
                expect.that(getEulerOrder(0)).is("ZYX");
                expect.that(getEulerOrder(5)).is("XYZ");
                expect.that(convertFBXTimeToSeconds(46186158000 * 2)).is(2);
            });
            test("the binary parser reads records, compressed arrays and 64-bit ids", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const parser = new BinaryParser();
                const tree = parser.parse(bytes!);
                expect.that(parser.error).is("");
                if (tree == null) return;
                const models = tree.objects("Model");
                expect.that(models.ids.length).is(11);
                // ids above 2^32 stay in file order and exact
                expect.that(models.ids[0]).is(<i64>2000000001000);
                const root = models.get(models.ids[0]);
                expect.that(root.attrName).is("Root");
                expect.that(root.attrType).is("Null");
                const translation = root.property("Lcl_Translation")!;
                expect.that(translation.value.arr[1]).is(1);
                const geometries = tree.objects("Geometry");
                const box = geometries.get(geometries.ids[0]);
                expect.that(box.array("Vertices")!.length).is(24);
                expect.that(box.array("PolygonVertexIndex")![3]).is(-2);   // 1 ^ -1: the end of the first face
                expect.that(box.nodesNamed("LayerElementUV").length).is(1);
                const connections = tree.node("Connections")!.connections;
                expect.that(connections.length).is(41);
                expect.that(connections[0].relationship).is("");
                const video = tree.objects("Video");
                const content = video.get(video.ids[0]).value("Content")!;
                expect.that(content.kind).is(FBX_BYTES);
                expect.that(content.bytes!.byteLength).greaterThan(50);
            });
            test("the text parser builds the same kind of tree", (expect) => {
                const bytes = this.blob("fbx_ascii");
                if (bytes == null) return;
                const tree = new TextParser().parse(convertArrayBufferToString(bytes!));
                const models = tree.objects("Model");
                expect.that(models.ids.length).is(2);
                expect.that(models.get(20).attrName).is("Parent");
                expect.that(models.get(21).property("Lcl_Scaling")!.value.arr[2]).is(2);
                const geometry = tree.objects("Geometry").get(22);
                expect.that(geometry.attrName).is("PlaneGeo");
                expect.that(geometry.array("PolygonVertexIndex")!.length).is(7);
                const settings = tree.node("GlobalSettings")!;
                expect.that(settings.property("UnitScaleFactor")!.value.asNumber()).is(1);
                const connections = tree.node("Connections")!.connections;
                expect.that(connections.length).is(6);
                expect.that(connections[5].relationship).is("DiffuseColor");
                const content = tree.objects("Video").get(24).value("Content")!;
                expect.that(content.kind).is(FBX_STRING);
                expect.that(content.str.startsWith("iVBOR")).is(true);
            });
            test("FBX 7500 (64-bit records, uncompressed arrays)", (expect) => {
                const bytes = this.blob("fbx_v7500");
                if (bytes == null) return;
                const loader = new FBXLoader();
                const object = loader.parse(bytes!);
                expect.that(loader.error).is("");
                if (object == null) return;
                const mesh = find(object!, "Wide") as THREE.Mesh;
                expect.that(mesh.geometry.getAttribute("position")!.count).is(9);
                expect.that(mesh.position.z).is(1);
            });
            test("arrays inflated by the job (inflateFBX) parse the same", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const inflated = inflateFBX(bytes!);
                expect.that(inflated.error).is("");
                expect.that(inflated.offsets.length).greaterThan(20);
                const loader = new FBXLoader();
                const object = loader.parseInflated(bytes!, "", inflated);
                expect.that(loader.error).is("");
                if (object == null) return;
                const box = find(object!, "Box") as THREE.Mesh;
                expect.that(box.geometry.getAttribute("position")!.count).is(36);
                expect.that(object!.animations[0].tracks.length).is(3);
                // a mismatch is an error, not a wrong scene
                const other = this.blob("fbx_v7500");
                if (other == null) return;
                expect.that(new FBXLoader().parseInflated(bytes!, "", inflateFBX(other!)) == null).is(true);
            });
            test("bad input fails with an error", (expect) => {
                const loader = new FBXLoader();
                expect.that(loader.parse(String.UTF8.encode("not an fbx")) == null).is(true);
                expect.that(loader.error.length).greaterThan(0);
            });
        });

        group("FBX scene", () => {
            test("hierarchy and FBX transforms (pre-rotation, pivots)", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const loader = new FBXLoader();
                const object = loader.parse(bytes!);
                expect.that(loader.error).is("");
                if (object == null) return;
                const scene = object!;
                // several top-level models: a new Group
                expect.that(scene.name).is("");
                expect.that(loader.unitScaleFactor).is(2.54);
                const root = find(scene, "Root")!;
                expect.that(root.parent === scene).is(true);
                expect.that(near(root.position.y, 1)).is(true);
                const box = find(scene, "Box")!;
                expect.that(box.parent === root).is(true);
                expect.that(near(box.position.x, 2)).is(true);
                expect.that(near(box.scale.x, 0.5) && near(box.scale.y, 0.5) && near(box.scale.z, 0.5)).is(true);
                // PreRotation x -90 then rotation y 90: +x turns to -y
                const v = new THREE.Vector3(1, 0, 0).applyQuaternion(box.quaternion);
                expect.that(near(v.x, 0) && near(v.y, -1) && near(v.z, 0)).is(true);
                // RotationPivot (1, 0, 0), rotation z 90: the origin moves to (1, -1, 0)
                const pivoted = find(scene, "Pivoted")!;
                expect.that(near(pivoted.position.x, 1) && near(pivoted.position.y, -1)).is(true);
                scene.updateMatrixWorld(true);
                const world = new THREE.Vector3().setFromMatrixPosition(box.matrixWorld);
                expect.that(near(world.x, 2) && near(world.y, 1)).is(true);
                expect.that(find(scene, "Bone1")!.parent === find(scene, "Bone0")).is(true);
                expect.that(find(scene, "Strip")!.parent === find(scene, "Armature")).is(true);
                expect.that(loader.originalNames.get(root.id)).is("Root");
            });
            test("quads triangulated with normals, uvs and material groups", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const object = new FBXLoader().parse(bytes!);
                if (object == null) return;
                const box = find(object!, "Box") as THREE.Mesh;
                const g = box.geometry;
                const p = g.getAttribute("position")!;
                const n = g.getAttribute("normal")!;
                const uv = g.getAttribute("uv")!;
                expect.that(p.count).is(36);
                expect.that(n.count).is(36);
                expect.that(uv.count).is(36);
                // every triangle winds with its face normal
                let wound = true;
                const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3();
                for (let i = 0; i < 36; i += 3) {
                    a.set(p.getX(i), p.getY(i), p.getZ(i));
                    b.set(p.getX(i + 1), p.getY(i + 1), p.getZ(i + 1));
                    c.set(p.getX(i + 2), p.getY(i + 2), p.getZ(i + 2));
                    const cross = b.clone().sub(a).cross(c.clone().sub(a));
                    if (cross.x * n.getX(i) + cross.y * n.getY(i) + cross.z * n.getZ(i) <= 0) wound = false;
                }
                expect.that(wound).is(true);
                // uvs by index: corners of the unit square
                let corners = true;
                for (let i = 0; i < 36; i++) {
                    const u = uv.getX(i), w = uv.getY(i);
                    if (!((u == 0 || u == 1) && (w == 0 || w == 1))) corners = false;
                }
                expect.that(corners).is(true);
                // materials by polygon: faces 0-3 Gold, 4 Glass, 5 Gold
                expect.that(g.groups.length).is(3);
                expect.that(g.groups[0].start).is(0);
                expect.that(g.groups[0].count).is(24);
                expect.that(g.groups[1].materialIndex).is(1);
                expect.that(g.groups[1].count).is(6);
                expect.that(g.groups[2].start).is(30);
                expect.that(box.materials.length).is(2);
            });
            test("Phong and Lambert materials and an embedded texture", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const object = new FBXLoader().parse(bytes!);
                if (object == null) return;
                const box = find(object!, "Box") as THREE.Mesh;
                const gold = box.materials[0];
                expect.that(gold instanceof THREE.MeshPhongMaterial).is(true);
                expect.that(gold.name).is("Gold");
                const phong = gold as THREE.MeshPhongMaterial;
                expect.that(near(phong.color.r, srgbToLinear(0.8))).is(true);
                expect.that(near(phong.color.g, srgbToLinear(0.6))).is(true);
                expect.that(near(phong.specular.r, srgbToLinear(0.5))).is(true);
                expect.that(phong.shininess).is(20);
                expect.that(phong.transparent).is(false);
                const map = phong.map;
                expect.that(map != null).is(true);
                if (map != null) {
                    expect.that(map.name).is("Checker");
                    expect.that(map.wrapS).is(THREE.RepeatWrapping);
                    expect.that(map.wrapT).is(THREE.ClampToEdgeWrapping);
                    expect.that(map.repeat.x).is(2);
                    expect.that(map.repeat.y).is(3);
                    expect.that(map.colorSpace).is(THREE.SRGBColorSpace);
                }
                const glass = box.materials[1];
                expect.that(glass instanceof THREE.MeshLambertMaterial).is(true);
                expect.that(near(glass.opacity, 0.75)).is(true);
                expect.that(glass.transparent).is(true);
            });
            test("vertex colours, n-gons, geometric transforms, blend shapes", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const object = new FBXLoader().parse(bytes!);
                if (object == null) return;
                const pentagon = find(object!, "Pentagon") as THREE.Mesh;
                const g = pentagon.geometry;
                const p = g.getAttribute("position")!;
                // a pentagon (3 triangles) and a triangle
                expect.that(p.count).is(12);
                g.computeBoundingBox();
                expect.that(near(g.boundingBox!.min.y, -0.5)).is(true);   // GeometricTranslation y 0.5
                const color = g.getAttribute("color");
                expect.that(color != null).is(true);
                if (color != null) expect.that(color.itemSize).is(3);
                expect.that(pentagon.material.vertexColors).is(true);
                expect.that(pentagon.material.name).is(THREE.Loader.DEFAULT_MATERIAL_NAME);
                expect.that(g.morphTargetsRelative).is(true);
                const morph = g.morphAttributes.get("position");
                expect.that(morph.length).is(1);
                expect.that(morph[0].name).is("Bulge");
                expect.that(morph[0].count).is(12);
                // control point 0 moves along z: its vertices carry the delta
                let moved = 0;
                for (let i = 0; i < 12; i++) if (morph[0].getZ(i) == 1) moved++;
                expect.that(moved).greaterThan(0);
                expect.that(pentagon.morphTargetDictionary.get("Bulge")).is(0);
                expect.that(pentagon.morphTargetInfluences.length).is(1);
            });
            test("skinning: clusters, weights, bind pose", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const object = new FBXLoader().parse(bytes!);
                if (object == null) return;
                const strip = find(object!, "Strip");
                expect.that(strip instanceof THREE.SkinnedMesh).is(true);
                if (!(strip instanceof THREE.SkinnedMesh)) return;
                const mesh = strip as THREE.SkinnedMesh;
                const skeleton = mesh.skeleton!;
                expect.that(skeleton.bones.length).is(2);
                expect.that(skeleton.bones[0].name).is("Bone0");
                expect.that(skeleton.bones[1].name).is("Bone1");
                expect.that(skeleton.bones[1].position.y).is(1);
                // the bind matrix comes from the BindPose, inverses from TransformLinks
                expect.that(near(mesh.bindMatrix.elements[14], -2)).is(true);
                const inverse = skeleton.boneInverses[1].elements;
                expect.that(near(inverse[13], -1) && near(inverse[14], 2)).is(true);
                const g = mesh.geometry;
                const p = g.getAttribute("position")!;
                const index = g.getAttribute("skinIndex")!;
                const weight = g.getAttribute("skinWeight")!;
                expect.that(p.count).is(12);
                let ok = true;
                for (let i = 0; i < p.count; i++) {
                    const y = p.getY(i);
                    if (y == 0 && !(index.getX(i) == 0 && weight.getX(i) == 1)) ok = false;
                    if (y == 2 && !(index.getX(i) == 1 && weight.getX(i) == 1)) ok = false;
                    if (y == 1 && !(index.getX(i) == 0 && index.getY(i) == 1 && near(weight.getX(i), 0.5) && near(weight.getY(i), 0.5))) ok = false;
                }
                expect.that(ok).is(true);
            });
            test("animation stack: position, rotation and morph tracks", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const object = new FBXLoader().parse(bytes!);
                if (object == null) return;
                expect.that(object!.animations.length).is(1);
                const clip = object!.animations[0];
                expect.that(clip.name).is("Take 001");
                expect.that(clip.tracks.length).is(3);
                expect.that(clip.duration).is(2);
                const position = trackNamed(clip, "Root.position");
                expect.that(position != null).is(true);
                if (position != null) {
                    expect.that(position.times.length).is(2);
                    expect.that(position.times[1]).is(1);
                    // y from the curve, x and z from the model's transform
                    expect.that(position.values[1]).is(1);
                    expect.that(position.values[4]).is(2);
                    expect.that(position.values[3]).is(0);
                }
                const rotation = trackNamed(clip, "Bone1.quaternion");
                expect.that(rotation != null).is(true);
                if (rotation != null) {
                    // the 90 -> 300 degree span is split (as three.js: from its start)
                    expect.that(rotation.times.length).is(4);
                    expect.that(rotation.values.length).is(16);
                    // key 1: 90 degrees about z
                    expect.that(near(Math.abs(rotation.values[6]), Math.SQRT1_2) && near(Math.abs(rotation.values[7]), Math.SQRT1_2)).is(true);
                }
                const morph = trackNamed(clip, "Pentagon.morphTargetInfluences[0]");
                expect.that(morph != null).is(true);
                if (morph != null) {
                    expect.that(morph.values[0]).is(0);
                    expect.that(morph.values[1]).is(1);
                }
                // the clip plays on the loaded object
                const mixer = new THREE.AnimationMixer(object!);
                mixer.clipAction(clip).play();
                mixer.update(1);
                expect.that(near(find(object!, "Root")!.position.y, 2)).is(true);
            });
            test("lights, cameras and NURBS curves", (expect) => {
                const bytes = this.blob("fbx_scene");
                if (bytes == null) return;
                const object = new FBXLoader().parse(bytes!);
                if (object == null) return;
                const sun = find(object!, "Sun");
                expect.that(sun instanceof THREE.DirectionalLight).is(true);
                if (sun instanceof THREE.DirectionalLight) {
                    const light = sun as THREE.DirectionalLight;
                    expect.that(near(light.intensity, 1.5)).is(true);
                    expect.that(light.castShadow).is(true);
                    expect.that(near(light.color.g, srgbToLinear(0.9))).is(true);
                }
                const cam = find(object!, "Cam");
                expect.that(cam instanceof THREE.PerspectiveCamera).is(true);
                if (cam instanceof THREE.PerspectiveCamera) {
                    const camera = cam as THREE.PerspectiveCamera;
                    expect.that(camera.fov).is(40);
                    expect.that(camera.aspect).is(1.6);
                    expect.that(near(camera.near, 0.01)).is(true);
                    expect.that(camera.far).is(5);
                }
                const arc = find(object!, "Arc");
                expect.that(arc instanceof THREE.Line).is(true);
                if (arc instanceof THREE.Line) {
                    const p = (arc as THREE.Line).geometry.getAttribute("position")!;
                    expect.that(p.count).is(4 * 12 + 1);
                    expect.that(near(p.getX(0), -1) && near(p.getY(0), 0)).is(true);
                    expect.that(near(p.getX(p.count - 1), 1) && near(p.getY(p.count - 1), 0)).is(true);
                    expect.that(near(p.getX(24), 0) && near(p.getY(24), 1)).is(true);
                }
            });
        });

        group("FBX ASCII and real files", () => {
            test("an ASCII mesh with a material and an embedded texture", (expect) => {
                const bytes = this.blob("fbx_ascii");
                if (bytes == null) return;
                const loader = new FBXLoader();
                const object = loader.parse(bytes!);
                expect.that(loader.error).is("");
                if (object == null) return;
                // a single top-level Group is returned itself
                expect.that(object!.name).is("Parent");
                expect.that(object!.position.z).is(3);
                const plane = find(object!, "Plane") as THREE.Mesh;
                expect.that(plane.position.x).is(1);
                expect.that(plane.scale.y).is(2);
                const g = plane.geometry;
                expect.that(g.getAttribute("position")!.count).is(9);
                const n = g.getAttribute("normal")!;
                expect.that(n.getZ(0)).is(1);
                expect.that(n.getZ(8)).is(1);
                const uv = g.getAttribute("uv")!;
                let match = true;
                const p = g.getAttribute("position")!;
                for (let i = 0; i < 9; i++) if (uv.getX(i) != p.getX(i) && !(p.getX(i) == 2 && uv.getX(i) == 1)) match = false;
                expect.that(match).is(true);
                const material = plane.material;
                expect.that(material instanceof THREE.MeshLambertMaterial).is(true);
                const lambert = material as THREE.MeshLambertMaterial;
                expect.that(near(lambert.color.r, srgbToLinear(0.5))).is(true);
                expect.that(lambert.map != null).is(true);
            });
            test("multi-line ASCII arrays and URL-fetched texture flipY", (expect) => {
                // Minimal ASCII FBX 7400 with a multi-line Vertices array and an external texture URL.
                const ascii = "; FBX 7.4.0 project file\n"
                    + "; " + "--------------------------------------------------------------------------------"
                    + "--------------------------------------------------------------------------------"
                    + "----------------------------------------\n"
                    + "FBXHeaderExtension:  {\n\tFBXVersion: 7400\n}\n"
                    + "Objects:  {\n"
                    + "\tGeometry: 10, \"Geometry::Tri\", \"Mesh\" {\n"
                    + "\t\tVertices: *9 {\n"
                    + "\t\t\ta: 0,0,0,\n"
                    + "1,0,0,\n"
                    + "0,1,0\n"
                    + "\t\t}\n"
                    + "\t\tPolygonVertexIndex: *3 {\n"
                    + "\t\t\ta: 0,1,-3\n"
                    + "\t\t}\n"
                    + "\t}\n"
                    + "\tModel: 11, \"Model::TriMesh\", \"Mesh\" {\n"
                    + "\t\tProperties70:  {\n"
                    + "\t\t}\n"
                    + "\t}\n"
                    + "\tMaterial: 12, \"Material::Mat\", \"\" {\n"
                    + "\t\tShadingModel: \"lambert\"\n"
                    + "\t\tProperties70:  {\n"
                    + "\t\t}\n"
                    + "\t}\n"
                    + "\tTexture: 13, \"Texture::Tex\", \"\" {\n"
                    + "\t\tFileName: \"albedo.png\"\n"
                    + "\t\tRelativeFilename: \"albedo.png\"\n"
                    + "\t}\n"
                    + "\tVideo: 14, \"Video::Vid\", \"Clip\" {\n"
                    + "\t\tRelativeFilename: \"albedo.png\"\n"
                    + "\t}\n"
                    + "}\n"
                    + "Connections:  {\n"
                    + "\tC: \"OO\",10,11\n"
                    + "\tC: \"OO\",12,11\n"
                    + "\tC: \"OP\",13,12, \"DiffuseColor\"\n"
                    + "\tC: \"OO\",14,13\n"
                    + "}\n";
                const loader = new FBXLoader();
                const obj = loader.parse(String.UTF8.encode(ascii), "https://example.invalid/models/");
                expect.that(loader.error).is("");
                expect.that(obj != null).is(true);
                if (obj == null) return;
                const mesh = find(obj!, "TriMesh") as THREE.Mesh;
                expect.that(mesh.geometry.getAttribute("position")!.count).is(3);
                expect.that(mesh.geometry.getAttribute("position")!.getX(1)).is(1);
                expect.that(mesh.geometry.getAttribute("position")!.getY(2)).is(1);
                const mat = mesh.material as THREE.MeshLambertMaterial;
                expect.that(mat.map != null).is(true);
                if (mat.map != null) expect.that(mat.map!.flipY).is(true);
            });
            test("three.js's nurbs.fbx (ASCII 7.2, open, closed and periodic curves)", (expect) => {
                const bytes = this.blob("fbx_nurbs");
                if (bytes == null) return;
                const loader = new FBXLoader();
                const object = loader.parse(bytes!);
                expect.that(loader.error).is("");
                if (object == null) return;
                let lines = 0;
                let finite = true;
                const stack: Array<THREE.Object3D> = [object!];
                while (stack.length > 0) {
                    const o = stack.pop();
                    for (let i = 0; i < o.children.length; i++) stack.push(o.children[i]);
                    if (!(o instanceof THREE.Line)) continue;
                    lines++;
                    const p = (o as THREE.Line).geometry.getAttribute("position")!;
                    if (p.count < 10) finite = false;
                    for (let i = 0; i < p.count; i++) {
                        if (!isFinite(p.getX(i)) || !isFinite(p.getY(i)) || !isFinite(p.getZ(i))) finite = false;
                    }
                }
                expect.that(lines).is(5);
                expect.that(finite).is(true);
            });
            test("NURBSCurve", (expect) => {
                // a quadratic Bezier as a NURBS: (0,0) (1,2) (2,0)
                const curve = new NURBSCurve(2, [0, 0, 0, 1, 1, 1], [
                    new THREE.Vector4(0, 0, 0, 1), new THREE.Vector4(1, 2, 0, 1), new THREE.Vector4(2, 0, 0, 1),
                ]);
                const mid = curve.getPoint(0.5);
                expect.that(near(mid.x, 1) && near(mid.y, 1)).is(true);
                const tangent = curve.getTangent(0.5);
                expect.that(near(tangent.x, 1) && near(tangent.y, 0)).is(true);
            });
        });
    }
}
