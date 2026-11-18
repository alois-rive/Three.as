// Clipping: three.js's webgl_clipping_stencil, adapted. Three moving
// planes clip a torus knot (clipShadows: its shadow is clipped too); each
// cut is capped by a plane drawn where a stencil mask, built from the
// knot's back faces (increment) and front faces (decrement), is non-zero.
// A second object shows clipIntersection: only the corner where both its
// planes clip is removed.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { Context } from "rive/host";

export class Clipping extends THREE.ThreeLayout {
    planes: Array<THREE.Plane> = [];
    caps: Array<THREE.Mesh> = [];
    knot: THREE.Group = new THREE.Group();
    time: f64 = 0;

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.localClippingEnabled = true;
        renderer.shadowMap.enabled = true;
        const scene = this.scene;
        scene.background = new THREE.Color(0x263238);
        scene.add(new THREE.AmbientLight(0xffffff, 1.5));
        const sun = new THREE.DirectionalLight(0xffffff, 3);
        sun.position.set(5, 10, 7.5);
        sun.castShadow = true;
        sun.shadow.mapSize.set(1024, 1024);
        const sc = sun.shadow.camera as THREE.OrthographicCamera;
        sc.left = -2; sc.right = 2; sc.top = 2; sc.bottom = -2;
        sc.updateProjectionMatrix();
        scene.add(sun);

        this.planes.push(new THREE.Plane(new THREE.Vector3(-1, 0, 0), 0));
        this.planes.push(new THREE.Plane(new THREE.Vector3(0, -1, 0), 0));
        this.planes.push(new THREE.Plane(new THREE.Vector3(0, 0, -1), 0));

        const geometry = new THREE.TorusKnotGeometry(0.4, 0.15, 220, 60);
        const object = new THREE.Group();
        scene.add(object);
        this.knot = object;

        // Per plane: the stencil passes of the knot, then the cap.
        const colors: Array<u32> = [0xe91e63, 0x00bcd4, 0xffc107];
        for (let i = 0; i < this.planes.length; i++) {
            const plane = this.planes[i];
            const order = <f64>(i + 1);
            const back = new THREE.MeshBasicMaterial({
                side: THREE.BackSide, depthWrite: false, depthTest: false, colorWrite: false, stencilWrite: true,
                stencilFunc: THREE.AlwaysStencilFunc, stencilFail: THREE.IncrementWrapStencilOp,
                stencilZFail: THREE.IncrementWrapStencilOp, stencilZPass: THREE.IncrementWrapStencilOp,
                clippingPlanes: [plane],
            });
            const front = new THREE.MeshBasicMaterial({
                side: THREE.FrontSide, depthWrite: false, depthTest: false, colorWrite: false, stencilWrite: true,
                stencilFunc: THREE.AlwaysStencilFunc, stencilFail: THREE.DecrementWrapStencilOp,
                stencilZFail: THREE.DecrementWrapStencilOp, stencilZPass: THREE.DecrementWrapStencilOp,
                clippingPlanes: [plane],
            });
            const m0 = new THREE.Mesh(geometry, back);
            m0.renderOrder = <i32>order;
            object.add(m0);
            const m1 = new THREE.Mesh(geometry, front);
            m1.renderOrder = <i32>order;
            object.add(m1);

            const others: Array<THREE.Plane> = [];
            for (let j = 0; j < this.planes.length; j++) if (j != i) others.push(this.planes[j]);
            const capMaterial = new THREE.MeshStandardMaterial({
                color: colors[i], metalness: 0.1, roughness: 0.75, clippingPlanes: others,
                stencilWrite: true, stencilRef: 0, stencilFunc: THREE.NotEqualStencilFunc,
                stencilFail: THREE.ReplaceStencilOp, stencilZFail: THREE.ReplaceStencilOp,
                stencilZPass: THREE.ReplaceStencilOp,
            });
            const cap = new THREE.Mesh(new THREE.PlaneGeometry(4, 4), capMaterial);
            cap.renderOrder = <i32>order + 1;   // after this plane's stencil passes, before the next plane's
            scene.add(cap);
            this.caps.push(cap);
        }
        // The stencil passes of plane i draw at order i+1, its cap right
        // after: renderOrder is an integer here, so space them out.
        for (let i = 0; i < object.children.length; i++) {
            const m = object.children[i] as THREE.Mesh;
            m.renderOrder = m.renderOrder * 10;
        }
        for (let i = 0; i < this.caps.length; i++) this.caps[i].renderOrder = (i + 1) * 10 + 1;

        // The clipped knot itself.
        const clippedColor = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({
            color: 0xffc107, metalness: 0.1, roughness: 0.75, clippingPlanes: this.planes, clipShadows: true,
        }));
        clippedColor.castShadow = true;
        clippedColor.renderOrder = 60;
        object.add(clippedColor);

        // clipIntersection: only the corner outside both planes goes.
        const ball = new THREE.Mesh(new THREE.SphereGeometry(0.45, 48, 24), new THREE.MeshStandardMaterial({
            color: 0x8bc34a, roughness: 0.5, side: THREE.DoubleSide, clipIntersection: true,
            clippingPlanes: [new THREE.Plane(new THREE.Vector3(1, 0, 0), -1.6), new THREE.Plane(new THREE.Vector3(0, -1, 0), 0)],
        }));
        ball.position.set(1.6, 0, 0);
        ball.castShadow = true;
        scene.add(ball);

        const ground = new THREE.Mesh(new THREE.PlaneGeometry(9, 9), new THREE.MeshStandardMaterial({ color: 0x37474f, roughness: 0.9 }));
        ground.rotation.x = -Math.PI / 2;
        ground.position.y = -1;
        ground.receiveShadow = true;
        scene.add(ground);

        this.camera.position.set(2, 2, 2);
        const controls = new OrbitControls(this.camera, renderer);
        controls.minDistance = 2;
        controls.maxDistance = 20;
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        this.knot.rotation.x += seconds * 0.5;
        this.knot.rotation.y += seconds * 0.2;
        // The planes sweep; each cap lies on its plane, facing the cut.
        for (let i = 0; i < this.planes.length; i++) {
            const plane = this.planes[i];
            plane.constant = Math.sin(t * 0.7 + <f64>i) * 0.25;
            const cap = this.caps[i];
            plane.coplanarPoint(cap.position);
            cap.lookAt<f64>(cap.position.x - plane.normal.x, cap.position.y - plane.normal.y, cap.position.z - plane.normal.z);
        }
    }
}
