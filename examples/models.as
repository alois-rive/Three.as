// Models: glTF extensions (examples/assets/features.glb, made by
// tools/make_gltf_samples.py). A meshopt-compressed glass torus
// (EXT_meshopt_compression with octahedral, exponential and quaternion
// filters, KHR_materials_transmission / volume / dispersion) spinning on a
// meshopt-compressed track, its rings as compressed line indices; an
// iridescent quantized torus (KHR_mesh_quantization) with a sparse morph
// target; a row of brushed-metal instances (EXT_mesh_gpu_instancing,
// KHR_materials_anisotropy). Lit by a RoomEnvironment.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { GLTFLoader } from "../three/addons/loaders/GLTFLoader";
import { MeshoptDecoder } from "../three/addons/libs/meshopt_decoder";
import { RoomEnvironment } from "../three/addons/environments/RoomEnvironment";
import { Context } from "rive/host";
import { Promise } from "rive/promise";

const DUCK_URL = "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/Duck/glTF/Duck.gltf";

export class Models extends THREE.ThreeLayout {
    mixer: THREE.AnimationMixer? = null;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x15181f);
        const pmrem = new THREE.PMREMGenerator(this.renderer);
        scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
        this.renderer!.toneMapping = THREE.ACESFilmicToneMapping;
        const sun = new THREE.DirectionalLight(0xffffff, 1.5);
        sun.position.set(-2, 4, 3);
        scene.add(sun);
        // Something behind the glass to refract.
        const stripes = new THREE.Mesh(new THREE.PlaneGeometry(8, 4),
            new THREE.MeshBasicMaterial({ map: this.stripes() }));
        stripes.position.set(0, 0.5, -2.5);
        scene.add(stripes);

        // Decoded in a Rive job; the scene fills in a frame or two later.
        this.load(new GLTFLoader(context).setMeshoptDecoder(MeshoptDecoder));
        // A .gltf with external .bin and .png files, over the network where
        // the host allows it.
        this.loadDuck(new GLTFLoader(context));

        this.camera.position.set(0, 3.2, 6.2);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 0, 0);
        controls.enableDamping = true;
        controls.update();
        this.controls = controls;
        return true;
    }

    async load(loader: GLTFLoader): Promise<void> {
        const settled = await loader.loadAsync("features").settled();
        if (!settled.ok) {
            this.context!.log("features.glb: " + settled.error);
            return;
        }
        const gltf = settled.value;
        this.scene.add(gltf.scene);
        const mixer = new THREE.AnimationMixer(gltf.scene);
        for (let i = 0; i < gltf.animations.length; i++) mixer.clipAction(gltf.animations[i]).play();
        this.mixer = mixer;
    }

    async loadDuck(loader: GLTFLoader): Promise<void> {
        const settled = await loader.loadAsync(DUCK_URL).settled();
        if (!settled.ok) {
            this.context!.log("Duck.gltf: " + settled.error);
            return;
        }
        const duck = settled.value.scene;
        duck.scale.setScalar(0.7);
        duck.position.set(2.4, -0.4, 0.4);
        duck.rotation.y = -0.9;
        this.scene.add(duck);
        this.context!.log("Duck.gltf: loaded");
    }

    private stripes(): THREE.DataTexture {
        const w = 64, h = 4;
        const data = new Uint8Array(w * h * 4);
        for (let y = 0; y < h; y++) {
            for (let x = 0; x < w; x++) {
                const o = (y * w + x) * 4;
                const on = ((x >> 2) & 1) == 0;
                data[o] = on ? 240 : 30; data[o + 1] = on ? 200 : 40; data[o + 2] = on ? 90 : 70; data[o + 3] = 255;
            }
        }
        const t = new THREE.DataTexture(data, w, h);
        t.colorSpace = THREE.SRGBColorSpace;
        t.needsUpdate = true;
        return t;
    }

    override animate(seconds: f64): void {
        const mixer = this.mixer;
        if (mixer != null) mixer.update(seconds);
    }
}
