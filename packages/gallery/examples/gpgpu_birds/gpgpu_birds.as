// GpgpuBirds: three.js's webgl_gpgpu_birds. 1024 birds flock on the GPU:
// a GPUComputationRenderer computes their velocities (separation, alignment
// and cohesion against every other bird) and positions in two float
// textures each frame (examples/gpgpu_birds/velocity.wgsl, position.wgsl),
// and one ShaderMaterial draws every bird from its texel
// (examples/gpgpu_birds/bird.wgsl). The pointer is a predator the birds
// flee; separation, alignment and cohesion are script inputs (three.js's
// GUI).

import * as THREE from "lib:threeas/three/Three";
import { GPUComputationRenderer, GPUComputationVariable } from "lib:threeas/three/addons/misc/GPUComputationRenderer";
import { Context } from "rive/host";
import { PointerEvent } from "rive/events";

/* TEXTURE WIDTH FOR SIMULATION */
const WIDTH = 32;

const BIRDS = WIDTH * WIDTH;

const BOUNDS: f64 = 800;
const BOUNDS_HALF: f64 = BOUNDS / 2;

// Custom Geometry - using 3 triangles each. No UVs, no normals currently.
// three.js's `reference` attribute is the uv here, and `birdColor` plus
// `birdVertex` the colour (rgb, a): a ShaderMaterial receives position,
// normal, uv and colour.
class BirdGeometry extends THREE.BufferGeometry {
    constructor() {
        super();

        const trianglesPerBird = 3;
        const triangles = BIRDS * trianglesPerBird;
        const points = triangles * 3;

        const vertices = new Float32Array(points * 3);
        const birdColors = new Float32Array(points * 4);
        const references = new Float32Array(points * 2);

        let n = 0;
        const wingsSpan: f32 = 20;
        const bird: StaticArray<f32> = [
            // Body
            0, -0, -20,
            0, 4, -20,
            0, 0, 30,
            // Wings
            0, 0, -15,
            -wingsSpan, 0, 0,
            0, 0, 15,

            0, 0, 15,
            wingsSpan, 0, 0,
            0, 0, -15,
        ];
        for (let f = 0; f < BIRDS; f++) {
            for (let i = 0; i < bird.length; i++) vertices[n++] = bird[i];
        }

        const c = new THREE.Color();
        for (let v = 0; v < triangles * 3; v++) {
            const triangleIndex = v / 3;
            const birdIndex = triangleIndex / trianglesPerBird;
            const x = <f64>(birdIndex % WIDTH) / <f64>WIDTH;
            const y = <f64>(birdIndex / WIDTH) / <f64>WIDTH;

            c.setHex(<u32>Math.floor(0x666666 + <f64>(v / 9) / <f64>BIRDS * 0x666666));

            birdColors[v * 4 + 0] = <f32>c.r;
            birdColors[v * 4 + 1] = <f32>c.g;
            birdColors[v * 4 + 2] = <f32>c.b;
            // birdVertex
            birdColors[v * 4 + 3] = <f32>(v % 9);

            references[v * 2] = <f32>x;
            references[v * 2 + 1] = <f32>y;
        }

        this.setAttribute("position", new THREE.BufferAttribute(vertices, 3));
        this.setAttribute("color", new THREE.BufferAttribute(birdColors, 4));
        this.setAttribute("uv", new THREE.BufferAttribute(references, 2));

        this.scale(0.2, 0.2, 0.2);
    }
}

export class GpgpuBirds extends THREE.ThreeLayout {
    @input separation: f64 = 20;
    @input alignment: f64 = 20;
    @input cohesion: f64 = 20;

    gpuCompute: GPUComputationRenderer? = null;
    velocityVariable: GPUComputationVariable? = null;
    positionVariable: GPUComputationVariable? = null;
    birdMaterial: THREE.ShaderMaterial = new THREE.ShaderMaterial({ shader: "examples/gpgpu_birds/bird", side: THREE.DoubleSide });
    mouseX: f64 = 10000;
    mouseY: f64 = 10000;
    time: f64 = 0;

    override setup(context: Context): bool {
        this.camera = new THREE.PerspectiveCamera(75, 1, 1, 3000);
        this.camera.position.z = 350;

        this.scene.background = new THREE.Color(0xffffff);
        this.scene.fog = new THREE.Fog(0xffffff, 100, 1000);

        this.initComputeRenderer(context);
        this.initBirds();
        return true;
    }

