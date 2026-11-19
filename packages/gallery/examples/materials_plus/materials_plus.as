// MaterialsPlus: the rest of three.js's material options. Top row: a
// bumpMap, a displacementMap on a subdivided sphere, a lightMap on uv1, a
// tangent-space normal map with computeTangents, an object-space normal
// map. Bottom row: Phong and Lambert envMaps with each `combine` mode and a
// specularMap, a clearcoat with its own normal and roughness maps, sheen
// from a sheenColorMap. Front row: transmission (glass with dispersion,
// frosted, tinted by attenuation), iridescence and anisotropy.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { RGBELoader } from "lib:threeas/three/addons/loaders/RGBELoader";
import { Context } from "rive/host";

/// A size x size RGBA8 texture from f(u, v) -> 0xRRGGBB.
class Painter {
    paint(u: f64, v: f64): u32 { return 0; }
}

function texture(size: i32, p: Painter, srgb: bool = false): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const c = p.paint((<f64>x + 0.5) / <f64>size, (<f64>y + 0.5) / <f64>size);
            const o = (y * size + x) * 4;
            data[o] = <u8>(c >> 16); data[o + 1] = <u8>(c >> 8); data[o + 2] = <u8>c; data[o + 3] = 255;
        }
    }
    const t = new THREE.DataTexture(data, size, size);
    if (srgb) t.colorSpace = THREE.SRGBColorSpace;
    t.wrapS = THREE.RepeatWrapping;
    t.wrapT = THREE.RepeatWrapping;
    t.magFilter = THREE.LinearFilter;
    t.minFilter = THREE.LinearMipmapLinearFilter;
    t.generateMipmaps = true;
    return t;
}

function grey(v: f64): u32 {
    const g = <u32>Math.max(0, Math.min(255, v * 255));
    return (g << 16) | (g << 8) | g;
}

/// Raised dots (a height field).
class Dots extends Painter {
    override paint(u: f64, v: f64): u32 {
        const fx = (u * 6) % 1 - 0.5, fy = (v * 6) % 1 - 0.5;
        return grey(Math.max(0, 1 - Math.sqrt(fx * fx + fy * fy) * 3));
    }
}

/// Ridges along v (displacement).
class Ridges extends Painter {
    override paint(u: f64, v: f64): u32 {
        return grey(0.5 + 0.5 * Math.sin(u * Math.PI * 16) * Math.sin(v * Math.PI * 8));
    }
}

/// A baked light: bright top-left corner falling off.
class Baked extends Painter {
    override paint(u: f64, v: f64): u32 {
        const d = Math.sqrt(u * u + (1 - v) * (1 - v));
        const r = Math.max(0, 1.3 - d), g = Math.max(0, 1.1 - d), b = Math.max(0, 0.8 - d * 0.6);
        return (<u32>(Math.min(1, r) * 255) << 16) | (<u32>(Math.min(1, g) * 255) << 8) | <u32>(Math.min(1, b) * 255);
    }
}

/// A tangent-space normal map of diagonal grooves.
class Grooves extends Painter {
    override paint(u: f64, v: f64): u32 {
        const s = Math.cos((u + v) * Math.PI * 10);
        const nx = s * 0.5, ny = s * 0.5, nz = Math.sqrt(Math.max(0, 1 - nx * nx - ny * ny));
        return (<u32>((nx * 0.5 + 0.5) * 255) << 16) | (<u32>((ny * 0.5 + 0.5) * 255) << 8) | <u32>((nz * 0.5 + 0.5) * 255);
    }
}

/// An object-space normal map for a sphere: its own normals, banded.
class SphereNormals extends Painter {
    override paint(u: f64, v: f64): u32 {
        const phi = u * Math.PI * 2, theta = (1 - v) * Math.PI;
        let nx = -Math.cos(phi) * Math.sin(theta), ny = Math.cos(theta), nz = Math.sin(phi) * Math.sin(theta);
        const band = Math.sin(theta * 12) * 0.35;
        nx += band; nz += band;
        const l = Math.sqrt(nx * nx + ny * ny + nz * nz);
        return (<u32>((nx / l * 0.5 + 0.5) * 255) << 16) | (<u32>((ny / l * 0.5 + 0.5) * 255) << 8) | <u32>((nz / l * 0.5 + 0.5) * 255);
    }
}

/// Stripes (a specularMap / clearcoat roughness map).
class Stripes extends Painter {
    override paint(u: f64, v: f64): u32 { return ((<i32>(v * 8)) % 2 == 0) ? 0xffffff : 0x202020; }
}

/// A sheen colour pattern.
class Fabric extends Painter {
    override paint(u: f64, v: f64): u32 {
        const w = ((<i32>(u * 16) + <i32>(v * 16)) % 2 == 0);
        return w ? 0xff6fb5 : 0x7a5cff;
    }
}

export class MaterialsPlus extends THREE.ThreeLayout {
    meshes: Array<THREE.Mesh> = [];

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        const scene = this.scene;
        scene.background = new THREE.Color(0x15171c);
        const hdr = new RGBELoader(context).load("studio_rgbe");
        if (hdr != null) {
            hdr.mapping = THREE.EquirectangularReflectionMapping;
            scene.environment = hdr;
        }
        scene.environmentIntensity = 0.6;
        scene.add(new THREE.HemisphereLight(0xdde6ff, 0x30302a, 1.0));
        const sun = new THREE.DirectionalLight(0xffffff, 2.2);
        sun.position.set(-3, 4, 5);
        scene.add(sun);

