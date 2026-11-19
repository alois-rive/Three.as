// Primitives: an animated InstancedMesh, a Points galaxy, lines (strip,
// loop, segments, dashed), a wireframe mesh, additive sprites and LODs.

import * as THREE from "lib:threeas/three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";

const GRID: i32 = 20;

/// A soft round glow, white with alpha falling off from the centre.
function glowTexture(size: i32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const dx = (<f64>x + 0.5) / <f64>size * 2 - 1, dy = (<f64>y + 0.5) / <f64>size * 2 - 1;
            const a = Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy));
            const o = (y * size + x) * 4;
            data[o] = 255; data[o + 1] = 255; data[o + 2] = 255;
            data[o + 3] = <u8>(a * a * 255);
        }
    }
    const t = new THREE.DataTexture(data, size, size);
    t.magFilter = THREE.LinearFilter;
    t.minFilter = THREE.LinearFilter;
    return t;
}

export class Primitives extends Layout {
    renderer: THREE.GPURenderer? = null;
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(45, 1, 0.1, 200);
    instances: THREE.InstancedMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(0.1, 0.1, 0.1),
        new THREE.MeshStandardMaterial({ roughness: 0.5 }), GRID * GRID);
    galaxy: THREE.Points = new THREE.Points();
    wire: THREE.Mesh = new THREE.Mesh();
    edges: THREE.LineSegments = new THREE.LineSegments();
    sprites: Array<THREE.Sprite> = [];
    time: f64 = 0;
    dummy: THREE.Object3D = new THREE.Object3D();

    override init(context: Context): bool {
        this.renderer = new THREE.GPURenderer(context, { antialias: true });
        const scene = this.scene;
        scene.background = new THREE.Color(0x0b0d12);
        scene.add(new THREE.HemisphereLight(0xbcd0ff, 0x202030, 2));
        const sun = new THREE.DirectionalLight(0xffffff, 2);
        sun.position.set(3, 5, 4);
        scene.add(sun);

        // InstancedMesh: a wave of cubes, coloured by position.
        const color = new THREE.Color();
        for (let i = 0; i < GRID * GRID; i++) {
            const gx = i % GRID, gz = i / GRID;
            color.setHSL(0.55 + <f64>gx / <f64>GRID * 0.3, 0.7, 0.5 + <f64>gz / <f64>GRID * 0.2);
            this.instances.setColorAt(i, color);
        }
        this.instances.position.set(-2.4, -0.7, 0);
        this.instances.rotation.x = 0.45;
        scene.add(this.instances);

        // Points: a two-armed spiral with vertex colours.
        const count = 3000;
        const positions: Array<f64> = [];
        const colors: Array<f64> = [];
        THREE.MathUtils.seededRandom(7);
        for (let i = 0; i < count; i++) {
            const r = THREE.MathUtils.seededRandom() * 1.6;
            const arm = <f64>(i % 2) * Math.PI;
            const angle = r * 3 + arm + (THREE.MathUtils.seededRandom() - 0.5) * 0.6;
            positions.push(Math.cos(angle) * r);
            positions.push((THREE.MathUtils.seededRandom() - 0.5) * 0.15);
            positions.push(Math.sin(angle) * r);
            color.setHSL(0.08 + r * 0.25, 0.9, 0.6);
            colors.push(color.r); colors.push(color.g); colors.push(color.b);
        }
        const galaxyGeometry = new THREE.BufferGeometry();
        galaxyGeometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
        galaxyGeometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3));
        this.galaxy = new THREE.Points(galaxyGeometry,
            new THREE.PointsMaterial({ size: 3, vertexColors: true, sizeAttenuation: false }));
        this.galaxy.position.set(2.6, 0.6, 0);
        this.galaxy.rotation.x = 0.5;
        scene.add(this.galaxy);

        // Lines: a sine strip, a circle loop, a dashed helix.
        const wave: Array<f64> = [];
        for (let i = 0; i <= 64; i++) {
            const x = <f64>i / 64 * 4 - 2;
            wave.push(x); wave.push(Math.sin(x * 3) * 0.25); wave.push(0);
        }
        const waveGeometry = new THREE.BufferGeometry();
        waveGeometry.setAttribute("position", new THREE.Float32BufferAttribute(wave, 3));
        const strip = new THREE.Line(waveGeometry, new THREE.LineBasicMaterial({ color: 0x7ae582 }));
        strip.position.set(-2.6, 2.1, 0);
        scene.add(strip);

        const circle = new THREE.LineLoop(new THREE.BufferGeometry().setAttribute("position",
            new THREE.Float32BufferAttribute(circlePoints(0.6, 6), 3)), new THREE.LineBasicMaterial({ color: 0xffb400 }));
        circle.position.set(0, 2.1, 0);
        scene.add(circle);

        const helix: Array<f64> = [];
        for (let i = 0; i <= 200; i++) {
            const t = <f64>i / 200 * Math.PI * 6;
            helix.push(Math.cos(t) * 0.5); helix.push(<f64>i / 200 * 1.4 - 0.7); helix.push(Math.sin(t) * 0.5);
        }
        const dashed = new THREE.Line(new THREE.BufferGeometry().setAttribute("position",
            new THREE.Float32BufferAttribute(helix, 3)), new THREE.LineDashedMaterial({ color: 0xff5a5f, dashSize: 0.15, gapSize: 0.08 }));
        dashed.computeLineDistances();
        dashed.position.set(2.6, 2.1, 0);
        scene.add(dashed);

        // EdgesGeometry as LineSegments, and a wireframe material.
        this.edges = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.DodecahedronGeometry(0.55)),
            new THREE.LineBasicMaterial({ color: 0xffffff }));
        this.edges.position.set(-0.7, 0.6, 0);
        scene.add(this.edges);
        this.wire = new THREE.Mesh(new THREE.IcosahedronGeometry(0.55, 1),
            new THREE.MeshBasicMaterial({ color: 0x4d9de0, wireframe: true }));
        this.wire.position.set(0.7, 0.6, 0);
        scene.add(this.wire);

        // Sprites: additive glows.
        const glow = glowTexture(64);
        const hues: Array<f64> = [0.0, 0.15, 0.55, 0.8];
        for (let i = 0; i < hues.length; i++) {
            const m = new THREE.SpriteMaterial({ map: glow, blending: THREE.AdditiveBlending, depthWrite: false });
            m.color.setHSL(hues[i], 0.9, 0.6);
            const sprite = new THREE.Sprite(m);
            sprite.scale.set(0.9, 0.9, 1);
            scene.add(sprite);
            this.sprites.push(sprite);
        }

        // LODs: detail by distance, coloured by level (red near, blue far).
        const levels: Array<u32> = [0xef476f, 0xffd166, 0x118ab2];
        for (let k = 0; k < 5; k++) {
            const lod = new THREE.LOD();
            for (let l = 0; l < levels.length; l++) {
                const detail = 3 - l;
                lod.addLevel(new THREE.Mesh(new THREE.IcosahedronGeometry(0.3, detail),
                    new THREE.MeshStandardMaterial({ color: levels[l], flatShading: true })), <f64>l * 8);
            }
            lod.position.set(<f64>k * 1.2 - 2.4, -2.1, 4 - <f64>k * 7);
            scene.add(lod);
        }

        this.camera.position.set(0, 0.9, 8.5);
        this.camera.lookAt(0, 0.2, 0);
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
        const d = this.dummy;
        for (let i = 0; i < GRID * GRID; i++) {
            const gx = i % GRID, gz = i / GRID;
            const x = <f64>gx / <f64>(GRID - 1) * 2 - 1, z = <f64>gz / <f64>(GRID - 1) * 2 - 1;
            d.position.set(x * 1.5, Math.sin(t * 2 + (x + z) * 3) * 0.2, z * 1.5);
            d.rotation.set(t + x, t * 0.7 + z, 0);
            d.updateMatrix();
            this.instances.setMatrixAt(i, d.matrix);
        }
        this.instances.instanceMatrix.needsUpdate = true;
        this.instances.computeBoundingSphere();
        this.galaxy.rotation.y = t * 0.3;
        this.edges.rotation.y = t * 0.5;
        this.wire.rotation.y = -t * 0.5;
        for (let i = 0; i < this.sprites.length; i++) {
            const a = t * 0.8 + <f64>i * Math.PI / 2;
            this.sprites[i].position.set(Math.cos(a) * 1.4, -0.9 + Math.sin(a * 2) * 0.2, Math.sin(a) * 0.6 + 1.5);
        }
        return true;
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer!;
        r.render(this.scene, this.camera);
        r.present(renderer);
    }
}

function circlePoints(radius: f64, sides: i32): Array<f64> {
    const out: Array<f64> = [];
    for (let i = 0; i < sides; i++) {
        const a = <f64>i / <f64>sides * Math.PI * 2;
        out.push(Math.cos(a) * radius); out.push(Math.sin(a) * radius); out.push(0);
    }
    return out;
}