    initComputeRenderer(context: Context): void {
        const gpuCompute = new GPUComputationRenderer(WIDTH, WIDTH, this.renderer);
        this.gpuCompute = gpuCompute;

        const dtPosition = gpuCompute.createTexture();
        THREE.MathUtils.seededRandom(1);
        const dtVelocity = gpuCompute.createTexture();
        this.fillPositionTexture(dtPosition);
        this.fillVelocityTexture(dtVelocity);

        const velocityVariable = gpuCompute.addVariable("textureVelocity", "examples/gpgpu_birds/velocity", dtVelocity);
        const positionVariable = gpuCompute.addVariable("texturePosition", "examples/gpgpu_birds/position", dtPosition);
        this.velocityVariable = velocityVariable;
        this.positionVariable = positionVariable;

        gpuCompute.setVariableDependencies(velocityVariable, [positionVariable, velocityVariable]);
        gpuCompute.setVariableDependencies(positionVariable, [positionVariable, velocityVariable]);

        const positionUniforms = positionVariable.material.uniforms;
        const velocityUniforms = velocityVariable.material.uniforms;

        // The predator first: its vec3 then starts a 16-byte row, where
        // HLSL packs it too (velocity.wgsl).
        velocityUniforms.set("predator", new THREE.Uniform<THREE.Vector3>(new THREE.Vector3()));
        positionUniforms.set("time", new THREE.Uniform<f64>(0.0));
        positionUniforms.set("delta", new THREE.Uniform<f64>(0.0));
        velocityUniforms.set("time", new THREE.Uniform<f64>(1.0));
        velocityUniforms.set("testing", new THREE.Uniform<f64>(1.0));
        velocityUniforms.set("delta", new THREE.Uniform<f64>(0.0));
        velocityUniforms.set("separationDistance", new THREE.Uniform<f64>(this.separation));
        velocityUniforms.set("alignmentDistance", new THREE.Uniform<f64>(this.alignment));
        velocityUniforms.set("cohesionDistance", new THREE.Uniform<f64>(this.cohesion));
        velocityUniforms.set("freedomFactor", new THREE.Uniform<f64>(0.75));
        // three.js's define BOUNDS is a constant in velocity.wgsl.

        velocityVariable.wrapS = THREE.RepeatWrapping;
        velocityVariable.wrapT = THREE.RepeatWrapping;
        positionVariable.wrapS = THREE.RepeatWrapping;
        positionVariable.wrapT = THREE.RepeatWrapping;

        const error = gpuCompute.init();
        if (error != null) context.log(error!);
    }

    initBirds(): void {
        const geometry = new BirdGeometry();

        // For Vertex and Fragment
        const m = this.birdMaterial;
        m.uniforms.set("color", new THREE.Uniform<THREE.Color>(new THREE.Color(0xff2200)));
        m.uniforms.set("texturePosition", new THREE.Uniform<THREE.Texture>(new THREE.Texture()));
        m.uniforms.set("textureVelocity", new THREE.Uniform<THREE.Texture>(new THREE.Texture()));
        m.uniforms.set("time", new THREE.Uniform<f64>(1.0));
        m.uniforms.set("delta", new THREE.Uniform<f64>(0.0));

        const birdMesh = new THREE.Mesh(geometry, m);
        birdMesh.rotation.y = Math.PI / 2;
        birdMesh.matrixAutoUpdate = false;
        birdMesh.updateMatrix();

        this.scene.add(birdMesh);
    }

    fillPositionTexture(texture: THREE.DataTexture): void {
        const theArray = texture.data as Float32Array;
        for (let k = 0, kl = theArray.length; k < kl; k += 4) {
            const x = THREE.MathUtils.seededRandom() * BOUNDS - BOUNDS_HALF;
            const y = THREE.MathUtils.seededRandom() * BOUNDS - BOUNDS_HALF;
            const z = THREE.MathUtils.seededRandom() * BOUNDS - BOUNDS_HALF;
            theArray[k + 0] = <f32>x;
            theArray[k + 1] = <f32>y;
            theArray[k + 2] = <f32>z;
            theArray[k + 3] = 1;
        }
    }

    fillVelocityTexture(texture: THREE.DataTexture): void {
        const theArray = texture.data as Float32Array;
        for (let k = 0, kl = theArray.length; k < kl; k += 4) {
            const x = THREE.MathUtils.seededRandom() - 0.5;
            const y = THREE.MathUtils.seededRandom() - 0.5;
            const z = THREE.MathUtils.seededRandom() - 0.5;
            theArray[k + 0] = <f32>(x * 10);
            theArray[k + 1] = <f32>(y * 10);
            theArray[k + 2] = <f32>(z * 10);
            theArray[k + 3] = 1;
        }
    }

    override onPointerMove(event: PointerEvent): void {
        this.mouseX = <f64>event.position.x - this.width / 2;
        this.mouseY = <f64>event.position.y - this.height / 2;
    }

    override animate(seconds: f64): void {
        let delta = seconds;
        if (delta > 1) delta = 1; // safety cap on large deltas
        this.time += delta;
        const now = this.time * 1000;

        const pv = this.positionVariable, vv = this.velocityVariable;
        if (pv == null || vv == null) return;
        const p = pv.material, v = vv.material;
        p.uniform<f64>("time").value = now;
        p.uniform<f64>("delta").value = delta;
        v.uniform<f64>("time").value = now;
        v.uniform<f64>("delta").value = delta;
        this.birdMaterial.uniform<f64>("time").value = now;
        this.birdMaterial.uniform<f64>("delta").value = delta;
        v.uniform<f64>("separationDistance").value = this.separation;
        v.uniform<f64>("alignmentDistance").value = this.alignment;
        v.uniform<f64>("cohesionDistance").value = this.cohesion;

        const windowHalfX = this.width / 2, windowHalfY = this.height / 2;
        if (windowHalfX > 0 && windowHalfY > 0) {
            v.uniform<THREE.Vector3>("predator").value.set(0.5 * this.mouseX / windowHalfX,
                -0.5 * this.mouseY / windowHalfY, 0);
        }

        this.mouseX = 10000;
        this.mouseY = 10000;
    }

    override renderFrame(): void {
        const gpuCompute = this.gpuCompute;
        const r = this.renderer;
        if (gpuCompute == null || r == null) return;
        gpuCompute.compute();

        this.birdMaterial.uniform<THREE.Texture>("texturePosition").value =
            gpuCompute.getCurrentRenderTarget(this.positionVariable!).texture;
        this.birdMaterial.uniform<THREE.Texture>("textureVelocity").value =
            gpuCompute.getCurrentRenderTarget(this.velocityVariable!).texture;

        r.render(this.scene, this.camera);
    }
}
