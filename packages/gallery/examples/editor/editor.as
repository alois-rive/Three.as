// Editor: three.js's scene tools. Helpers for the grid, axes, lights, a
// second camera, a box, a plane, an arrow and vertex normals; addon
// geometries (a rounded box, a Klein bottle, a convex hull with a decal)
// and text extruded from the Rive file's Orbitron font; wide lines (a
// rainbow helix and a dashed outline). TransformControls on the rounded
// box: drag its arrows, planes or rings; orbit elsewhere.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { VertexNormalsHelper } from "lib:threeas/three/addons/helpers/VertexNormalsHelper";
import { RoundedBoxGeometry } from "lib:threeas/three/addons/geometries/RoundedBoxGeometry";
import { ParametricGeometry } from "lib:threeas/three/addons/geometries/ParametricGeometry";
import { klein } from "lib:threeas/three/addons/geometries/ParametricFunctions";
import { ConvexGeometry } from "lib:threeas/three/addons/geometries/ConvexGeometry";
import { DecalGeometry } from "lib:threeas/three/addons/geometries/DecalGeometry";
import { RiveFont } from "lib:threeas/three/addons/loaders/FontLoader";
import { TextGeometry, TextGeometryParameters } from "lib:threeas/three/addons/geometries/TextGeometry";
import { LineGeometry } from "lib:threeas/three/addons/lines/LineGeometry";
import { LineSegmentsGeometry } from "lib:threeas/three/addons/lines/LineSegmentsGeometry";
import { LineMaterial } from "lib:threeas/three/addons/lines/LineMaterial";
import { Line2, LineSegments2 } from "lib:threeas/three/addons/lines/LineSegments2";
import { TransformControls } from "lib:threeas/three/addons/controls/TransformControls";
import { Context } from "rive/host";

