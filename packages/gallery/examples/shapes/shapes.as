// Shapes: three.js's heart, extruded with a bevel; a tube along a closed
// Catmull-Rom knot; a flat shape with a hole; and a star drawn in Rive (the
// Emblem artboard's StarPath), read as a path and extruded.

import * as THREE from "../../three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Artboard } from "rive/artboard";

function heartShape(): THREE.Shape {
    const s = new THREE.Shape();
    const x = 0.0, y = 0.0;
    s.moveTo(x + 25, y + 25);
    s.bezierCurveTo(x + 25, y + 25, x + 20, y, x, y);
    s.bezierCurveTo(x - 30, y, x - 30, y + 35, x - 30, y + 35);
    s.bezierCurveTo(x - 30, y + 55, x - 10, y + 77, x + 25, y + 95);
    s.bezierCurveTo(x + 60, y + 77, x + 80, y + 55, x + 80, y + 35);
    s.bezierCurveTo(x + 80, y + 35, x + 80, y, x + 50, y);
    s.bezierCurveTo(x + 35, y, x + 25, y + 25, x + 25, y + 25);
    return s;
}

export class Shapes extends Layout {
    @input emblem: Artboard? = null;

    renderer: THREE.GPURenderer? = null;
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(45, 1, 0.1, 100);
    spinners: Array<THREE.Object3D> = [];
    star: THREE.Mesh? = null;
    time: f64 = 0;

    override init(context: Context): bool {
        const renderer = new THREE.GPURenderer(context, { antialias: true });
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        this.renderer = renderer;
        const scene = this.scene;
        scene.background = new THREE.Color(0x14161c);
        scene.add(new THREE.HemisphereLight(0xdde8ff, 0x302820, 1.8));
        const sun = new THREE.DirectionalLight(0xffffff, 2.5);
        sun.position.set(2, 4, 6);
        scene.add(sun);

        // The heart (three.js's webgl_geometry_shapes), bevelled.
        const options = new THREE.ExtrudeGeometryOptions();
        options.depth = 8;
        options.bevelThickness = 2;
        options.bevelSize = 2;
        options.bevelSegments = 4;
        const heart = new THREE.Mesh(new THREE.ExtrudeGeometry([heartShape()], options),
            new THREE.MeshPhysicalMaterial({ color: 0xe0245e, roughness: 0.35, clearcoat: 1 }));
        heart.geometry.center();
        heart.scale.setScalar(0.022);
        heart.rotation.z = Math.PI;
        const heartPivot = new THREE.Group();
        heartPivot.add(heart);
        heartPivot.position.set(-2.4, 0.9, 0);
        scene.add(heartPivot);
        this.spinners.push(heartPivot);

        // A tube along a closed knot.
        const knot: Array<THREE.Vector3> = [];
        for (let i = 0; i < 12; i++) {
            const t = <f64>i / 12 * Math.PI * 2;
            knot.push(new THREE.Vector3(Math.sin(t) + 2 * Math.sin(2 * t), Math.cos(t) - 2 * Math.cos(2 * t), -Math.sin(3 * t))
                .multiplyScalar(0.3));
        }
        const tube = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(knot, true), 160, 0.12, 12, true),
            new THREE.MeshStandardMaterial({ color: 0x2ec4b6, roughness: 0.3, metalness: 0.1 }));
        tube.position.set(0, 0.9, 0);
        scene.add(tube);
        this.spinners.push(tube);

        // A flat shape with a hole.
        const disc = new THREE.Shape();
        disc.absarc(0, 0, 0.9, 0, Math.PI * 2, false);
        const hole = new THREE.Path();
        hole.absarc(0.25, 0.1, 0.35, 0, Math.PI * 2, true);
        disc.holes.push(hole);
        const flat = new THREE.Mesh(new THREE.ShapeGeometry([disc], 32),
            new THREE.MeshStandardMaterial({ color: 0xffd166, side: THREE.DoubleSide, roughness: 0.6 }));
        flat.position.set(2.4, 0.9, 0);
        scene.add(flat);
        this.spinners.push(flat);

        this.camera.position.set(0, 0.6, 7.5);
        this.camera.lookAt(0, 0, 0);
        return true;
    }

    /// The star from the Rive artboard, extruded (once the input is bound).
    private makeStar(): void {
        const emblem = this.emblem;
        if (emblem == null || this.star != null) return;
        // Paths are built when the artboard updates: advance it first.
        const instance = emblem.instance();
        instance.advance(0);
        const node = instance.node("StarPath");
        if (node == null) return;
        const path = node.asPath();
        if (path == null || path.length == 0) return;
        const options = new THREE.ExtrudeGeometryOptions();
        options.depth = 0.25;
        options.bevelThickness = 0.08;
        options.bevelSize = 0.06;
        const geometry = new THREE.ExtrudeGeometry(THREE.shapesFromRivePath(path, 0.012, true), options);
        geometry.center();
        const star = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: 0xffb400, metalness: 0.6, roughness: 0.35 }));
        star.position.set(0, -1.6, 0);
        this.scene.add(star);
        this.spinners.push(star);
        this.star = star;
    }

    override resize(width: f64, height: f64, scale: f64): void {
        const renderer = this.renderer!;
        renderer.setPixelRatio(scale);
        renderer.setSize(width, height);
        this.camera.aspect = width / height;
        this.camera.updateProjectionMatrix();
    }

    override advance(seconds: f64): bool {
        this.makeStar();
        const t = (this.time += seconds);
        for (let i = 0; i < this.spinners.length; i++) {
            this.spinners[i].rotation.y = t * 0.6 + <f64>i;
            this.spinners[i].rotation.x = Math.sin(t * 0.5 + <f64>i) * 0.3;
        }
        return true;
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer!;
        r.render(this.scene, this.camera);
        r.present(renderer);
    }
}
