// three.js ArrowHelper: an arrow from `origin` along unit `dir`, `length`
// long, with a cone head.

import { Object3D } from "../core/Object3D";
import { Line } from "../objects/Line";
import { Mesh } from "../objects/Mesh";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { ConeGeometry } from "../geometries/ConeGeometry";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Vector3 } from "../math/Vector3";
import { Color } from "../math/Color";

let _lineGeometry: BufferGeometry? = null;
let _coneGeometry: BufferGeometry? = null;
const _axis = new Vector3();

export class ArrowHelper extends Object3D {
    line: Line;
    cone: Mesh;

    constructor(dir: Vector3 = new Vector3(0, 0, 1), origin: Vector3 = new Vector3(0, 0, 0), length: f64 = 1,
                color: u32 = 0xffff00, headLength: f64 = -1, headWidth: f64 = -1) {
        super();
        this.type = "ArrowHelper";
        const hl = headLength < 0 ? length * 0.2 : headLength;
        const hw = headWidth < 0 ? hl * 0.2 : headWidth;
        if (_lineGeometry == null) {
            const g = new BufferGeometry();
            g.setAttribute("position", new Float32BufferAttribute([0, 0, 0, 0, 1, 0], 3));
            _lineGeometry = g;
            const cone = new ConeGeometry(0.5, 1, 5, 1);
            cone.translate(0, -0.5, 0);
            _coneGeometry = cone;
        }
        this.position.copy(origin);
        this.line = new Line(_lineGeometry!, new LineBasicMaterial({ color: color, toneMapped: false }));
        this.line.matrixAutoUpdate = false;
        this.add(this.line);
        this.cone = new Mesh(_coneGeometry!, new MeshBasicMaterial({ color: color, toneMapped: false }));
        this.cone.matrixAutoUpdate = false;
        this.add(this.cone);
        this.setDirection(dir);
        this.setLength(length, hl, hw);
    }

    setDirection(dir: Vector3): void {
        if (dir.y > 0.99999) this.quaternion.set(0, 0, 0, 1);
        else if (dir.y < -0.99999) this.quaternion.set(1, 0, 0, 0);
        else {
            _axis.set(dir.z, 0, -dir.x).normalize();
            const radians = Math.acos(dir.y);
            this.quaternion.setFromAxisAngle(_axis, radians);
        }
    }

    setLength(length: f64, headLength: f64 = -1, headWidth: f64 = -1): void {
        const hl = headLength < 0 ? length * 0.2 : headLength;
        const hw = headWidth < 0 ? hl * 0.2 : headWidth;
        this.line.scale.set(1, Math.max(0.0001, length - hl), 1);
        this.line.updateMatrix();
        this.cone.scale.set(hw, hl, hw);
        this.cone.position.y = length;
        this.cone.updateMatrix();
    }

    setColor(color: Color): void {
        (this.line.material as LineBasicMaterial).color.copy(color);
        (this.cone.material as MeshBasicMaterial).color.copy(color);
    }

    dispose(): void {
        this.line.material.dispose();
        this.cone.material.dispose();
    }
}
