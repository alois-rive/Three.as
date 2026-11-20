// three.js DirectionalLightHelper, PointLightHelper, SpotLightHelper and
// HemisphereLightHelper. Call `update()` after the light changed (as
// three.js); each follows its light's world matrix.

import { Object3D } from "../core/Object3D";
import { Line, LineSegments } from "../objects/Line";
import { Mesh } from "../objects/Mesh";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute, BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { SphereGeometry } from "../geometries/SphereGeometry";
import { OctahedronGeometry } from "../geometries/PolyhedronGeometry";
import { DirectionalLight } from "../lights/DirectionalLight";
import { PointLight } from "../lights/PointLight";
import { SpotLight } from "../lights/SpotLight";
import { HemisphereLight } from "../lights/HemisphereLight";
import { Vector3 } from "../math/Vector3";
import { Color } from "../math/Color";

const _v1 = new Vector3();
const _v2 = new Vector3();
const _v3 = new Vector3();
const _color1 = new Color();
const _color2 = new Color();

export class DirectionalLightHelper extends Object3D {
    light: DirectionalLight;
    color: i32;
    lightPlane: Line;
    targetLine: Line;

    /// `color` -1 follows the light's colour.
    constructor(light: DirectionalLight, size: f64 = 1, color: i32 = -1) {
        super();
        this.light = light;
        this.matrix = light.matrixWorld;
        this.matrixAutoUpdate = false;
        this.color = color;
        this.type = "DirectionalLightHelper";
        const g = new BufferGeometry();
        g.setAttribute("position", new Float32BufferAttribute(
            [-size, size, 0, size, size, 0, size, -size, 0, -size, -size, 0, -size, size, 0], 3));
        this.lightPlane = new Line(g, new LineBasicMaterial({ fog: false, toneMapped: false }));
        this.add(this.lightPlane);
        const t = new BufferGeometry();
        t.setAttribute("position", new Float32BufferAttribute([0, 0, 0, 0, 0, 1], 3));
        this.targetLine = new Line(t, new LineBasicMaterial({ fog: false, toneMapped: false }));
        this.add(this.targetLine);
        this.update();
    }

    update(): void {
        this.light.updateWorldMatrix(true, false);
        this.light.target.updateWorldMatrix(true, false);
        _v1.setFromMatrixPosition(this.light.matrixWorld);
        _v2.setFromMatrixPosition(this.light.target.matrixWorld);
        _v3.subVectors(_v2, _v1);
        this.lightPlane.lookAt<f64>(_v2.x, _v2.y, _v2.z);
        const c = this.color >= 0 ? _color1.setHex(<u32>this.color) : _color1.copy(this.light.color);
        (this.lightPlane.material as LineBasicMaterial).color.copy(c);
        (this.targetLine.material as LineBasicMaterial).color.copy(c);
        this.targetLine.lookAt<f64>(_v2.x, _v2.y, _v2.z);
        this.targetLine.scale.z = _v3.length();
    }

    dispose(): void {
        this.lightPlane.geometry.dispose();
        this.lightPlane.material.dispose();
        this.targetLine.geometry.dispose();
        this.targetLine.material.dispose();
    }
}

export class PointLightHelper extends Mesh {
    light: PointLight;
    color: i32;

    constructor(light: PointLight, sphereSize: f64 = 1, color: i32 = -1) {
        super(new SphereGeometry(sphereSize, 4, 2), new MeshBasicMaterial({ wireframe: true, fog: false, toneMapped: false }));
        this.light = light;
        this.color = color;
        this.type = "PointLightHelper";
        this.matrix = light.matrixWorld;
        this.matrixAutoUpdate = false;
        this.update();
    }

    update(): void {
        this.light.updateWorldMatrix(true, false);
        const m = this.material as MeshBasicMaterial;
        if (this.color >= 0) m.color.setHex(<u32>this.color);
        else m.color.copy(this.light.color);
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}

export class SpotLightHelper extends Object3D {
    light: SpotLight;
    color: i32;
    cone: LineSegments;

