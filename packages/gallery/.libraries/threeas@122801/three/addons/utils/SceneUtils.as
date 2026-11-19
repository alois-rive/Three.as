// three.js examples/jsm/utils/SceneUtils.js: converting between instanced,
// multi-material and plain meshes.

import { Object3D } from "../../core/Object3D";
import { Group } from "../../objects/Group";
import { Mesh } from "../../objects/Mesh";
import { InstancedMesh } from "../../objects/InstancedMesh";
import { BufferGeometry } from "../../core/BufferGeometry";
import { Material } from "../../materials/Material";
import { Matrix4 } from "../../math/Matrix4";

/// A Group of one Mesh per material, all sharing `geometry`.
export function createMultiMaterialObject(geometry: BufferGeometry, materials: Array<Material>): Group {
    const group = new Group();
    for (let i = 0; i < materials.length; i++) group.add(new Mesh(geometry, materials[i]));
    return group;
}

/// A Group of plain meshes, one per instance (matrices applied).
export function createMeshesFromInstancedMesh(instancedMesh: InstancedMesh): Group {
    const group = new Group();
    const m = new Matrix4();
    for (let i = 0; i < instancedMesh.count; i++) {
        const mesh = new Mesh(instancedMesh.geometry, instancedMesh.material);
        instancedMesh.getMatrixAt(i, m);
        m.decompose(mesh.position, mesh.quaternion, mesh.scale);
        group.add(mesh);
    }
    group.copyTransform(instancedMesh);
    group.updateMatrixWorld();
    return group;
}

/// A Group of one mesh per geometry group of a multi-material mesh.
export function createMeshesFromMultiMaterialMesh(mesh: Mesh): Object3D {
    if (mesh.materials.length == 0) return mesh;
    const group = new Group();
    const geometry = mesh.geometry;
    for (let i = 0; i < geometry.groups.length; i++) {
        const g = geometry.groups[i];
        const part = new BufferGeometry().copy(geometry);
        part.groups = [];
        part.setDrawRange(g.start, g.count);
        group.add(new Mesh(part, mesh.materials[g.materialIndex]));
    }
    group.copyTransform(mesh);
    group.updateMatrixWorld();
    return group;
}