        const sphere = new THREE.SphereGeometry(0.42, 64, 32);
        const top: f64 = 1.5, bottom: f64 = 0.0;

        // bumpMap
        this.add(new THREE.Mesh(sphere, new THREE.MeshStandardMaterial({
            color: 0xc9b38f, roughness: 0.5, bumpMap: texture(128, new Dots()), bumpScale: 3,
        })), -2.2, top);
        // displacementMap
        this.add(new THREE.Mesh(new THREE.SphereGeometry(0.36, 128, 64), new THREE.MeshStandardMaterial({
            color: 0x8fb3c9, roughness: 0.4, displacementMap: texture(128, new Ridges()), displacementScale: 0.12,
            displacementBias: -0.06,
        })), -1.1, top);
        // lightMap on uv1 (a box whose uv1 is its uv)
        const box = new THREE.BoxGeometry(0.62, 0.62, 0.62);
        box.setAttribute("uv1", box.getAttribute("uv")!);
        const baked = texture(64, new Baked(), true);
        baked.channel = 1;
        this.add(new THREE.Mesh(box, new THREE.MeshLambertMaterial({
            color: 0x707070, lightMap: baked, lightMapIntensity: 3,
        })), 0, top);
        // normal map with tangents
        const tangentSphere = new THREE.SphereGeometry(0.42, 64, 32);
        tangentSphere.computeTangents();
        this.add(new THREE.Mesh(tangentSphere, new THREE.MeshStandardMaterial({
            color: 0xd0d4dc, roughness: 0.35, metalness: 0.6, normalMap: texture(128, new Grooves()),
        })), 1.1, top);
        // object-space normal map
        this.add(new THREE.Mesh(sphere, new THREE.MeshStandardMaterial({
            color: 0xb8c48c, roughness: 0.45, normalMap: texture(128, new SphereNormals()),
            normalMapType: THREE.ObjectSpaceNormalMap,
        })), 2.2, top);

        // Phong / Lambert envMaps: multiply, mix, add (with a specularMap).
        const env = hdr;
        const stripes = texture(64, new Stripes());
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhongMaterial({
            color: 0x6f8fd0, envMap: env, combine: THREE.MultiplyOperation, reflectivity: 0.9,
        })), -2.2, bottom);
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhongMaterial({
            color: 0x6f8fd0, envMap: env, combine: THREE.MixOperation, reflectivity: 0.5, specularMap: stripes,
        })), -1.1, bottom);
        this.add(new THREE.Mesh(sphere, new THREE.MeshLambertMaterial({
            color: 0x704030, envMap: env, combine: THREE.AddOperation, reflectivity: 0.15,
        })), 0, bottom);
        // clearcoat with its own normal map and roughness map
        this.add(new THREE.Mesh(tangentSphere, new THREE.MeshPhysicalMaterial({
            color: 0x9c1020, roughness: 0.6, clearcoat: 1, clearcoatRoughness: 0.4,
            clearcoatNormalMap: texture(128, new Grooves()), clearcoatRoughnessMap: stripes,
        })), 1.1, bottom);
        // sheen from a sheenColorMap
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhysicalMaterial({
            color: 0x202024, roughness: 0.9, sheen: 1, sheenRoughness: 0.4, sheenColor: 0xffffff,
            sheenColorMap: texture(128, new Fabric(), true),
        })), 2.2, bottom);

        // Front row, over a striped backdrop the glass refracts.
        const front: f64 = -1.5;
        const backdrop = new THREE.Mesh(new THREE.PlaneGeometry(6, 0.9), new THREE.MeshBasicMaterial({
            map: texture(64, new Stripes(), true),
        }));
        backdrop.position.set(0, front, -0.9);
        this.scene.add(backdrop);
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhysicalMaterial({
            color: 0xffffff, roughness: 0.02, transmission: 1, thickness: 0.8, ior: 1.5, dispersion: 2,
        })), -2.2, front);
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhysicalMaterial({
            color: 0xffffff, roughness: 0.35, transmission: 1, thickness: 0.5, ior: 1.5,
        })), -1.1, front);
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhysicalMaterial({
            color: 0xffffff, roughness: 0.05, transmission: 1, thickness: 0.9, ior: 1.45,
            attenuationColor: 0x30c070, attenuationDistance: 0.35,
        })), 0, front);
        this.add(new THREE.Mesh(sphere, new THREE.MeshPhysicalMaterial({
            color: 0x101010, roughness: 0.25, metalness: 1, iridescence: 1, iridescenceIOR: 1.6,
            iridescenceThicknessRange: [200, 800],
        })), 1.1, front);
        this.add(new THREE.Mesh(tangentSphere, new THREE.MeshPhysicalMaterial({
            color: 0xc8c8cc, roughness: 0.35, metalness: 1, anisotropy: 0.9, anisotropyRotation: Math.PI / 2,
        })), 2.2, front);

        this.camera.position.set(0, -0.3, 6.4);
        const controls = new OrbitControls(this.camera, renderer);
        controls.update();
        this.controls = controls;
        return true;
    }

    private add(m: THREE.Mesh, x: f64, y: f64): void {
        m.position.set(x, y, 0);
        this.scene.add(m);
        this.meshes.push(m);
    }

    override animate(seconds: f64): void {
        for (let i = 0; i < this.meshes.length; i++) this.meshes[i].rotation.y += seconds * 0.3;
    }
}
