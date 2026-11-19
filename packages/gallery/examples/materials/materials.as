// Materials: every mesh material, lit by hemisphere, spot and point lights,
// in linear fog, under an equirectangular sky, tone mapped with ACES. All
// textures are generated (no image assets).

import * as THREE from "lib:threeas/three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";

/// An RGBA DataTexture of size x size from a per-texel function writing
/// into `out` (r, g, b, a in 0..255). Rows go bottom to top.
function texture(width: i32, height: i32, texel: (x: f64, y: f64, out: StaticArray<f64>) => void): THREE.DataTexture {
    const data = new Uint8Array(width * height * 4);
    const out = new StaticArray<f64>(4);
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            texel((<f64>x + 0.5) / <f64>width, (<f64>y + 0.5) / <f64>height, out);
            const o = (y * width + x) * 4;
            for (let c = 0; c < 4; c++) data[o + c] = <u8>Math.max(0, Math.min(255, Math.round(out[c])));
        }
    }
    const t = new THREE.DataTexture(data, width, height);
    t.magFilter = THREE.LinearFilter;
    t.minFilter = THREE.LinearMipmapLinearFilter;
    t.generateMipmaps = true;
    return t;
}

/// Tangent-space bumps.
function bumps(x: f64, y: f64, out: StaticArray<f64>): void {
    const k = Math.PI * 8;
    const dx = Math.cos(x * k) * Math.sin(y * k);
    const dy = Math.sin(x * k) * Math.cos(y * k);
    const l = Math.sqrt(dx * dx + dy * dy + 1);
    out[0] = (-dx / l * 0.5 + 0.5) * 255;
    out[1] = (-dy / l * 0.5 + 0.5) * 255;
    out[2] = (1 / l * 0.5 + 0.5) * 255;
    out[3] = 255;
}

/// A warm clay matcap: a lit sphere.
function clay(x: f64, y: f64, out: StaticArray<f64>): void {
    const u = x * 2 - 1, v = y * 2 - 1;
    const d = u * u + v * v;
    const z = d < 1 ? Math.sqrt(1 - d) : 0;
    const lx = -0.4, ly = 0.6, lz = 0.7;
    const diffuse = Math.max(0, u * lx + v * ly + z * lz);
    const spec = Math.pow(Math.max(0, z * 0.2 + diffuse * 0.8), 40);
    out[0] = 40 + 200 * diffuse + 120 * spec;
    out[1] = 25 + 130 * diffuse + 120 * spec;
    out[2] = 20 + 90 * diffuse + 120 * spec;
    out[3] = 255;
}

/// Stripes, for an alphaMap (green channel).
function stripes(_x: f64, y: f64, out: StaticArray<f64>): void {
    const on = Math.sin(y * Math.PI * 12) > 0 ? 255.0 : 0.0;
    out[0] = on; out[1] = on; out[2] = on; out[3] = 255;
}

/// An equirectangular sky: deep blue above, haze at and below the horizon.
function sky(_x: f64, y: f64, out: StaticArray<f64>): void {
    const e = y * 2 - 1;   // -1 nadir .. 1 zenith
    if (e > 0) {
        const t = Math.pow(e, 0.5);
        out[0] = 190 - 150 * t; out[1] = 205 - 120 * t; out[2] = 225 - 60 * t;
    } else {
        // Below the horizon: the fog's haze, so the finite floor fades in.
        out[0] = 180; out[1] = 195; out[2] = 214;
    }
    out[3] = 255;
}

export class Materials extends Layout {
    renderer: THREE.GPURenderer? = null;
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(42, 1, 0.1, 500);
    shapes: Array<THREE.Mesh> = [];
    spot: THREE.SpotLight = new THREE.SpotLight(0xffffff, 120, 0, Math.PI / 5, 0.5, 2);
    point: THREE.PointLight = new THREE.PointLight(0xff9a40, 10, 8, 2);
    time: f64 = 0;