    constructor(light: SpotLight, color: i32 = -1) {
        super();
        this.light = light;
        this.matrixAutoUpdate = false;
        this.color = color;
        this.type = "SpotLightHelper";
        const positions: Array<f64> = [0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, -1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, -1, 1];
        for (let i = 0, j = 1, l = 32; i < l; i++, j++) {
            const p1 = <f64>i / <f64>l * Math.PI * 2;
            const p2 = <f64>j / <f64>l * Math.PI * 2;
            positions.push(Math.cos(p1)); positions.push(Math.sin(p1)); positions.push(1);
            positions.push(Math.cos(p2)); positions.push(Math.sin(p2)); positions.push(1);
        }
        const g = new BufferGeometry();
        g.setAttribute("position", new Float32BufferAttribute(positions, 3));
        this.cone = new LineSegments(g, new LineBasicMaterial({ fog: false, toneMapped: false }));
        this.add(this.cone);
        this.update();
    }

    update(): void {
        this.light.updateWorldMatrix(true, false);
        this.light.target.updateWorldMatrix(true, false);
        // Follow the light's world matrix (three.js copies it with the
        // parent's inverse).
        if (this.parent != null) {
            this.parent!.updateWorldMatrix(true, false);
            this.matrix.copy(this.parent!.matrixWorld).invert().multiply(this.light.matrixWorld);
        } else {
            this.matrix.copy(this.light.matrixWorld);
        }
        this.matrixWorld.copy(this.light.matrixWorld);
        const coneLength = this.light.distance > 0 ? this.light.distance : 1000;
        const coneWidth = coneLength * Math.tan(this.light.angle);
        this.cone.scale.set(coneWidth, coneWidth, coneLength);
        _v1.setFromMatrixPosition(this.light.target.matrixWorld);
        this.cone.lookAt<f64>(_v1.x, _v1.y, _v1.z);
        const m = this.cone.material as LineBasicMaterial;
        if (this.color >= 0) m.color.setHex(<u32>this.color);
        else m.color.copy(this.light.color);
    }

    dispose(): void {
        this.cone.geometry.dispose();
        this.cone.material.dispose();
    }
}

export class HemisphereLightHelper extends Object3D {
    light: HemisphereLight;
    color: i32;
    mesh: Mesh;

    constructor(light: HemisphereLight, size: f64 = 1, color: i32 = -1) {
        super();
        this.light = light;
        this.matrix = light.matrixWorld;
        this.matrixAutoUpdate = false;
        this.color = color;
        this.type = "HemisphereLightHelper";
        const geometry = new OctahedronGeometry(size);
        geometry.rotateY(Math.PI * 0.5);
        const position = geometry.getAttribute("position")!;
        geometry.setAttribute("color", new BufferAttribute(new Float32Array(position.count * 3), 3));
        this.mesh = new Mesh(geometry, new MeshBasicMaterial({ wireframe: true, fog: false, toneMapped: false,
            vertexColors: true }));
        this.add(this.mesh);
        this.update();
    }

    update(): void {
        const m = this.mesh.material as MeshBasicMaterial;
        if (this.color >= 0) {
            m.vertexColors = false;
            m.color.setHex(<u32>this.color);
        } else {
            const colors = this.mesh.geometry.getAttribute("color")!;
            _color1.copy(this.light.color);
            _color2.copy(this.light.groundColor);
            const n = colors.count;
            for (let i = 0; i < n; i++) {
                const c = i < n / 2 ? _color1 : _color2;
                colors.setXYZ(i, c.r, c.g, c.b);
            }
            colors.needsUpdate = true;
        }
        this.light.updateWorldMatrix(true, false);
        _v1.setFromMatrixPosition(this.light.matrixWorld).negate();
        this.mesh.lookAt<f64>(_v1.x, _v1.y, _v1.z);
    }

    dispose(): void {
        this.mesh.geometry.dispose();
        this.mesh.material.dispose();
    }
}
