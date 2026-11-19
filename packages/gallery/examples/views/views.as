// Views: several views in one canvas, as three.js's camera_array,
// multiple_views, multiple_scenes and StereoEffect examples do it. Left: an
// ArrayCamera of four sub-cameras, each in its viewport. Top right: a
// StereoCamera's two eyes side by side. Bottom right: a second scene in its
// scissor rectangle. Over it all, a picture-in-picture view from above,
// cleared inside its scissor.

import * as THREE from "../../three/Three";
import { Context } from "rive/host";

export class Views extends THREE.ThreeLayout {
    sceneB: THREE.Scene = new THREE.Scene();
    cameraB: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(45, 1, 0.1, 50);
    top: THREE.OrthographicCamera = new THREE.OrthographicCamera(-4, 4, 3, -3, 0.1, 50);
    array: THREE.ArrayCamera = new THREE.ArrayCamera();
    stereo: THREE.StereoCamera = new THREE.StereoCamera();
    spinners: Array<THREE.Mesh> = [];
    gem: THREE.Mesh = new THREE.Mesh();
    time: f64 = 0;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x10141c);
        scene.add(new THREE.HemisphereLight(0xbfd4ff, 0x302820, 1.2));
        const sun = new THREE.DirectionalLight(0xffffff, 2.5);
        sun.position.set(3, 6, 4);
        scene.add(sun);
        const floor = new THREE.Mesh(new THREE.PlaneGeometry(12, 12),
            new THREE.MeshStandardMaterial({ color: 0x3a4250, roughness: 0.9 }));
        floor.rotation.x = -Math.PI / 2;
        scene.add(floor);
        const colors: Array<u32> = [0xff5a5f, 0x3ec1d3, 0xffc145, 0x8ac926, 0xb388eb];
        for (let i = 0; i < colors.length; i++) {
            const a = <f64>i / <f64>colors.length * Math.PI * 2;
            const geometry: THREE.BufferGeometry = i % 2 == 0
                ? new THREE.TorusKnotGeometry(0.45, 0.15, 96, 12) : new THREE.BoxGeometry(0.8, 0.8, 0.8);
            const mesh = new THREE.Mesh(geometry,
                new THREE.MeshStandardMaterial({ color: colors[i], roughness: 0.35, metalness: 0.1 }));
            mesh.position.set(Math.cos(a) * 2.4, 0.8, Math.sin(a) * 2.4);
            scene.add(mesh);
            this.spinners.push(mesh);
        }
        this.camera.position.set(0, 3.2, 6.5);
        this.camera.lookAt(0, 0.6, 0);
        this.top.position.set(0, 10, 0);
        this.top.lookAt(0, 0, 0);

        // A second scene.
        const b = this.sceneB;
        b.background = new THREE.Color(0x2a1640);
        b.add(new THREE.AmbientLight(0xffffff, 0.4));
        const key = new THREE.PointLight(0xffd0a0, 25, 0, 2);
        key.position.set(2, 2, 3);
        b.add(key);
        this.gem = new THREE.Mesh(new THREE.IcosahedronGeometry(1, 0),
            new THREE.MeshPhongMaterial({ color: 0xff7eb6, shininess: 80, flatShading: true }));
        b.add(this.gem);
        const wire = new THREE.Mesh(new THREE.IcosahedronGeometry(1.5, 1),
            new THREE.MeshBasicMaterial({ color: 0xc9a7ff, wireframe: true }));
        this.gem.add(wire);
        this.cameraB.position.set(0, 0, 4.5);

        // Four sub-cameras around the scene (viewports set on resize).
        const cameras: Array<THREE.PerspectiveCamera> = [];
        for (let i = 0; i < 4; i++) {
            const sub = new THREE.PerspectiveCamera(40, 1, 0.1, 50);
            const a = <f64>i * Math.PI / 2 + Math.PI / 4;
            sub.position.set(Math.cos(a) * 7, 2.5 + <f64>i * 0.8, Math.sin(a) * 7);
            sub.lookAt(0, 0.6, 0);
            sub.viewport = new THREE.Vector4();
            cameras.push(sub);
        }
        this.array = new THREE.ArrayCamera(cameras);
        this.stereo.eyeSep = 0.3;
        return true;
    }

    override onResize(width: f64, height: f64): void {
        const r = this.renderer!.getPixelRatio();
        const cw = width / 4, ch = height / 2;
        for (let i = 0; i < 4; i++) {
            const sub = this.array.cameras[i];
            const col = i % 2, row = i / 2;
            const x = <f64>col, y = <f64>row;
            sub.viewport!.set(Math.floor(x * cw * r), Math.floor(y * ch * r), Math.ceil(cw * r), Math.ceil(ch * r));
            sub.aspect = cw / ch;
            sub.updateProjectionMatrix();
        }
        // The stereo pair: two eyes of width / 4 by height / 2.
        const main = this.camera as THREE.PerspectiveCamera;
        main.aspect = (width / 2) / (height / 2);
        this.camera.updateProjectionMatrix();
        this.stereo.aspect = 0.5;
        this.cameraB.aspect = (width / 2) / (height / 2);
        this.cameraB.updateProjectionMatrix();
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        for (let i = 0; i < this.spinners.length; i++) {
            const m = this.spinners[i];
            m.rotation.x = t * 0.7 + <f64>i;
            m.rotation.y = t * 0.9;
        }
        this.gem.rotation.y = t * 0.6;
        this.gem.rotation.x = t * 0.25;
        this.camera.position.set(Math.sin(t * 0.3) * 6.5, 3.2, Math.cos(t * 0.3) * 6.5);
        this.camera.lookAt(0, 0.6, 0);
    }

    override renderFrame(): void {
        const r = this.renderer!;
        const w = this.width, h = this.height;
        // Left half: the ArrayCamera (its first view clears the canvas).
        r.setScissorTest(false);
        r.render(this.scene, this.array);

        r.setScissorTest(true);
        // Top right: the stereo pair.
        this.camera.updateMatrixWorld();
        this.stereo.update(this.camera as THREE.PerspectiveCamera);
        r.setScissor(w / 2, h / 2, w / 4, h / 2);
        r.setViewport(w / 2, h / 2, w / 4, h / 2);
        r.render(this.scene, this.stereo.cameraL);
        r.setScissor(w * 3 / 4, h / 2, w / 4, h / 2);
        r.setViewport(w * 3 / 4, h / 2, w / 4, h / 2);
        r.render(this.scene, this.stereo.cameraR);

        // Bottom right: another scene.
        r.setScissor(w / 2, 0, w / 2, h / 2);
        r.setViewport(w / 2, 0, w / 2, h / 2);
        r.render(this.sceneB, this.cameraB);

        // Picture in picture from above, cleared to its own colour.
        const pw = 150.0, ph = 112.5;
        r.setScissor(w - pw - 12, 12, pw, ph);
        r.setViewport(w - pw - 12, 12, pw, ph);
        r.render(this.scene, this.top);

        r.setScissorTest(false);
        r.setViewport(0, 0, w, h);
    }
}
