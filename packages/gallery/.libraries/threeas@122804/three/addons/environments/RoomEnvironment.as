// three.js examples/jsm/environments/RoomEnvironment.js: a neutral studio
// room (boxes, a point light, emissive panels) to make an environment
// from: `scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture`.

import { Scene } from "../../scenes/Scene";
import { BoxGeometry } from "../../geometries/BoxGeometry";
import { MeshStandardMaterial } from "../../materials/MeshStandardMaterial";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { Mesh } from "../../objects/Mesh";
import { PointLight } from "../../lights/PointLight";
import { BackSide } from "../../constants";

export class RoomEnvironment extends Scene {
    constructor() {
        super();
        const geometry = new BoxGeometry();
        geometry.deleteAttribute("uv");
        const roomMaterial = new MeshStandardMaterial({ side: BackSide });
        const boxMaterial = new MeshStandardMaterial();

        const mainLight = new PointLight(0xffffff, 900, 28, 2);
        mainLight.position.set(0.418, 16.199, 0.300);
        this.add(mainLight);

        const room = new Mesh(geometry, roomMaterial);
        room.position.set(-0.757, 13.219, 0.717);
        room.scale.set(31.713, 28.305, 28.591);
        this.add(room);

        this.box(geometry, boxMaterial, -10.906, 2.009, 1.846, -0.195, 2.328, 7.905, 4.651);
        this.box(geometry, boxMaterial, -5.607, -0.754, -0.758, 0.994, 1.970, 1.534, 3.955);
        this.box(geometry, boxMaterial, 6.167, 0.857, 7.803, 0.561, 3.927, 6.285, 3.687);
        this.box(geometry, boxMaterial, -2.017, 0.018, 6.124, 0.333, 2.002, 4.566, 2.064);
        this.box(geometry, boxMaterial, 2.291, -0.756, -2.621, -0.286, 1.546, 1.552, 1.496);
        this.box(geometry, boxMaterial, -2.193, -0.369, -5.547, 0.516, 3.875, 3.487, 2.986);

        this.light(geometry, 50, -16.116, 14.37, 8.208, 0.1, 2.428, 2.739);    // -x right
        this.light(geometry, 50, -16.109, 18.021, -8.207, 0.1, 2.425, 2.751);  // -x left
        this.light(geometry, 17, 14.904, 12.198, -1.832, 0.15, 4.265, 6.331);  // +x
        this.light(geometry, 43, -0.462, 8.89, 14.520, 4.38, 5.441, 0.088);    // +z
        this.light(geometry, 20, 3.235, 11.486, -12.541, 2.5, 2.0, 0.1);       // -z
        this.light(geometry, 100, 0.0, 20.0, 0.0, 1.0, 0.1, 1.0);              // +y
    }

    private box(geometry: BoxGeometry, material: MeshStandardMaterial, x: f64, y: f64, z: f64, ry: f64,
                sx: f64, sy: f64, sz: f64): void {
        const m = new Mesh(geometry, material);
        m.position.set(x, y, z);
        m.rotation.set(0, ry, 0);
        m.scale.set(sx, sy, sz);
        this.add(m);
    }

    private light(geometry: BoxGeometry, intensity: f64, x: f64, y: f64, z: f64, sx: f64, sy: f64, sz: f64): void {
        const material = new MeshBasicMaterial();
        material.color.setScalar(intensity);
        const m = new Mesh(geometry, material);
        m.position.set(x, y, z);
        m.scale.set(sx, sy, sz);
        this.add(m);
    }
}
