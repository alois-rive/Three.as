// toJSON, JSON.stringify and ObjectLoader / MaterialLoader /
// BufferGeometryLoader: rive . --test

import { Tests } from "rive/test";
import { Dynamic } from "rive/dynamic";
import * as THREE from "../three/Three";

function near(a: f64, b: f64, eps: f64 = 1e-5): bool { return Math.abs(a - b) <= eps; }

function attributesEqual(a: THREE.BufferAttribute?, b: THREE.BufferAttribute?): bool {
    if (a == null || b == null) return a == null && b == null;
    if (a.itemSize != b.itemSize || a.array.length != b.array.length) return false;
    for (let i = 0; i < a.array.length; i++) if (a.array[i] != b.array[i]) return false;
    return true;
}

function indexEqual(a: THREE.Uint32BufferAttribute?, b: THREE.Uint32BufferAttribute?): bool {
    if (a == null || b == null) return a == null && b == null;
    if (a.array.length != b.array.length) return false;
    for (let i = 0; i < a.array.length; i++) if (a.array[i] != b.array[i]) return false;
    return true;
}

function geometriesEqual(a: THREE.BufferGeometry, b: THREE.BufferGeometry): bool {
    const names = a.attributes.keys();
    if (names.length != b.attributes.keys().length) return false;
    for (let i = 0; i < names.length; i++) if (!attributesEqual(a.getAttribute(names[i]), b.getAttribute(names[i]))) return false;
    if (!indexEqual(a.index, b.index)) return false;
    if (a.groups.length != b.groups.length) return false;
    for (let i = 0; i < a.groups.length; i++) {
        const ga = a.groups[i], gb = b.groups[i];
        if (ga.start != gb.start || ga.count != gb.count || ga.materialIndex != gb.materialIndex) return false;
    }
    return true;
}

function child(root: THREE.Object3D, name: string): THREE.Object3D {
    return root.getObjectByName(name)!;
}

