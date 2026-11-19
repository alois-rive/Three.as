// three.js CameraHelper: a camera's frustum (near and far rectangles,
// sides), its cone from the eye, an up triangle, the target line and the
// near and far crosses. Call `update()` after the camera's projection
// changed. Depth is [0, 1] (WebGPU), so the near plane is NDC z = 0.

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Camera } from "../cameras/Camera";
import { Vector3 } from "../math/Vector3";
import { Color } from "../math/Color";

const _vector = new Vector3();
// Line endpoints by name, in order.
const LINES: StaticArray<string> = [
    "n1", "n2", "n2", "n4", "n4", "n3", "n3", "n1",
    "f1", "f2", "f2", "f4", "f4", "f3", "f3", "f1",
    "n1", "f1", "n2", "f2", "n3", "f3", "n4", "f4",
    "p", "n1", "p", "n2", "p", "n3", "p", "n4",
    "u1", "u2", "u2", "u3", "u3", "u1",
    "c", "t", "p", "c",
    "cn1", "cn2", "cn3", "cn4", "cf1", "cf2", "cf3", "cf4",
];

export class CameraHelper extends LineSegments {
    camera: Camera;
    pointMap: Map<string, Array<i32>> = new Map<string, Array<i32>>();

    constructor(camera: Camera) {
        const geometry = new BufferGeometry();
        const vertices: Array<f64> = [];
        const colors: Array<f64> = [];
        for (let i = 0; i < LINES.length; i++) {
            for (let k = 0; k < 3; k++) { vertices.push(0); colors.push(0); }
        }
        geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        geometry.setAttribute("color", new Float32BufferAttribute(colors, 3));
        super(geometry, new LineBasicMaterial({ color: 0xffffff, vertexColors: true, toneMapped: false }));
        this.type = "CameraHelper";
        this.camera = camera;
        for (let i = 0; i < LINES.length; i++) {
            const name = LINES[i];
            if (!this.pointMap.has(name)) this.pointMap.set(name, []);
            this.pointMap.get(name).push(i);
        }
        this.matrix = camera.matrixWorld;
        this.matrixAutoUpdate = false;
        this.setColors(new Color(0xffaa00), new Color(0xff0000), new Color(0x00aaff), new Color(0xffffff), new Color(0x333333));
        this.update();
    }

    setColors(frustum: Color, cone: Color, up: Color, target: Color, cross: Color): CameraHelper {
        const a = this.geometry.getAttribute("color")!;
        for (let i = 0; i < LINES.length; i++) {
            const c = i < 24 ? frustum : i < 32 ? cone : i < 38 ? up : i < 42 ? target : cross;
            a.setXYZ(i, c.r, c.g, c.b);
        }
        a.needsUpdate = true;
        return this;
    }

    update(): void {
        const w: f64 = 1, h: f64 = 1;
        this.setPoint("c", 0, 0, 0);
        this.setPoint("t", 0, 0, 1);
        this.setPoint("n1", -w, -h, 0); this.setPoint("n2", w, -h, 0);
        this.setPoint("n3", -w, h, 0); this.setPoint("n4", w, h, 0);
        this.setPoint("f1", -w, -h, 1); this.setPoint("f2", w, -h, 1);
        this.setPoint("f3", -w, h, 1); this.setPoint("f4", w, h, 1);
        this.setPoint("u1", w * 0.7, h * 1.1, 0); this.setPoint("u2", -w * 0.7, h * 1.1, 0);
        this.setPoint("u3", 0, h * 2, 0);
        this.setPoint("cf1", -w, 0, 1); this.setPoint("cf2", w, 0, 1);
        this.setPoint("cf3", 0, -h, 1); this.setPoint("cf4", 0, h, 1);
        this.setPoint("cn1", -w, 0, 0); this.setPoint("cn2", w, 0, 0);
        this.setPoint("cn3", 0, -h, 0); this.setPoint("cn4", 0, h, 0);
        this.geometry.getAttribute("position")!.needsUpdate = true;
        this.geometry.computeBoundingSphere();
    }

    private setPoint(name: string, x: f64, y: f64, z: f64): void {
        // Camera space: the helper's matrix is the camera's matrixWorld.
        _vector.set(x, y, z).applyMatrix4(this.camera.projectionMatrixInverse);
        const points = this.pointMap.get(name);
        const a = this.geometry.getAttribute("position")!;
        for (let i = 0; i < points.length; i++) a.setXYZ(points[i], _vector.x, _vector.y, _vector.z);
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
