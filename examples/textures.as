// Textures: per-map uv transforms (a map turning about its center while
// the normal map scrolls), an aoMap read through a second uv set
// (channel 1), and KTX2 compressed textures (BC1 with mipmaps, ASTC 4x4)
// from KTX2Loader (a device without ASTC shows that cube magenta, with a log
// line: KTX2 files here hold one GPU format, no Basis transcoding).

import { unzlibSync } from "../three/addons/libs/fflate";
import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { KTX2Loader } from "../three/addons/loaders/KTX2Loader";
import { Context } from "rive/host";

function checker(size: i32, cells: i32, a: u32, b: u32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const c = ((x * cells / size) + (y * cells / size)) % 2 == 0 ? a : b;
            const o = (y * size + x) * 4;
            data[o] = <u8>(c >> 16); data[o + 1] = <u8>(c >> 8); data[o + 2] = <u8>c; data[o + 3] = 255;
        }
    }
    const t = new THREE.DataTexture(data, size, size);
    t.colorSpace = THREE.SRGBColorSpace;
    t.magFilter = THREE.NearestFilter;
    t.minFilter = THREE.LinearMipmapLinearFilter;
    t.generateMipmaps = true;
    return t;
}

/// A soft radial falloff (white center, dark rim) for the aoMap.
function vignette(size: i32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const dx = (<f64>x + 0.5) / <f64>size * 2 - 1, dy = (<f64>y + 0.5) / <f64>size * 2 - 1;
            const v = <u8>(255 * Math.max(0.15, 1 - (dx * dx + dy * dy) * 0.6));
            const o = (y * size + x) * 4;
            data[o] = v; data[o + 1] = v; data[o + 2] = v; data[o + 3] = 255;
        }
    }
    const t = new THREE.DataTexture(data, size, size);
    t.magFilter = THREE.LinearFilter;
    t.minFilter = THREE.LinearFilter;
    t.wrapS = THREE.RepeatWrapping;
    t.wrapT = THREE.RepeatWrapping;
    return t;
}

export class Textures extends THREE.ThreeLayout {
    spinning: THREE.Texture = new THREE.Texture();
    cubes: Array<THREE.Mesh> = [];

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        const scene = this.scene;
        scene.background = new THREE.Color(0x15171c);
        scene.add(new THREE.HemisphereLight(0xffffff, 0x404050, 2.2));
        const sun = new THREE.DirectionalLight(0xffffff, 1.5);
        sun.position.set(2, 4, 3);
        scene.add(sun);

        // A map turning about its center (rotation + center + repeat).
        const map = checker(64, 8, 0xe8e2d0, 0x2a6f97);
        map.wrapS = THREE.RepeatWrapping;
        map.wrapT = THREE.RepeatWrapping;
        map.center.set(0.5, 0.5);
        map.repeat.set(1.5, 1.5);
        this.spinning = map;
        const plane = new THREE.Mesh(new THREE.PlaneGeometry(1.6, 1.6), new THREE.MeshStandardMaterial({ map: map }));
        plane.position.set(-2.1, 0, 0);
        scene.add(plane);

        // An aoMap on the second uv set: uv1 tiles the vignette 2 x 2.
        const box = new THREE.BoxGeometry(1.1, 1.1, 1.1);
        const uv = box.getAttribute("uv")!;
        const uv1 = new Float32Array(uv.array.length);
        for (let i = 0; i < uv1.length; i++) uv1[i] = uv.array[i] * 2;
        box.setAttribute("uv1", new THREE.BufferAttribute(uv1, 2));
        const ao = vignette(64);
        ao.channel = 1;
        const aoCube = new THREE.Mesh(box, new THREE.MeshStandardMaterial({
            color: 0xd8c3a5, aoMap: ao, aoMapIntensity: 1, roughness: 0.6,
        }));
        aoCube.position.set(-0.6, 0, 0);
        scene.add(aoCube);
        this.cubes.push(aoCube);

        // KTX2: BC1 (5 mip levels) and ASTC 4x4, shipped zlib-compressed
        // (tools/make_ktx2_samples.py says why).
        const loader = new KTX2Loader(context).detectSupport(renderer);
        const names: StaticArray<string> = ["checker_bc1", "checker_astc"];
        for (let i = 0; i < 2; i++) {
            const packedAsset = context.blob(names[i]);
            const packed = packedAsset != null ? packedAsset!.toArrayBuffer() : null;
            const t = packed != null ? loader.parse(unzlibSync(Uint8Array.wrap(packed!))) : null;
            const m = new THREE.Mesh(new THREE.BoxGeometry(1.1, 1.1, 1.1),
                new THREE.MeshStandardMaterial({ color: t != null ? 0xffffff : 0xff00ff, map: t, roughness: 0.5 }));
            m.position.set(0.9 + <f64>i * 1.5, 0, 0);
            scene.add(m);
            this.cubes.push(m);
        }

        this.camera.position.set(0.0, 1.5, 5.6);
        const controls = new OrbitControls(this.camera, renderer);
        controls.target.set(0.0, 0, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        this.spinning.rotation += seconds * 0.5;
        for (let i = 0; i < this.cubes.length; i++) {
            this.cubes[i].rotation.y += seconds * 0.4;
            this.cubes[i].rotation.x = 0.35;
        }
    }
}