/// A scene with one of most things toJSON writes.
function buildScene(): THREE.Scene {
    const scene = new THREE.Scene();
    scene.name = "world";
    scene.background = THREE.Color.fromHex(0x223344);
    scene.fog = new THREE.Fog(0x112233, 2, 50);
    scene.backgroundRotation.set(0, 0.5, 0, "YXZ");

    const group = new THREE.Group();
    group.name = "group";
    group.position.set(1, 2, 3);
    group.rotation.set(0.1, 0.2, 0.3);
    group.scale.set(2, 2, 2);
    group.userData.set("hp", Dynamic.fromNumber(7));
    group.userData.set("tag", Dynamic.fromString("enemy \"boss\"\n"));
    scene.add(group);

    const standard = new THREE.MeshStandardMaterial({ color: 0xff8800, roughness: 0.25, metalness: 0.75, emissive: 0x102030 });
    standard.name = "gold";
    standard.emissiveIntensity = 2;
    const box = new THREE.Mesh(new THREE.BoxGeometry(2, 3, 4, 2, 1, 1), standard);
    box.name = "box";
    box.position.set(-1, 0.5, 0);
    box.castShadow = true;
    box.receiveShadow = true;
    box.renderOrder = 2;
    box.layers.set(3);
    box.frustumCulled = false;
    group.add(box);

    const phong = new THREE.MeshPhongMaterial({ color: 0x00ff00, shininess: 80, side: THREE.DoubleSide,
        transparent: true, opacity: 0.5, specular: 0x333333 });
    const sphere = new THREE.Mesh(new THREE.SphereGeometry(1.5, 12, 8), phong);
    sphere.name = "sphere";
    sphere.visible = false;
    scene.add(sphere);
    // The same geometry and material twice: written once.
    const sphere2 = new THREE.Mesh(sphere.geometry, phong);
    sphere2.name = "sphere2";
    scene.add(sphere2);

    // Custom data: index, groups, normals, uvs, a morph target, a sphere.
    const custom = new THREE.BufferGeometry();
    custom.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0], 3));
    custom.setAttribute("normal", new THREE.Float32BufferAttribute([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1], 3));
    custom.setAttribute("uv", new THREE.Float32BufferAttribute([0, 0, 1, 0, 0, 1, 1, 1], 2));
    custom.setIndex([0, 1, 2, 2, 1, 3]);
    custom.addGroup(0, 3, 0);
    custom.addGroup(3, 3, 1);
    const morph = new THREE.Float32BufferAttribute([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1], 3);
    morph.name = "bulge";
    custom.morphAttributes.set("position", [morph]);
    custom.computeBoundingSphere();
    custom.name = "quad";
    const multi = new THREE.Mesh(custom);
    multi.name = "multi";
    multi.materials = [new THREE.MeshBasicMaterial({ color: 0xff0000 }), new THREE.MeshLambertMaterial({ color: 0x0000ff })];
    scene.add(multi);

    // A data texture (its texels are written) on a basic material.
    const texels = new Uint8Array(16);
    for (let i = 0; i < 16; i++) texels[i] = <u8>(i * 16);
    const texture = new THREE.DataTexture(texels, 2, 2);
    texture.name = "checker";
    texture.wrapS = THREE.RepeatWrapping;
    texture.wrapT = THREE.MirroredRepeatWrapping;
    texture.repeat.set(4, 2);
    texture.offset.set(0.25, 0.5);
    texture.rotation = 0.3;
    texture.magFilter = THREE.LinearFilter;
    texture.colorSpace = THREE.SRGBColorSpace;
    const textured = new THREE.Mesh(new THREE.PlaneGeometry(2, 1, 3, 2),
        new THREE.MeshBasicMaterial({ map: texture, alphaTest: 0.5 }));
    textured.name = "textured";
    scene.add(textured);

    const lineGeometry = new THREE.BufferGeometry();
    lineGeometry.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 0, 1, 1, 1, 2, 0, 2], 3));
    const line = new THREE.Line(lineGeometry, new THREE.LineDashedMaterial({ color: 0xffff00, dashSize: 0.2, gapSize: 0.1 }));
    line.name = "line";
    scene.add(line);
    const segments = new THREE.LineSegments(lineGeometry, new THREE.LineBasicMaterial({ color: 0x00ffff }));
    segments.name = "segments";
    scene.add(segments);
    const points = new THREE.Points(lineGeometry, new THREE.PointsMaterial({ size: 4, sizeAttenuation: false, color: 0xff00ff }));
    points.name = "points";
    scene.add(points);
    const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ color: 0x8080ff, rotation: 0.7 }));
    sprite.name = "sprite";
    scene.add(sprite);

    const sun = new THREE.DirectionalLight(0xffeedd, 3);
    sun.name = "sun";
    sun.position.set(5, 10, 2);
    sun.castShadow = true;
    sun.shadow.bias = -0.001;
    sun.shadow.mapSize.set(1024, 1024);
    scene.add(sun);
    scene.add(sun.target);
    sun.target.name = "sunTarget";
    sun.target.position.set(1, 0, 1);
    const bulb = new THREE.PointLight(0xff0000, 2, 15, 1.5);
    bulb.name = "bulb";
    scene.add(bulb);
    const spot = new THREE.SpotLight(0x00ff00, 4, 20, 0.6, 0.3, 1);
    spot.name = "spot";
    scene.add(spot);
    scene.add(spot.target);   // a target outside the document loads as a new Object3D
    const hemi = new THREE.HemisphereLight(0x8888ff, 0x442200, 0.7);
    hemi.name = "hemi";
    scene.add(hemi);
    const ambient = new THREE.AmbientLight(0x404040, 0.4);
    ambient.name = "ambient";
    scene.add(ambient);
    const area = new THREE.RectAreaLight(0xffffff, 5, 3, 2);
    area.name = "area";
    scene.add(area);

    const camera = new THREE.PerspectiveCamera(60, 1.5, 0.5, 300);
    camera.name = "camera";
    camera.zoom = 2;
    scene.add(camera);
    const ortho = new THREE.OrthographicCamera(-4, 4, 3, -3, 1, 100);
    ortho.name = "ortho";
    scene.add(ortho);

    const instanced = new THREE.InstancedMesh(new THREE.TorusGeometry(1, 0.3, 6, 12), new THREE.MeshNormalMaterial(), 3);
    instanced.name = "instanced";
    for (let i = 0; i < 3; i++) instanced.setMatrixAt(i, new THREE.Matrix4().makeTranslation(<f64>i, 0, 0));
    instanced.setColorAt(1, THREE.Color.fromHex(0xff0000));
    scene.add(instanced);

    const physical = new THREE.MeshPhysicalMaterial({ clearcoat: 0.8, sheen: 0.5, ior: 1.7, transmission: 0.3,
        sheenColor: 0xff00ff, iridescence: 0.4 });
    const parametric: Array<THREE.BufferGeometry> = [
        new THREE.CylinderGeometry(0.5, 1, 2, 10, 2, true),
        new THREE.ConeGeometry(0.7, 1.5, 9),
        new THREE.CapsuleGeometry(0.4, 1.2, 3, 7),
        new THREE.CircleGeometry(1, 9, 0.1, 3),
        new THREE.RingGeometry(0.3, 1, 11, 2),
        new THREE.TorusKnotGeometry(1, 0.2, 20, 5, 2, 5),
        new THREE.IcosahedronGeometry(1, 1),
        new THREE.OctahedronGeometry(2),
        new THREE.TetrahedronGeometry(1.5),
        new THREE.DodecahedronGeometry(1),
        new THREE.LatheGeometry([new THREE.Vector2(0, -1), new THREE.Vector2(1, 0), new THREE.Vector2(0.5, 1)], 7),
    ];
    for (let i = 0; i < parametric.length; i++) {
        const m = new THREE.Mesh(parametric[i], physical);
        m.name = "p" + i.toString();
        scene.add(m);
    }

    const shape = new THREE.Shape();
    shape.moveTo(0, 0);
    shape.lineTo(2, 0);
    shape.quadraticCurveTo(3, 1, 2, 2);
    shape.bezierCurveTo(1.5, 3, 0.5, 3, 0, 2);
    shape.lineTo(0, 0);
    const hole = new THREE.Path();
    hole.absarc(1, 1, 0.3, 0, Math.PI * 2, false);
    shape.holes.push(hole);
    const flat = new THREE.Mesh(new THREE.ShapeGeometry([shape], 6), new THREE.MeshToonMaterial({ color: 0x00aa00 }));
    flat.name = "flat";
    scene.add(flat);
    const options = new THREE.ExtrudeGeometryOptions();
    options.depth = 0.5;
    options.bevelEnabled = true;
    options.bevelSegments = 2;
    options.curveSegments = 5;
    const extruded = new THREE.Mesh(new THREE.ExtrudeGeometry([shape], options), new THREE.MeshMatcapMaterial());
    extruded.name = "extruded";
    scene.add(extruded);

    // Skinning: two bones, a skinned mesh bound to them.
    const root = new THREE.Bone();
    root.name = "root";
    const tip = new THREE.Bone();
    tip.name = "tip";
    tip.position.set(0, 1, 0);
    root.add(tip);
    const skinGeometry = new THREE.BufferGeometry();
    skinGeometry.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 0, 1, 0, 0, 0, 1, 0], 3));
    skinGeometry.setAttribute("skinIndex", new THREE.Float32BufferAttribute([0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0], 4));
    skinGeometry.setAttribute("skinWeight", new THREE.Float32BufferAttribute([1, 0, 0, 0, 0.5, 0.5, 0, 0, 1, 0, 0, 0], 4));
    const skinned = new THREE.SkinnedMesh(skinGeometry, new THREE.MeshStandardMaterial());
    skinned.name = "skinned";
    skinned.add(root);
    skinned.bind(new THREE.Skeleton([root, tip]));
    scene.add(skinned);

    const lod = new THREE.LOD();
    lod.name = "lod";
    const near0 = new THREE.Group();
    near0.name = "lodNear";
    const far0 = new THREE.Group();
    far0.name = "lodFar";
    lod.addLevel(near0, 0);
    lod.addLevel(far0, 25, 0.1);
    scene.add(lod);

    const clip = new THREE.AnimationClip("spin", -1, [
        new THREE.VectorKeyframeTrack("box.position", [0, 1, 2], [0, 0, 0, 1, 2, 3, 0, 0, 0]),
        new THREE.QuaternionKeyframeTrack("box.quaternion", [0, 2], [0, 0, 0, 1, 0, 1, 0, 0]),
        new THREE.NumberKeyframeTrack("box.material.opacity", [0, 1], [1, 0.5], THREE.InterpolateDiscrete),
        new THREE.BooleanKeyframeTrack("sphere.visible", [0, 1], [1, 0]),
    ]);
    scene.animations.push(clip);
    return scene;
}

