// Model: a glTF 2.0 binary (examples/assets/sample.glb, made by
// tools/make_sample_glb.py) loaded with GLTFLoader from a BlobAsset, its
// two clips playing in an AnimationMixer: a node hierarchy (an arm with a
// cubic-spline elbow), a skinned tail with a morph target, a stepped pane,
// an embedded PNG texture and a glTF point light.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { GLTFLoader } from "../three/addons/loaders/GLTFLoader";
import { Context } from "rive/host";

export class Model extends THREE.ThreeLayout {
    mixer: THREE.AnimationMixer? = null;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x1a1d24);
        scene.add(new THREE.HemisphereLight(0xe0e8ff, 0x302820, 1.4));
        const sun = new THREE.DirectionalLight(0xffffff, 2);
        sun.position.set(-2, 4, 3);
        scene.add(sun);

        const gltf = new GLTFLoader(context).load("sample");
        if (gltf != null) {
            scene.add(gltf.scene);
            const mixer = new THREE.AnimationMixer(gltf.scene);
            for (let i = 0; i < gltf.animations.length; i++) mixer.clipAction(gltf.animations[i]).play();
            this.mixer = mixer;
            context.log("sample.glb: " + gltf.animations.length.toString() + " clips, "
                + gltf.cameras.length.toString() + " camera(s), generator " + gltf.generator);
        }

        this.camera.position.set(2.2, 2.0, 4.2);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 0.8, 0);
        controls.enableDamping = true;
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        const mixer = this.mixer;
        if (mixer != null) mixer.update(seconds);
    }
}