export class Editor extends THREE.ThreeLayout {
    knot: THREE.Mesh = new THREE.Mesh();
    boxHelper: THREE.BoxHelper? = null;
    normals: VertexNormalsHelper? = null;
    spotHelper: THREE.SpotLightHelper? = null;
    spot: THREE.SpotLight = new THREE.SpotLight();
    time: f64 = 0;
    transform: TransformControls? = null;
    /// The gizmo: 0 translate, 1 rotate, 2 scale.
    @input gizmoMode: i32 = 0;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x1b1d22);
        scene.add(new THREE.GridHelper(12, 24, 0x5a6270, 0x30343c));
        scene.add(new THREE.AxesHelper(1.5));
        scene.add(new THREE.HemisphereLight(0xdde4ff, 0x302a24, 1.2));

        const sun = new THREE.DirectionalLight(0xffffff, 2);
        sun.position.set(-3, 4, 2);
        scene.add(sun);
        scene.add(new THREE.DirectionalLightHelper(sun, 0.5));

        this.spot = new THREE.SpotLight(0xffaa55, 30, 6, 0.5, 0.3);
        this.spot.position.set(3, 3.5, 1);
        scene.add(this.spot);
        const sh = new THREE.SpotLightHelper(this.spot);
        scene.add(sh);
        this.spotHelper = sh;

        const lamp = new THREE.PointLight(0x55aaff, 6, 4);
        lamp.position.set(-2, 1.2, -2);
        scene.add(lamp);
        scene.add(new THREE.PointLightHelper(lamp, 0.2));

        this.knot = new THREE.Mesh(new THREE.TorusKnotGeometry(0.5, 0.17, 96, 12),
            new THREE.MeshStandardMaterial({ color: 0xd0d6e0, roughness: 0.4 }));
        this.knot.position.set(0, 1.0, 0);
        scene.add(this.knot);
        const bh = new THREE.BoxHelper(this.knot, 0xffe066);
        scene.add(bh);
        this.boxHelper = bh;

        const ball = new THREE.Mesh(new THREE.IcosahedronGeometry(0.5, 1),
            new THREE.MeshStandardMaterial({ color: 0x7ec4cf, flatShading: true }));
        ball.position.set(2, 0.5, -1.5);
        scene.add(ball);
        const n = new VertexNormalsHelper(ball, 0.25, 0xff5577);
        scene.add(n);
        this.normals = n;

        scene.add(new THREE.PlaneHelper(new THREE.Plane(new THREE.Vector3(1, 0, 0), 2.8), 2.5, 0x88ff88));
        scene.add(new THREE.ArrowHelper(new THREE.Vector3(1, 1, 0).normalize(), new THREE.Vector3(-3, 0, 2), 1.5, 0xff66cc));

        const other = new THREE.PerspectiveCamera(40, 1.5, 0.5, 2.5);
        other.position.set(-3, 1.5, 3);
        other.lookAt<f64>(0, 1, 0);
        other.updateMatrixWorld();
        scene.add(other);
        scene.add(new THREE.CameraHelper(other));

        // Addon geometries.
        const rounded = new THREE.Mesh(new RoundedBoxGeometry(0.9, 0.9, 0.9, 4, 0.18),
            new THREE.MeshStandardMaterial({ color: 0xef8354, roughness: 0.5 }));
        rounded.position.set(-1.8, 0.45, 1.4);
        scene.add(rounded);
        const bottle = new THREE.Mesh(new ParametricGeometry(klein, 48, 24),
            new THREE.MeshStandardMaterial({ color: 0x9d8df1, roughness: 0.4, side: THREE.DoubleSide }));
        bottle.scale.setScalar(0.08);
        bottle.position.set(1.6, 0.8, 1.8);
        scene.add(bottle);
        const pts: Array<THREE.Vector3> = [];
        for (let i = 0; i < 40; i++) {
            const a = <f64>i * 2.399, r = 0.5 + 0.25 * Math.sin(<f64>i * 1.7);
            pts.push(new THREE.Vector3(Math.cos(a) * r, (<f64>(i % 7) / 6 - 0.5) * 1.1, Math.sin(a) * r));
        }
        const hull = new THREE.Mesh(new ConvexGeometry(pts),
            new THREE.MeshStandardMaterial({ color: 0x5ab1bb, roughness: 0.6, flatShading: true }));
        hull.position.set(-0.4, 0.6, -2.4);
        scene.add(hull);
        hull.updateMatrixWorld();
        const decal = new THREE.Mesh(new DecalGeometry(hull, new THREE.Vector3(-0.4, 0.6, -1.9), new THREE.Euler(),
            new THREE.Vector3(0.6, 0.6, 1)), new THREE.MeshBasicMaterial({
                color: 0xffe066, polygonOffset: true, polygonOffsetFactor: -4, polygonOffsetUnits: -4 }));
        scene.add(decal);
        // Text shaped by Rive from the file's Orbitron font.
        const orbitron = context.font("Orbitron");
        if (orbitron != null) {
            const p = new TextGeometryParameters();
            p.font = new RiveFont(orbitron);
            p.size = 0.6;
            p.depth = 0.12;
            p.curveSegments = 6;
            p.bevelEnabled = true;
            p.bevelThickness = 0.02;
            p.bevelSize = 0.015;
            p.bevelSegments = 2;
            const text = new THREE.Mesh(new TextGeometry("THREEAS", p),
                new THREE.MeshStandardMaterial({ color: 0xf2f2f2, roughness: 0.3, metalness: 0.2 }));
            text.geometry.computeBoundingBox();
            const bb = text.geometry.boundingBox!;
            text.position.set(-(bb.max.x + bb.min.x) / 2, 2.4, -2.5);
            scene.add(text);
        }

        // Wide lines: a vertex-coloured helix, and the rounded box's edges dashed.
        const positions: Array<f64> = [];
        const colors: Array<f64> = [];
        const c = new THREE.Color();
        for (let i = 0; i <= 120; i++) {
            const t = <f64>i / 120;
            positions.push(Math.cos(t * Math.PI * 6) * 0.6 + 3.2);
            positions.push(t * 2.2);
            positions.push(Math.sin(t * Math.PI * 6) * 0.6 - 0.5);
            c.setHSL(t, 1, 0.5);
            colors.push(c.r); colors.push(c.g); colors.push(c.b);
        }
        const helix = new LineGeometry();
        helix.setPositions(positions);
        helix.setColors(colors);
        scene.add(new Line2(helix, new LineMaterial({ color: 0xffffff, linewidth: 5, vertexColors: true })));
        const edges = new LineSegmentsGeometry().fromEdgesGeometry(new THREE.EdgesGeometry(new THREE.BoxGeometry(0.98, 0.98, 0.98)));
        const outline = new LineSegments2(edges, new LineMaterial({
            color: 0xffe066, linewidth: 3, dashed: true, dashSize: 0.08, gapSize: 0.05,
        }));
        outline.computeLineDistances();
        outline.position.copy(rounded.position);
        scene.add(outline);

        const transform = new TransformControls(this.camera, this.renderer);
        transform.attach(rounded);
        scene.add(transform.getHelper());
        this.tools.push(transform);
        this.transform = transform;

        this.camera.position.set(5, 4, 7);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 0.8, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        const tc = this.transform;
        if (tc != null) tc.mode = this.gizmoMode == 1 ? "rotate" : this.gizmoMode == 2 ? "scale" : "translate";
        const t = (this.time += seconds);
        this.knot.rotation.y = t * 0.5;
        this.knot.rotation.x = Math.sin(t * 0.3) * 0.5;
        const bh = this.boxHelper;
        if (bh != null) bh.update();
        this.spot.position.set(3 * Math.cos(t * 0.4), 3.5, 3 * Math.sin(t * 0.4));
        const sh = this.spotHelper;
        if (sh != null) sh.update();
    }
}