export class ObjectLoaderTests extends Tests {
    override run(): void {
        group("JSON", () => {
            test("stringify writes JSON that parse reads back", (expect) => {
                const t = Dynamic.newTable();
                t.set("n", Dynamic.fromNumber(1));
                t.set("f", Dynamic.fromNumber(0.5));
                t.set("big", Dynamic.fromNumber(4294967295));
                t.set("s", Dynamic.fromString("a\"b\\c\nd"));
                t.set("b", Dynamic.fromBool(false));
                t.set("nan", Dynamic.fromNumber(NaN));
                t.set("list", Dynamic.fromNumbers([1, 2.5, -3]));
                t.set("empty", Dynamic.newTable());
                const text = THREE.JSON.stringify(t);
                expect.that(text).is('{"n":1,"f":0.5,"big":4294967295,"s":"a\\"b\\\\c\\nd","b":false,"nan":null,"list":[1,2.5,-3],"empty":[]}');
                const back = THREE.JSON.parse(text);
                expect.that(Dynamic.asString(Dynamic.get(back, "s"))).is("a\"b\\c\nd");
                expect.that(Dynamic.asNumber(Dynamic.at(Dynamic.get(back, "list"), 1))).is(2.5);
                expect.that(THREE.JSON.parse("{oops") == null).is(true);
                expect.that(THREE.JSON.lastError.length > 0).is(true);
                const pretty = THREE.JSON.stringify(Dynamic.fromNumbers([1, 2]), 2);
                expect.that(pretty).is("[\n  1,\n  2\n]");
            });
            test("uuids are version 4 and unique", (expect) => {
                const a = THREE.MathUtils.generateUUID();
                expect.that(a.length).is(36);
                expect.that(a.charAt(14)).is("4");
                expect.that(a != THREE.MathUtils.generateUUID()).is(true);
                const o = new THREE.Object3D();
                expect.that(o.uuid).is(o.uuid);
                expect.that(o.uuid != new THREE.Object3D().uuid).is(true);
            });
        });

        group("toJSON", () => {
            test("an object document in three.js's shape", (expect) => {
                const scene = buildScene();
                const json = scene.toJSON();
                const metadata = Dynamic.get(json, "metadata");
                expect.that(Dynamic.asNumber(Dynamic.get(metadata, "version"))).is(4.6);
                expect.that(Dynamic.asString(Dynamic.get(metadata, "type"))).is("Object");
                expect.that(Dynamic.asString(Dynamic.get(metadata, "generator"))).is("Object3D.toJSON");
                const object = Dynamic.get(json, "object");
                expect.that(Dynamic.asString(Dynamic.get(object, "type"))).is("Scene");
                expect.that(Dynamic.asString(Dynamic.get(object, "uuid"))).is(scene.uuid);
                expect.that(Dynamic.asNumber(Dynamic.get(object, "background"))).is(0x223344);
                // The shared sphere geometry and phong material are written once.
                const geometries = Dynamic.asArray(Dynamic.get(json, "geometries"));
                let spheres = 0;
                for (let i = 0; i < geometries.length; i++) {
                    if (Dynamic.asString(Dynamic.get(geometries[i], "type")) == "SphereGeometry") spheres++;
                    expect.that(Dynamic.get(geometries[i], "metadata") == null).is(true);
                }
                expect.that(spheres).is(1);
                const box = Dynamic.get(Dynamic.at(Dynamic.get(object, "children"), 0), "children");
                const boxJSON = Dynamic.at(box, 0);
                expect.that(Dynamic.asString(Dynamic.get(boxJSON, "type"))).is("Mesh");
                expect.that(Dynamic.asBool(Dynamic.get(boxJSON, "castShadow"))).is(true);
                expect.that(Dynamic.asNumber(Dynamic.get(boxJSON, "layers"))).is(8);
                expect.that(Dynamic.length(Dynamic.get(boxJSON, "matrix"))).is(16);
                expect.that(Dynamic.asNumbers(Dynamic.get(boxJSON, "matrix"))[12]).is(-1);
                expect.that(Dynamic.length(Dynamic.get(json, "skeletons"))).is(1);
                expect.that(Dynamic.length(Dynamic.get(json, "animations"))).is(1);
                expect.that(Dynamic.length(Dynamic.get(json, "shapes"))).is(1);
                expect.that(Dynamic.length(Dynamic.get(json, "images"))).is(1);
            });
            test("geometries, materials and textures on their own", (expect) => {
                const box = new THREE.BoxGeometry(1, 2, 3).toJSON();
                expect.that(Dynamic.asString(Dynamic.get(box, "type"))).is("BoxGeometry");
                expect.that(Dynamic.asNumber(Dynamic.get(box, "depth"))).is(3);
                expect.that(Dynamic.get(box, "data") == null).is(true);
                // A transformed clone is written as data, typed BufferGeometry.
                const data = new THREE.BoxGeometry().clone().toJSON();
                expect.that(Dynamic.asString(Dynamic.get(data, "type"))).is("BufferGeometry");
                const attributes = Dynamic.get(Dynamic.get(data, "data"), "attributes");
                expect.that(Dynamic.asNumber(Dynamic.get(Dynamic.get(attributes, "position"), "itemSize"))).is(3);
                expect.that(Dynamic.asString(Dynamic.get(Dynamic.get(attributes, "position"), "type"))).is("Float32Array");
                expect.that(Dynamic.asString(Dynamic.get(Dynamic.get(Dynamic.get(data, "data"), "index"), "type"))).is("Uint16Array");
                const texture = new THREE.DataTexture(new Uint8Array(4), 1, 1);
                const material = new THREE.MeshStandardMaterial({ color: 0x336699, map: texture });
                const mj = material.toJSON();
                expect.that(Dynamic.asNumber(Dynamic.get(mj, "color"))).is(0x336699);
                expect.that(Dynamic.asString(Dynamic.get(mj, "map"))).is(texture.uuid);
                expect.that(Dynamic.length(Dynamic.get(mj, "textures"))).is(1);
                expect.that(Dynamic.length(Dynamic.get(mj, "images"))).is(1);
                expect.that(Dynamic.asString(Dynamic.get(Dynamic.get(mj, "metadata"), "type"))).is("Material");
                const back = new THREE.MaterialLoader().parse<string>(THREE.JSON.stringify(mj))!;
                expect.that(back instanceof THREE.MeshStandardMaterial).is(true);
                expect.that((back as THREE.MeshStandardMaterial).color.getHex()).is(0x336699);
                expect.that(back.uuid).is(material.uuid);
            });
            test("a ShaderMaterial's uniforms and WGSL asset", (expect) => {
                const shader = new THREE.ShaderMaterial({ shader: "shaders/wave", lights: true });
                shader.uniforms.set("time", new THREE.Uniform<f64>(1.5));
                shader.uniforms.set("tint", new THREE.Uniform<THREE.Color>(THREE.Color.fromHex(0x8040c0)));
                shader.uniforms.set("offset", new THREE.Uniform<THREE.Vector2>(new THREE.Vector2(1, 2)));
                shader.uniforms.set("dir", new THREE.Uniform<THREE.Vector3>(new THREE.Vector3(0, 1, 0)));
                shader.uniforms.set("rect", new THREE.Uniform<THREE.Vector4>(new THREE.Vector4(1, 2, 3, 4)));
                shader.uniforms.set("m", new THREE.Uniform<THREE.Matrix4>(new THREE.Matrix4().makeTranslation(5, 6, 7)));
                const texture = new THREE.DataTexture(new Uint8Array(4), 1, 1);
                shader.uniforms.set("map", new THREE.Uniform<THREE.Texture>(texture));
                const json = shader.toJSON();
                const uniforms = Dynamic.get(json, "uniforms");
                expect.that(Dynamic.asString(Dynamic.get(Dynamic.get(uniforms, "tint"), "type"))).is("c");
                expect.that(Dynamic.asString(Dynamic.get(Dynamic.get(uniforms, "map"), "value"))).is(texture.uuid);
                expect.that(Dynamic.asNumber(Dynamic.get(Dynamic.get(uniforms, "time"), "value"))).is(1.5);
                const loader = new THREE.MaterialLoader();
                const textures = new Map<string, THREE.Texture>();
                textures.set(texture.uuid, texture);
                loader.setTextures(textures);
                const back = loader.parse<string>(THREE.JSON.stringify(json))! as THREE.ShaderMaterial;
                expect.that(back.shader).is("shaders/wave");
                expect.that(back.lights).is(true);
                expect.that(back.fog).is(false);
                expect.that(back.uniforms.keys().join(",")).is("time,tint,offset,dir,rect,m,map");
                expect.that(back.uniform<f64>("time").value).is(1.5);
                expect.that(back.uniform<THREE.Color>("tint").value.getHex()).is(0x8040c0);
                expect.that(back.uniform<THREE.Vector2>("offset").value.y).is(2);
                expect.that(back.uniform<THREE.Vector4>("rect").value.w).is(4);
                expect.that(<f64>back.uniform<THREE.Matrix4>("m").value.elements[13]).is(6);
                expect.that(back.uniform<THREE.Texture>("map").value === texture).is(true);
            });
        });

        group("ObjectLoader round trip", () => {
            test("hierarchy, transforms and flags", (expect) => {
                const scene = buildScene();
                scene.updateMatrixWorld(true);
                const text = THREE.JSON.stringify(scene.toJSON());
                const loader = new THREE.ObjectLoader();
                const loaded = loader.parse<string>(text)!;
                expect.that(loader.error).is("");
                expect.that(loaded instanceof THREE.Scene).is(true);
                expect.that(loaded.uuid).is(scene.uuid);
                expect.that(loaded.name).is("world");
                expect.that(loaded.children.length).is(scene.children.length);
                const s = loaded as THREE.Scene;
                expect.that((s.background as THREE.Color).getHex()).is(0x223344);
                const fog = s.fog as THREE.Fog;
                expect.that(fog.near).is(2);
                expect.that(fog.far).is(50);
                expect.that(fog.color.getHex()).is(0x112233);
                expect.that(s.backgroundRotation.order).is("YXZ");
                expect.that(s.backgroundRotation.y).is(0.5);

                const group = child(loaded, "group");
                expect.that(group instanceof THREE.Group).is(true);
                expect.that(near(group.position.x, 1) && near(group.position.y, 2) && near(group.position.z, 3)).is(true);
                expect.that(near(group.scale.y, 2)).is(true);
                expect.that(near(group.rotation.x, 0.1) && near(group.rotation.z, 0.3)).is(true);
                expect.that(Dynamic.asNumber(group.userData.get("hp"))).is(7);
                expect.that(Dynamic.asString(group.userData.get("tag"))).is("enemy \"boss\"\n");

                const box = child(loaded, "box") as THREE.Mesh;
                expect.that(box.parent === group).is(true);
                expect.that(near(box.position.x, -1) && near(box.position.y, 0.5)).is(true);
                expect.that(box.castShadow && box.receiveShadow).is(true);
                expect.that(box.renderOrder).is(2);
                expect.that(box.layers.mask).is(8);
                expect.that(box.frustumCulled).is(false);
                expect.that(child(loaded, "sphere").visible).is(false);
                expect.that(child(loaded, "sphere2").visible).is(true);
                expect.that((child(loaded, "sphere") as THREE.Mesh).geometry === (child(loaded, "sphere2") as THREE.Mesh).geometry).is(true);
                expect.that((child(loaded, "sphere") as THREE.Mesh).material === (child(loaded, "sphere2") as THREE.Mesh).material).is(true);
                expect.that(loaded.animations.length).is(1);
                expect.that(loader.warnings.length).is(0);
            });
            test("geometries rebuild from parameters and data", (expect) => {
                const scene = buildScene();
                const loaded = new THREE.ObjectLoader().parse<Dynamic>(scene.toJSON())!;
                const names = ["box", "sphere", "multi", "textured", "line", "instanced", "flat", "extruded", "skinned",
                    "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10"];
                for (let i = 0; i < names.length; i++) {
                    const a = scene.getObjectByName(names[i])!;
                    const b = loaded.getObjectByName(names[i])!;
                    const ga = a instanceof THREE.Mesh ? (a as THREE.Mesh).geometry : (a as THREE.Line).geometry;
                    const gb = b instanceof THREE.Mesh ? (b as THREE.Mesh).geometry : (b as THREE.Line).geometry;
                    expect.that(ga.type + " " + names[i]).is(gb.type + " " + names[i]);
                    expect.that(names[i] + (geometriesEqual(ga, gb) ? " equal" : " differ")).is(names[i] + " equal");
                }
                const box = (loaded.getObjectByName("box") as THREE.Mesh).geometry as THREE.BoxGeometry;
                expect.that(box.parameters.depth).is(4);
                expect.that(box.parameters.widthSegments).is(2);
                const cone = (loaded.getObjectByName("p1") as THREE.Mesh).geometry as THREE.ConeGeometry;
                expect.that(cone.parameters.radiusBottom).is(0.7);
                const multi = (loaded.getObjectByName("multi") as THREE.Mesh);
                const quad = multi.geometry;
                expect.that(quad.name).is("quad");
                expect.that(quad.morphAttributes.get("position").length).is(1);
                expect.that(quad.morphAttributes.get("position")[0].name).is("bulge");
                expect.that(near(quad.boundingSphere!.radius, Math.SQRT2 / 2)).is(true);
                expect.that(multi.morphTargetInfluences.length).is(1);
                expect.that(multi.materials.length).is(2);
                expect.that(multi.materials[1] instanceof THREE.MeshLambertMaterial).is(true);
                expect.that((multi.materials[1] as THREE.MeshLambertMaterial).color.getHex()).is(0x0000ff);
                const extruded = (loaded.getObjectByName("extruded") as THREE.Mesh).geometry as THREE.ExtrudeGeometry;
                expect.that(extruded.shapes[0].holes.length).is(1);
                expect.that(extruded.options.bevelSegments).is(2);
            });
            test("materials, textures, lights, cameras", (expect) => {
                const scene = buildScene();
                const loaded = new THREE.ObjectLoader().parse<string>(THREE.JSON.stringify(scene.toJSON()))!;
                const gold = (loaded.getObjectByName("box") as THREE.Mesh).material as THREE.MeshStandardMaterial;
                expect.that(gold.name).is("gold");
                expect.that(gold.color.getHex()).is(0xff8800);
                expect.that(gold.emissive.getHex()).is(0x102030);
                expect.that(gold.roughness).is(0.25);
                expect.that(gold.metalness).is(0.75);
                expect.that(gold.emissiveIntensity).is(2);
                const phong = (loaded.getObjectByName("sphere") as THREE.Mesh).material as THREE.MeshPhongMaterial;
                expect.that(phong.shininess).is(80);
                expect.that(phong.side).is(THREE.DoubleSide);
                expect.that(phong.transparent).is(true);
                expect.that(phong.opacity).is(0.5);
                expect.that(phong.specular.getHex()).is(0x333333);
                const basic = (loaded.getObjectByName("textured") as THREE.Mesh).material as THREE.MeshBasicMaterial;
                expect.that(basic.alphaTest).is(0.5);
                const map = basic.map!;
                expect.that(map instanceof THREE.DataTexture).is(true);
                expect.that(map.name).is("checker");
                expect.that(map.wrapS).is(THREE.RepeatWrapping);
                expect.that(map.wrapT).is(THREE.MirroredRepeatWrapping);
                expect.that(map.repeat.x == 4 && map.repeat.y == 2).is(true);
                expect.that(map.offset.x == 0.25 && map.offset.y == 0.5).is(true);
                expect.that(near(map.rotation, 0.3)).is(true);
                expect.that(map.magFilter).is(THREE.LinearFilter);
                expect.that(map.colorSpace).is(THREE.SRGBColorSpace);
                const data = map as THREE.DataTexture;
                expect.that(data.width).is(2);
                expect.that((data.data as Uint8Array)[5]).is(80);
                const physical = (loaded.getObjectByName("p0") as THREE.Mesh).material as THREE.MeshPhysicalMaterial;
                expect.that(near(physical.clearcoat, 0.8) && near(physical.sheen, 0.5) && near(physical.ior, 1.7)).is(true);
                expect.that(near(physical.transmission, 0.3) && near(physical.iridescence, 0.4)).is(true);
                expect.that(physical.sheenColor.getHex()).is(0xff00ff);
                const dashed = (loaded.getObjectByName("line") as THREE.Line).material as THREE.LineDashedMaterial;
                expect.that(dashed.color.getHex()).is(0xffff00);
                expect.that(near(dashed.dashSize, 0.2)).is(true);
                expect.that(loaded.getObjectByName("segments") instanceof THREE.LineSegments).is(true);
                const pm = (loaded.getObjectByName("points") as THREE.Points).material as THREE.PointsMaterial;
                expect.that(pm.size).is(4);
                expect.that(pm.sizeAttenuation).is(false);
                const sprite = loaded.getObjectByName("sprite") as THREE.Sprite;
                expect.that(near(sprite.material.rotation, 0.7)).is(true);
                expect.that((loaded.getObjectByName("flat") as THREE.Mesh).material instanceof THREE.MeshToonMaterial).is(true);

                const sun = loaded.getObjectByName("sun") as THREE.DirectionalLight;
                expect.that(sun.color.getHex()).is(0xffeedd);
                expect.that(sun.intensity).is(3);
                expect.that(sun.castShadow).is(true);
                expect.that(sun.shadow.bias).is(-0.001);
                expect.that(sun.shadow.mapSize.x).is(1024);
                expect.that(sun.target.name).is("sunTarget");
                expect.that(near(sun.target.position.x, 1)).is(true);
                const bulb = loaded.getObjectByName("bulb") as THREE.PointLight;
                expect.that(bulb.distance).is(15);
                expect.that(bulb.decay).is(1.5);
                const spot = loaded.getObjectByName("spot") as THREE.SpotLight;
                expect.that(spot.angle).is(0.6);
                expect.that(spot.penumbra).is(0.3);
                expect.that(spot.decay).is(1);
                const hemi = loaded.getObjectByName("hemi") as THREE.HemisphereLight;
                expect.that(hemi.groundColor.getHex()).is(0x442200);
                expect.that(near(hemi.intensity, 0.7)).is(true);
                expect.that((loaded.getObjectByName("ambient") as THREE.AmbientLight).color.getHex()).is(0x404040);
                const area = loaded.getObjectByName("area") as THREE.RectAreaLight;
                expect.that(area.width == 3 && area.height == 2).is(true);
                const camera = loaded.getObjectByName("camera") as THREE.PerspectiveCamera;
                expect.that(camera.fov).is(60);
                expect.that(camera.aspect).is(1.5);
                expect.that(camera.near).is(0.5);
                expect.that(camera.far).is(300);
                expect.that(camera.zoom).is(2);
                const ortho = loaded.getObjectByName("ortho") as THREE.OrthographicCamera;
                expect.that(ortho.left == -4 && ortho.top == 3 && ortho.far == 100).is(true);
            });
            test("instances, skins, LOD and animations", (expect) => {
                const scene = buildScene();
                const loaded = new THREE.ObjectLoader().parse<string>(THREE.JSON.stringify(scene.toJSON()))!;
                const instanced = loaded.getObjectByName("instanced") as THREE.InstancedMesh;
                expect.that(instanced.count).is(3);
                const m = new THREE.Matrix4();
                instanced.getMatrixAt(2, m);
                expect.that(m.elements[12]).is(2);
                const c = new THREE.Color();
                instanced.getColorAt(1, c);
                expect.that(c.getHex()).is(0xff0000);
                expect.that(instanced.material instanceof THREE.MeshNormalMaterial).is(true);

                const skinned = loaded.getObjectByName("skinned") as THREE.SkinnedMesh;
                const skeleton = skinned.skeleton!;
                expect.that(skeleton.bones.length).is(2);
                expect.that(skeleton.bones[0].name).is("root");
                expect.that((skeleton.bones[1] as THREE.Object3D) === loaded.getObjectByName("tip")).is(true);
                const original = (scene.getObjectByName("skinned") as THREE.SkinnedMesh).skeleton!;
                expect.that(near(<f64>skeleton.boneInverses[1].elements[13], <f64>original.boneInverses[1].elements[13])).is(true);
                expect.that(skeleton.uuid).is(original.uuid);

                const lod = loaded.getObjectByName("lod") as THREE.LOD;
                expect.that(lod.levels.length).is(2);
                expect.that(lod.levels[1].object.name).is("lodFar");
                expect.that(lod.levels[1].distance).is(25);
                expect.that(near(lod.levels[1].hysteresis, 0.1)).is(true);

                const clip = loaded.animations[0];
                expect.that(clip.name).is("spin");
                expect.that(clip.duration).is(2);
                expect.that(clip.tracks.length).is(4);
                expect.that(clip.tracks[0] instanceof THREE.VectorKeyframeTrack).is(true);
                expect.that(clip.tracks[1] instanceof THREE.QuaternionKeyframeTrack).is(true);
                expect.that(clip.tracks[2].interpolation).is(THREE.InterpolateDiscrete);
                expect.that(clip.tracks[3] instanceof THREE.BooleanKeyframeTrack).is(true);
                expect.that(clip.tracks[3].values[1]).is(0);
                expect.that(clip.tracks[0].values[4]).is(2);
            });
            test("a second round trip writes the same JSON", (expect) => {
                const scene = buildScene();
                const first = THREE.JSON.stringify(scene.toJSON());
                const loaded = new THREE.ObjectLoader().parse<string>(first)!;
                const second = THREE.JSON.stringify(loaded.toJSON());
                expect.that(second.length).is(first.length);
                expect.that(second == first).is(true);
            });
        });

        group("three.js r170 files", () => {
            test("a scene three.js writes", (expect) => {
                const loader = new THREE.ObjectLoader();
                const object = loader.parse<string>(THREEJS_SCENE);
                expect.that(loader.error).is("");
                expect.that(object != null).is(true);
                const scene = object! as THREE.Scene;
                expect.that(scene.uuid).is("0b4a9a2e-0001-4c6c-8a52-1b3c6f5f9a01");
                expect.that((scene.background as THREE.Color).getHex()).is(0x87ceeb);
                expect.that(scene.children.length).is(5);
                const box = scene.getObjectByName("Box") as THREE.Mesh;
                expect.that(box.geometry instanceof THREE.BoxGeometry).is(true);
                expect.that((box.geometry as THREE.BoxGeometry).parameters.height).is(2);
                expect.that(near(box.position.x, 2) && near(box.position.y, 1)).is(true);
                expect.that(box.castShadow).is(true);
                const mat = box.material as THREE.MeshStandardMaterial;
                expect.that(mat.color.getHex()).is(0xff4400);
                expect.that(mat.roughness).is(0.4);
                expect.that(mat.map != null).is(true);
                expect.that(mat.map!.wrapS).is(THREE.RepeatWrapping);
                expect.that(mat.map!.repeat.x).is(2);
                expect.that((mat.map! as THREE.DataTexture).width).is(2);
                expect.that(Dynamic.asString(box.userData.get("kind"))).is("crate");

                const tri = scene.getObjectByName("Triangle") as THREE.Mesh;
                const geometry = tri.geometry;
                expect.that(geometry.getAttribute("position")!.count).is(3);
                expect.that(geometry.index!.count).is(3);
                expect.that(geometry.index!.getX(2)).is(2);
                // A normalized Uint8 colour reads as floats in [0, 1].
                const color = geometry.getAttribute("color")!;
                expect.that(color.getX(0)).is(1);
                expect.that(near(color.getY(1), 128.0 / 255.0)).is(true);
                expect.that(color.normalized).is(false);
                // Interleaved position + uv.
                const quad = (scene.getObjectByName("Interleaved") as THREE.Mesh).geometry;
                expect.that(quad.getAttribute("position")!.getY(2)).is(2);
                expect.that(quad.getAttribute("uv")!.getY(2)).is(0.5);
                expect.that(quad.getAttribute("uv")!.getX(1)).is(1);
                expect.that((tri.material as THREE.MeshBasicMaterial).vertexColors).is(true);
                expect.that((tri.material as THREE.MeshBasicMaterial).side).is(THREE.DoubleSide);

                const sun = scene.getObjectByName("Sun") as THREE.DirectionalLight;
                expect.that(sun.intensity).is(2.5);
                expect.that(sun.shadow.mapSize.x).is(2048);
                expect.that((sun.shadow.camera as THREE.OrthographicCamera).left).is(-10);
                expect.that(sun.target === scene.getObjectByName("Target")).is(true);
                const camera = scene.getObjectByName("Camera") as THREE.PerspectiveCamera;
                expect.that(camera.fov).is(45);
                expect.that(near(camera.position.z, 10)).is(true);

                expect.that(scene.animations.length).is(1);
                const clip = scene.animations[0];
                expect.that(clip.tracks.length).is(3);
                expect.that(clip.tracks[2] instanceof THREE.BooleanKeyframeTrack).is(true);
                expect.that(clip.tracks[2].values[1]).is(0);
                expect.that(loader.warnings.length).is(0);
            });
            test("a pretty-printed file from a BlobAsset", (expect) => {
                const bytes = this.blob("threejs_scene");
                expect.that(bytes != null).is(true);
                const loader = new THREE.ObjectLoader();
                const props = loader.parse<string>(String.UTF8.decode(bytes!))!;
                expect.that(props instanceof THREE.Group).is(true);
                expect.that(props.children.length).is(5);
                const pill = props.getObjectByName("Pill") as THREE.Mesh;
                const capsule = pill.geometry as THREE.CapsuleGeometry;
                expect.that(capsule.parameters.height).is(1.5);   // r170's `length`
                expect.that(near(pill.position.x, -2)).is(true);
                const phong = pill.material as THREE.MeshPhongMaterial;
                expect.that(phong.normalScale.y).is(-1);
                const bumps = phong.normalMap!;
                expect.that(bumps.repeat.x).is(3);
                expect.that(bumps.anisotropy).is(4);
                expect.that(bumps.colorSpace).is(THREE.NoColorSpace);
                // Without a Context, images cannot be decoded or looked up:
                // the textures stay empty, their sources keep the urls.
                const red = phong.map!;
                expect.that(red.name).is("red");
                expect.that(red.source.url.startsWith("data:image/png;base64,")).is(true);
                expect.that(bumps.source.url).is("textures/studio_px.png");
                expect.that(loader.warnings.length).is(2);
                const lathe = (props.getObjectByName("Vase") as THREE.Mesh).geometry as THREE.LatheGeometry;
                expect.that(lathe.parameters.points.length).is(3);
                expect.that(lathe.parameters.points[1].x).is(0.8);
                expect.that(lathe.parameters.segments).is(10);
                const plate = (props.getObjectByName("Plate") as THREE.Mesh).geometry as THREE.ShapeGeometry;
                expect.that(plate.shapes.length).is(1);
                expect.that(plate.shapes[0].curves.length).is(3);
                expect.that(plate.shapes[0].curves[1] instanceof THREE.QuadraticBezierCurve).is(true);
                expect.that(plate.shapes[0].holes.length).is(1);
                expect.that((plate.shapes[0].holes[0].curves[0] as THREE.EllipseCurve).aClockwise).is(true);
                expect.that(plate.getAttribute("position")!.count > 10).is(true);
                expect.that((props.getObjectByName("Vase") as THREE.Mesh).material.flatShading).is(true);
                const stars = props.getObjectByName("Stars") as THREE.Points;
                expect.that(stars.visible).is(false);
                expect.that(stars.geometry instanceof THREE.IcosahedronGeometry).is(true);
                expect.that((stars.material as THREE.PointsMaterial).size).is(3);
                const sky = props.getObjectByName("Sky") as THREE.HemisphereLight;
                expect.that(sky.groundColor.getHex()).is(0x444444);
                expect.that(sky.intensity).is(1.5);
                // Written back, the data url is kept as it was.
                const again = THREE.JSON.stringify(props.toJSON());
                expect.that(again.indexOf("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ") > 0).is(true);
                expect.that(again.indexOf("\"length\":1.5") > 0).is(true);
            });
            test("the geometry and material loaders on their own", (expect) => {
                const geometry = new THREE.BufferGeometryLoader().parse<string>(
                    '{"metadata":{"version":4.6,"type":"BufferGeometry","generator":"BufferGeometry.toJSON"},' +
                    '"uuid":"g","type":"BufferGeometry","data":{"attributes":{"position":{"itemSize":3,' +
                    '"type":"Float32Array","array":[0,0,0,1,0,0,0,1,0],"normalized":false}},' +
                    '"groups":[{"start":0,"count":3,"materialIndex":0}],' +
                    '"boundingSphere":{"center":[0.5,0.5,0],"radius":0.7}}}')!;
                expect.that(geometry.getAttribute("position")!.count).is(3);
                expect.that(geometry.groups.length).is(1);
                expect.that(geometry.boundingSphere!.radius).is(0.7);
                const material = new THREE.MaterialLoader().parse<string>(
                    '{"metadata":{"version":4.6,"type":"Material","generator":"Material.toJSON"},' +
                    '"uuid":"m","type":"MeshLambertMaterial","color":16711680,"emissive":255,' +
                    '"reflectivity":1,"refractionRatio":0.98,"blendColor":0,"side":1,"depthWrite":false}')!;
                expect.that(material instanceof THREE.MeshLambertMaterial).is(true);
                expect.that((material as THREE.MeshLambertMaterial).emissive.getHex()).is(0x0000ff);
                expect.that(material.side).is(THREE.BackSide);
                expect.that(material.depthWrite).is(false);
                expect.that(new THREE.ObjectLoader().parse<string>('{"metadata":{"type":"BufferGeometry"}}') == null).is(true);
            });
        });
    }
}

