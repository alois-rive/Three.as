// Interactive: a ThreeLayout app. Drag to orbit (OrbitControls, damped),
// scroll to zoom; click the switch on the left panel (a live Rive artboard:
// the click reaches its state machine through a raycast); hover the cubes;
// the right "TV" shows a second scene through a RenderTarget; the propeller
// turns with the Screen artboard's animated Spinner node.

import * as THREE from "../../three/Three";
import { OrbitControls } from "../../three/addons/controls/OrbitControls";
import { Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { PointerEvent } from "rive/events";
import { Artboard } from "rive/artboard";

export class Interactive extends THREE.ThreeLayout {
    @input toggle: Artboard? = null;
    @input screen: Artboard? = null;

    panelMaterial: THREE.MeshBasicMaterial = new THREE.MeshBasicMaterial();
    toggleTexture: THREE.ArtboardTexture? = null;
    screenTexture: THREE.ArtboardTexture? = null;
    // Object3D, not Mesh: arrays are invariant and intersectObjects takes Object3D.
    cubes: Array<THREE.Object3D> = [];
    propeller: THREE.Mesh = new THREE.Mesh();

    // The scene shown on the TV.
    target: THREE.RenderTarget = new THREE.RenderTarget(320, 200, { samples: 4 });
    tvScene: THREE.Scene = new THREE.Scene();
    tvCamera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(40, 1.6, 0.1, 20);
    knot: THREE.Mesh = new THREE.Mesh();

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x101318);
        scene.add(new THREE.HemisphereLight(0xc8d8ff, 0x302820, 1.6));
        const sun = new THREE.DirectionalLight(0xffffff, 2.2);
        sun.position.set(3, 5, 4);
        scene.add(sun);

        const floor = new THREE.Mesh(new THREE.PlaneGeometry(20, 20),
            new THREE.MeshStandardMaterial({ color: 0x2a2f3a, roughness: 0.95 }));
        floor.rotation.x = -Math.PI / 2;
        scene.add(floor);

        // The switch panel (its map attaches when the input is bound).
        const panel = new THREE.Mesh(new THREE.PlaneGeometry(1.8, 1.0), this.panelMaterial);
        panel.position.set(-1.25, 1.2, 0);
        panel.rotation.y = 0.25;
        scene.add(panel);

        // The TV: a frame and a screen showing the render target.
        const tv = new THREE.Mesh(new THREE.BoxGeometry(1.9, 1.25, 0.12),
            new THREE.MeshStandardMaterial({ color: 0x16181d, roughness: 0.4 }));
        tv.position.set(1.25, 1.2, 0);
        tv.rotation.y = -0.25;
        const glass = new THREE.Mesh(new THREE.PlaneGeometry(1.76, 1.1), new THREE.MeshBasicMaterial({ map: this.target.texture }));
        glass.position.z = 0.061;
        tv.add(glass);
        scene.add(tv);

        // Cubes to hover.
        for (let i = 0; i < 3; i++) {
            const cube = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5),
                new THREE.MeshStandardMaterial({ color: 0x4d9de0, roughness: 0.5 }));
            cube.position.set(<f64>i * 0.9 - 0.9, 0.25, 1.4);
            scene.add(cube);
            this.cubes.push(cube);
        }

        // The propeller, turned by a Rive node.
        this.propeller = new THREE.Mesh(new THREE.BoxGeometry(1.4, 0.12, 0.05),
            new THREE.MeshStandardMaterial({ color: 0xffb400, metalness: 0.5, roughness: 0.3 }));
        this.propeller.position.set(0, 2.5, -0.5);
        scene.add(this.propeller);

        // The TV's own scene.
        this.tvScene.background = new THREE.Color(0x3a1c71);
        this.tvScene.add(new THREE.AmbientLight(0xffffff, 1.2));
        const tvLight = new THREE.DirectionalLight(0xffd6a5, 3);
        tvLight.position.set(1, 2, 3);
        this.tvScene.add(tvLight);
        this.knot = new THREE.Mesh(new THREE.TorusKnotGeometry(0.6, 0.2, 128, 16),
            new THREE.MeshStandardMaterial({ color: 0xff7eb6, roughness: 0.3 }));
        this.tvScene.add(this.knot);
        this.tvCamera.position.set(0, 0, 3);

        this.camera.position.set(0, 1.9, 5.2);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 1, 0);
        controls.enableDamping = true;
        controls.maxPolarAngle = Math.PI * 0.48;
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        // Artboard inputs may bind after init.
        const toggle = this.toggle;
        if (this.toggleTexture == null && toggle != null) {
            const t = new THREE.ArtboardTexture(toggle, 720, 400);
            this.toggleTexture = t;
            this.panelMaterial.map = t;
        }
        const screen = this.screen;
        if (this.screenTexture == null && screen != null) {
            this.screenTexture = new THREE.ArtboardTexture(screen, 64, 64);
        }
        const t = this.toggleTexture;
        if (t != null) t.advance(seconds);
        const s = this.screenTexture;
        if (s != null) {
            s.advance(seconds);
            const spinner = s.artboard.node("Spinner");
            if (spinner != null) THREE.copyNodeTransform(this.propeller, spinner, 0);
        }
        this.propeller.position.set(0, 2.5, -0.5);   // keep the place, take the turn
        this.knot.rotation.x += seconds * 0.7;
        this.knot.rotation.y += seconds * 0.4;
    }

    override onPointerMove(event: PointerEvent): void {
        const hits = this.raycaster.intersectObjects(this.cubes, false);
        for (let i = 0; i < this.cubes.length; i++) {
            const m = (this.cubes[i] as THREE.Mesh).material as THREE.MeshStandardMaterial;
            const hovered = hits.length > 0 && hits[0].object === this.cubes[i];
            m.emissive.setHex(hovered ? 0xff8800 : 0x000000);
        }
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer;
        if (r == null) return;
        r.setRenderTarget(this.target);
        r.render(this.tvScene, this.tvCamera);
        r.setRenderTarget(null);
        super.draw(renderer);
    }
}
