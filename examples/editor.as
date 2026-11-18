// Editor: three.js's scene tools. Helpers for the grid, axes, lights, a
// second camera, a box, a plane, an arrow and vertex normals.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { VertexNormalsHelper } from "../three/addons/helpers/VertexNormalsHelper";
import { Context } from "rive/host";

export class Editor extends THREE.ThreeLayout {
    knot: THREE.Mesh = new THREE.Mesh();
    boxHelper: THREE.BoxHelper? = null;
    normals: VertexNormalsHelper? = null;
    spotHelper: THREE.SpotLightHelper? = null;
    spot: THREE.SpotLight = new THREE.SpotLight();
    time: f64 = 0;

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

        this.camera.position.set(5, 4, 7);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 0.8, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
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