// A document as three.js r170's Object3D.toJSON writes it (by hand, after
// its format): a box with a textured standard material and userData, an
// indexed triangle with normalized Uint8 colours, an interleaved quad, a
// directional light with its shadow and a target, a camera, and a clip.
const THREEJS_SCENE: string =
    '{"metadata":{"version":4.6,"type":"Object","generator":"Object3D.toJSON"},' +
    '"geometries":[' +
    '{"uuid":"c3f2a1b0-0002-4d1e-9f00-000000000001","type":"BoxGeometry","width":1,"height":2,"depth":1,' +
    '"widthSegments":1,"heightSegments":1,"depthSegments":1},' +
    '{"uuid":"c3f2a1b0-0002-4d1e-9f00-000000000002","type":"BufferGeometry","data":{"attributes":{' +
    '"position":{"itemSize":3,"type":"Float32Array","array":[0,0,0,1,0,0,0,1,0],"normalized":false},' +
    '"color":{"itemSize":3,"type":"Uint8Array","array":[255,0,0,0,128,0,0,0,255],"normalized":true}},' +
    '"index":{"type":"Uint16Array","array":[0,1,2]},' +
    '"boundingSphere":{"center":[0.5,0.5,0],"radius":0.7071067811865476}}},' +
    '{"uuid":"c3f2a1b0-0002-4d1e-9f00-000000000003","type":"BufferGeometry","data":{"attributes":{' +
    '"position":{"isInterleavedBufferAttribute":true,"itemSize":3,"data":"ib-1","offset":0,"normalized":false},' +
    '"uv":{"isInterleavedBufferAttribute":true,"itemSize":2,"data":"ib-1","offset":3,"normalized":false}},' +
    '"interleavedBuffers":{"ib-1":{"uuid":"ib-1","buffer":"ab-1","type":"Float32Array","stride":5}},' +
    '"arrayBuffers":{"ab-1":[0,0,0,0,0,1065353216,0,0,1065353216,0,0,1073741824,0,0,1056964608]}}}],' +
    '"materials":[' +
    '{"uuid":"d4e5f6a7-0003-4b2c-8d00-000000000001","type":"MeshStandardMaterial","color":16729088,' +
    '"roughness":0.4,"metalness":0.1,"emissive":0,"envMapRotation":[0,0,0,"XYZ"],"envMapIntensity":1,' +
    '"map":"e5f6a7b8-0004-4c3d-9e00-000000000001","blendColor":0},' +
    '{"uuid":"d4e5f6a7-0003-4b2c-8d00-000000000002","type":"MeshBasicMaterial","color":16777215,' +
    '"envMapRotation":[0,0,0,"XYZ"],"reflectivity":1,"refractionRatio":0.98,"side":2,"vertexColors":true,' +
    '"blendColor":0}],' +
    '"textures":[{"uuid":"e5f6a7b8-0004-4c3d-9e00-000000000001","name":"","image":"f6a7b8c9-0005-4d4e-af00-000000000001",' +
    '"mapping":300,"channel":0,"repeat":[2,2],"offset":[0,0],"center":[0,0],"rotation":0,"wrap":[1000,1000],' +
    '"format":1023,"internalFormat":null,"type":1009,"colorSpace":"srgb","minFilter":1008,"magFilter":1006,' +
    '"anisotropy":1,"flipY":true,"generateMipmaps":true,"premultiplyAlpha":false,"unpackAlignment":4}],' +
    '"images":[{"uuid":"f6a7b8c9-0005-4d4e-af00-000000000001","url":{"data":[255,0,0,255,0,255,0,255,' +
    '0,0,255,255,255,255,255,255],"width":2,"height":2,"type":"Uint8Array"}}],' +
    '"animations":[{"name":"bob","duration":2,"tracks":[' +
    '{"name":"Box.position","times":[0,1,2],"values":[2,1,0,2,2,0,2,1,0],"type":"vector"},' +
    '{"name":"Box.quaternion","times":[0,2],"values":[0,0,0,1,0,0.7071068,0,0.7071068],"type":"quaternion"},' +
    '{"name":"Box.visible","times":[0,1],"values":[true,false],"type":"bool"}],' +
    '"uuid":"a7b8c9d0-0006-4e5f-b000-000000000001","blendMode":2500}],' +
    '"object":{"uuid":"0b4a9a2e-0001-4c6c-8a52-1b3c6f5f9a01","type":"Scene","layers":1,' +
    '"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"up":[0,1,0],"background":8900331,' +
    '"backgroundRotation":[0,0,0,"XYZ"],"environmentRotation":[0,0,0,"XYZ"],' +
    '"children":[' +
    '{"uuid":"11111111-0001-4000-8000-000000000001","type":"Mesh","name":"Box","castShadow":true,' +
    '"userData":{"kind":"crate"},"layers":1,"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,2,1,0,1],"up":[0,1,0],' +
    '"geometry":"c3f2a1b0-0002-4d1e-9f00-000000000001","material":"d4e5f6a7-0003-4b2c-8d00-000000000001"},' +
    '{"uuid":"11111111-0001-4000-8000-000000000002","type":"Mesh","name":"Triangle","layers":1,' +
    '"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"up":[0,1,0],' +
    '"geometry":"c3f2a1b0-0002-4d1e-9f00-000000000002","material":"d4e5f6a7-0003-4b2c-8d00-000000000002"},' +
    '{"uuid":"11111111-0001-4000-8000-000000000003","type":"Mesh","name":"Interleaved","layers":1,' +
    '"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"up":[0,1,0],' +
    '"geometry":"c3f2a1b0-0002-4d1e-9f00-000000000003","material":"d4e5f6a7-0003-4b2c-8d00-000000000002"},' +
    '{"uuid":"11111111-0001-4000-8000-000000000004","type":"DirectionalLight","name":"Sun","castShadow":true,' +
    '"layers":1,"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,5,10,7.5,1],"up":[0,1,0],"color":16777215,"intensity":2.5,' +
    '"shadow":{"bias":-0.0005,"mapSize":[2048,2048],"camera":{"uuid":"11111111-0001-4000-8000-000000000005",' +
    '"type":"OrthographicCamera","layers":1,"up":[0,1,0],"zoom":1,"left":-10,"right":10,"top":10,"bottom":-10,' +
    '"near":0.5,"far":500}},"target":"11111111-0001-4000-8000-000000000006"},' +
    '{"uuid":"11111111-0001-4000-8000-000000000006","type":"Object3D","name":"Target","layers":1,' +
    '"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"up":[0,1,0],"children":[' +
    '{"uuid":"11111111-0001-4000-8000-000000000007","type":"PerspectiveCamera","name":"Camera","layers":1,' +
    '"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,10,1],"up":[0,1,0],"fov":45,"zoom":1,"near":0.1,"far":1000,' +
    '"focus":10,"aspect":1.7777777777777777,"filmGauge":35,"filmOffset":0}]}],' +
    '"animations":["a7b8c9d0-0006-4e5f-b000-000000000001"]}}';
