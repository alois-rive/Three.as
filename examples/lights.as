// Lights: a night street. RectAreaLights (linearly transformed cosines)
// glow on a glossy floor and the facades, a row of 20 warm point lights
// with short ranges (each surface is lit by the few that reach it), and a
// LightProbe projected from an HDR environment for the soft fill. A low
// moon casts long shadows down the street through cascaded shadow maps
// (the CSM addon, four cascades).

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { RGBELoader } from "../three/addons/loaders/RGBELoader";
import { LightProbeGenerator } from "../three/addons/lights/LightProbeGenerator";
import { CSM } from "../three/addons/csm/CSM";
import { Context } from "rive/host";

export class Lights extends THREE.ThreeLayout {
    panels: Array<THREE.RectAreaLight> = [];
    bulbs: Array<THREE.PointLight> = [];
    csm: CSM? = null;
    time: f64 = 0;

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        const scene = this.scene;
        scene.background = new THREE.Color(0x05060a);
        scene.fog = new THREE.FogExp2(0x05060a, 0.03);

        // A soft fill from an HDR studio, as spherical harmonics.
        const hdr = new RGBELoader(context).load("studio_rgbe");
        if (hdr != null) {
            const probe = LightProbeGenerator.fromEquirectangular(hdr, 2);
            probe.intensity = 0.12;
            scene.add(probe);
        }

        const floor = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), new THREE.MeshStandardMaterial({
            color: 0x202226, roughness: 0.18, metalness: 0.0,
        }));
        floor.rotation.x = -Math.PI / 2;
        floor.receiveShadow = true;
        scene.add(floor);
        const facade = new THREE.MeshStandardMaterial({ color: 0x8a8f99, roughness: 0.7 });
        for (let side = -1; side <= 1; side += 2) {
            const wall = new THREE.Mesh(new THREE.BoxGeometry(0.4, 6, 40), facade);
            wall.position.set(<f64>side * 5, 3, 0);
            wall.receiveShadow = true;
            scene.add(wall);
        }

        // Area lights: four coloured panels.
        const colors: Array<u32> = [0xff3b6b, 0x3bc8ff, 0xffd23b, 0x7cff6b];
        for (let i = 0; i < 4; i++) {
            const light = new THREE.RectAreaLight(colors[i], 6, 1.6, 3.2);
            const side: f64 = i % 2 == 0 ? -1 : 1;
            light.position.set(side * 4.75, 2.4, <f64>i * 3.5 - 6);
            light.lookAt<f64>(0, 2.4, <f64>i * 3.5 - 6);
            scene.add(light);
            this.panels.push(light);
            // The panel itself, glowing.
            const panel = new THREE.Mesh(new THREE.PlaneGeometry(1.6, 3.2), new THREE.MeshBasicMaterial({ color: colors[i] }));
            panel.position.copy(light.position);
            panel.quaternion.copy(light.quaternion);
            panel.rotateY(Math.PI);
            scene.add(panel);
        }

        // A row of street lamps: short-range point lights.
        const bulbGeometry = new THREE.SphereGeometry(0.07, 12, 6);
        const bulbMaterial = new THREE.MeshBasicMaterial({ color: 0xffd9a0 });
        for (let i = 0; i < 20; i++) {
            const lamp = new THREE.PointLight(0xffb070, 12, 4.5, 2);
            lamp.position.set(i % 2 == 0 ? -2.2 : 2.2, 2.6, <f64>(i / 2) * 2.4 - 11);
            scene.add(lamp);
            this.bulbs.push(lamp);
            const bulb = new THREE.Mesh(bulbGeometry, bulbMaterial);
            bulb.position.copy(lamp.position);
            scene.add(bulb);
        }

        // Things on the street.
        const knot = new THREE.Mesh(new THREE.TorusKnotGeometry(0.5, 0.18, 160, 24), new THREE.MeshPhysicalMaterial({
            color: 0xdddddd, roughness: 0.25, metalness: 0.9, clearcoat: 1,
        }));
        knot.position.set(0, 1.0, -1);
        knot.castShadow = true;
        scene.add(knot);
        const ball = new THREE.Mesh(new THREE.SphereGeometry(0.6, 48, 24), new THREE.MeshStandardMaterial({
            color: 0xffffff, roughness: 0.5,
        }));
        ball.position.set(1.2, 0.6, 3);
        ball.castShadow = true;
        ball.receiveShadow = true;
        scene.add(ball);
        // Pillars down the street, near and far (the cascades cover both).
        const pillar = new THREE.BoxGeometry(0.3, 2.2, 0.3);
        const stone = new THREE.MeshStandardMaterial({ color: 0x9aa0aa, roughness: 0.8 });
        for (let i = 0; i < 8; i++) {
            const p = new THREE.Mesh(pillar, stone);
            p.position.set(i % 2 == 0 ? -3.6 : 3.6, 1.1, <f64>i * -3 + 6);
            p.castShadow = true;
            p.receiveShadow = true;
            scene.add(p);
        }

        // Moonlight with cascaded shadows.
        renderer.shadowMap.enabled = true;
        renderer.shadowMap.type = THREE.PCFSoftShadowMap;
        const csm = new CSM({
            camera: this.camera, parent: scene, cascades: 4, maxFar: 40, mode: "practical", shadowMapSize: 2048,
            lightDirection: new THREE.Vector3(-1, -1.2, -0.7).normalize(), lightIntensity: 1.2, lightMargin: 20,
            lightFar: 100, shadowBias: -0.0004,
        });
        for (let i = 0; i < csm.lights.length; i++) {
            csm.lights[i].color.setHex(0x9fb6ff);
            csm.lights[i].shadow.normalBias = 0.02;
        }
        this.csm = csm;

        this.camera.position.set(0, 2.2, 9);
        const controls = new OrbitControls(this.camera, renderer);
        controls.target.set(0, 1.4, 0);
        controls.update();
        this.controls = controls;
        csm.updateFrustums();
        return true;
    }

    override onResize(width: f64, height: f64): void {
        const csm = this.csm;
        if (csm != null) csm.updateFrustums();
    }

    override animate(seconds: f64): void {
        const csm = this.csm;
        if (csm != null) csm.update();
        const t = (this.time += seconds);
        for (let i = 0; i < this.panels.length; i++) {
            this.panels[i].intensity = 5 + 2 * Math.sin(t * 1.3 + <f64>i * 1.7);
        }
    }
}