    override init(context: Context): bool {
        const renderer = new THREE.GPURenderer(context, { antialias: true });
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        renderer.toneMappingExposure = 1.1;
        this.renderer = renderer;
        const scene = this.scene;

        const skyTexture = texture(128, 64, sky);
        skyTexture.colorSpace = THREE.SRGBColorSpace;
        skyTexture.mapping = THREE.EquirectangularReflectionMapping;
        skyTexture.wrapS = THREE.RepeatWrapping;
        scene.background = skyTexture;
        scene.fog = new THREE.Fog(0xb4c3d6, 14, 34);

        scene.add(new THREE.HemisphereLight(0xc4d8ff, 0x3a2c20, 1.6));
        this.spot.position.set(2, 9, 6);
        scene.add(this.spot);
        scene.add(this.point);

        const normalMap = texture(64, 64, bumps);
        normalMap.wrapS = THREE.RepeatWrapping;
        normalMap.wrapT = THREE.RepeatWrapping;
        normalMap.repeat.set(2, 1);
        const matcap = texture(64, 64, clay);
        matcap.colorSpace = THREE.SRGBColorSpace;
        const alphaMap = texture(8, 64, stripes);
        const gradient = new THREE.DataTexture(new Uint8Array(12), 3, 1);
        const g = gradient.data as Uint8Array;
        g[0] = 70; g[1] = 70; g[2] = 70; g[3] = 255;
        g[4] = 160; g[5] = 160; g[6] = 160; g[7] = 255;
        g[8] = 255; g[9] = 255; g[10] = 255; g[11] = 255;

        const knot = new THREE.TorusKnotGeometry(0.45, 0.16, 96, 12);
        const sphere = new THREE.SphereGeometry(0.62, 48, 24);
        const materials: Array<THREE.Material> = [
            new THREE.MeshLambertMaterial({ color: 0x3fa7d6 }),
            new THREE.MeshPhongMaterial({ color: 0x3fa7d6, specular: 0x666666, shininess: 80 }),
            new THREE.MeshToonMaterial({ color: 0x59cd90, gradientMap: gradient }),
            new THREE.MeshStandardMaterial({ color: 0xee6352, roughness: 0.45, normalMap: normalMap }),
            new THREE.MeshStandardMaterial({ color: 0xfac05e, metalness: 1, roughness: 0.25 }),
            new THREE.MeshPhysicalMaterial({ color: 0xc81d25, roughness: 0.7, clearcoat: 1, clearcoatRoughness: 0.08 }),
            new THREE.MeshPhysicalMaterial({ color: 0x2b2d42, roughness: 0.9, sheen: 1, sheenColor: 0xb5a8ff, sheenRoughness: 0.4 }),
            new THREE.MeshMatcapMaterial({ matcap: matcap }),
            new THREE.MeshNormalMaterial(),
            new THREE.MeshDepthMaterial(),
            new THREE.MeshBasicMaterial({ vertexColors: true }),
            new THREE.MeshStandardMaterial({ color: 0x8d6a9f, alphaMap: alphaMap, alphaTest: 0.5, side: THREE.DoubleSide }),
        ];
        for (let i = 0; i < materials.length; i++) {
            const geometry: THREE.BufferGeometry = i == 10 ? colorfulIcosahedron() : i % 2 == 0 ? sphere : knot;
            const mesh = new THREE.Mesh(geometry, materials[i]);
            const column = i % 4, row = i / 4;
            mesh.position.set(<f64>column * 2 - 3, 3.1 - <f64>row * 1.75, 0);
            scene.add(mesh);
            this.shapes.push(mesh);
        }

        // A box with a material per face (geometry groups).
        const box = new THREE.Mesh(new THREE.BoxGeometry(1.2, 1.2, 1.2));
        const faceColors: Array<u32> = [0xef476f, 0xffd166, 0x06d6a0, 0x118ab2, 0x073b4c, 0xf78c6b];
        for (let i = 0; i < faceColors.length; i++) {
            box.materials.push(new THREE.MeshStandardMaterial({ color: faceColors[i], roughness: 0.5 }));
        }
        box.position.set(0, -2.2, 1.2);
        scene.add(box);
        this.shapes.push(box);

        const floor = new THREE.Mesh(new THREE.PlaneGeometry(400, 400),
            new THREE.MeshStandardMaterial({ color: 0x6d7a6a, roughness: 0.95 }));
        floor.rotation.x = -Math.PI / 2;
        floor.position.y = -3;
        scene.add(floor);

        this.camera.position.set(0, 1.2, 11.5);
        this.camera.lookAt(0, 0.3, 0);
        return true;
    }

    override resize(width: f64, height: f64, scale: f64): void {
        const renderer = this.renderer!;
        renderer.setPixelRatio(scale);
        renderer.setSize(width, height);
        this.camera.aspect = width / height;
        this.camera.updateProjectionMatrix();
    }

    override advance(seconds: f64): bool {
        const t = (this.time += seconds);
        for (let i = 0; i < this.shapes.length; i++) {
            this.shapes[i].rotation.y = t * 0.5 + <f64>i;
            this.shapes[i].rotation.x = 0.3;
        }
        this.point.position.set(Math.cos(t) * 4, 0.5, Math.sin(t) * 2 + 2);
        return true;
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer!;
        r.render(this.scene, this.camera);
        r.present(renderer);
    }
}

/// An icosahedron with a colour per face (non-indexed, so per vertex).
function colorfulIcosahedron(): THREE.BufferGeometry {
    const g = new THREE.IcosahedronGeometry(0.7, 0);
    const count = g.getAttribute("position")!.count;
    const colors: Array<f64> = [];
    const c = new THREE.Color();
    for (let i = 0; i < count; i++) {
        c.setHSL(<f64>(i / 3) / <f64>(count / 3), 0.75, 0.55);
        colors.push(c.r); colors.push(c.g); colors.push(c.b);
    }
    g.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3));
    return g;
}
