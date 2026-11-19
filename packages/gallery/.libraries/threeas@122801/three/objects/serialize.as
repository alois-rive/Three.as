// Internal: writing an object's geometry and materials into a JSONMeta,
// for the toJSONObject hooks of Mesh, Line, Points and Sprite (three.js's
// `serialize` inside Object3D.toJSON).

import { Dynamic } from "rive/dynamic";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { JSONMeta } from "../core/JSON";

/// Writes `geometry` into `meta.geometries` (once) and returns its uuid.
export function geometryToLibrary(geometry: BufferGeometry, meta: JSONMeta): string {
    const uuid = geometry.uuid;
    if (!meta.geometries.has(uuid)) meta.geometries.set(uuid, geometry.toJSON(meta));
    return uuid;
}

/// Writes `material` into `meta.materials` (once) and returns its uuid.
export function materialToLibrary(material: Material, meta: JSONMeta): string {
    const uuid = material.uuid;
    if (!meta.materials.has(uuid)) meta.materials.set(uuid, material.toJSON(meta));
    return uuid;
}

/// Sets `object.material`: the uuid of `material`, or an array of uuids
/// when `materials` (a mesh's per-group materials) is not empty.
export function writeMaterials(object: Dynamic, material: Material, materials: Array<Material>, meta: JSONMeta): void {
    if (materials.length > 0) {
        const uuids = Dynamic.newTable();
        for (let i = 0; i < materials.length; i++) uuids.push(Dynamic.fromString(materialToLibrary(materials[i], meta)));
        object.set("material", uuids);
    } else {
        object.set("material", Dynamic.fromString(materialToLibrary(material, meta)));
    }
}
