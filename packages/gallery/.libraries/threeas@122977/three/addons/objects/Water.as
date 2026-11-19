// three.js examples/jsm/objects/Water.js (r170): an ocean surface. A planar
// mirror (rendered before the pass, as Reflector's) distorted by a
// scrolling normal map, lit by a sun, with a Fresnel mix of water colour
// and reflection; the scene's lights only shade its shadows
// (getShadowMask) when it receives them.
//
//     const water = new Water(new PlaneGeometry(10000, 10000), {
//         textureWidth: 512, textureHeight: 512,
//         waterNormals: normals,            // RepeatWrapping
//         sunDirection: new Vector3(), sunColor: 0xffffff,
//         waterColor: 0x001e0f, distortionScale: 3.7,
//     });
//     water.rotation.x = -Math.PI / 2;
//     // each frame:
//     water.material.uniform<f64>("time").value += seconds;
//
// Based on the flat mirror for three.js (Slayvin), Lee Stemkoski's water
// shader and http://29a.ch/slides/2012/webglwater/.
//
// Differences from three.js (see docs/DEVIATIONS.md): typed WaterOptions
// (colours are hex numbers); the material is a ShaderMaterial over
// three/shaders/objects/water.wgsl, reached as `water.shaderMaterial` (or
// `material as ShaderMaterial`); the mirror target is HalfFloatType
// (three.js renders linear colour into an 8-bit target; here an 8-bit
// target holds tone-mapped sRGB); onBeforeRender is called before the
// render's pass; the oblique clipping writes WebGPU's [0, 1] depth.

import { Mesh } from "../../objects/Mesh";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry, GeometryGroup } from "../../core/BufferGeometry";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { Material } from "../../materials/Material";
import { ShaderMaterial, Uniform } from "../../materials/ShaderMaterial";
import { Color } from "../../math/Color";
import { Matrix4 } from "../../math/Matrix4";
import { Plane } from "../../math/Plane";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { Texture } from "../../textures/Texture";
import { RenderTarget } from "../../renderers/RenderTarget";
import { GPURenderer } from "../../renderers/GPURenderer";
import { emptyTexture } from "../shaders/PostShaders";
import { obliqueClip, cameraFar } from "./Reflector";
import { FrontSide, HalfFloatType } from "../../constants";

/// Water's options (three.js's options object).
export class WaterOptions {
    textureWidth: i32 = 512;
    textureHeight: i32 = 512;
    clipBias: f64 = 0.0;
    alpha: f64 = 1.0;
    time: f64 = 0.0;
    /// The normal map (set RepeatWrapping), null for none.
    waterNormals: Texture? = null;
    sunDirection: Vector3 = new Vector3(0.70707, 0.70707, 0.0);
    sunColor: u32 = 0xffffff;
    waterColor: u32 = 0x7F7F7F;
    /// The eye position the shader uses (updated from the camera each render).
    eye: Vector3 = new Vector3(0, 0, 0);
    distortionScale: f64 = 20.0;
    side: i32 = FrontSide;
    fog: bool = false;
}

export class Water extends Mesh {
    readonly isWater: bool = true;
    private renderTarget: RenderTarget;
    private clipBias: f64;
    private eye: Vector3;
    private mirrorCamera: PerspectiveCamera = new PerspectiveCamera();
    private textureMatrix: Matrix4 = new Matrix4();

    private mirrorPlane: Plane = new Plane();
    private normal: Vector3 = new Vector3();
    private mirrorWorldPosition: Vector3 = new Vector3();
    private cameraWorldPosition: Vector3 = new Vector3();
    private rotationMatrix: Matrix4 = new Matrix4();
    private lookAtPosition: Vector3 = new Vector3(0, 0, -1);
    private clipPlane: Vector4 = new Vector4();
    private view: Vector3 = new Vector3();
    private target: Vector3 = new Vector3();

    constructor(geometry: BufferGeometry, options: WaterOptions? = null) {
        super(geometry);
        const o = options != null ? options! : new WaterOptions();
        this.clipBias = o.clipBias;
        this.eye = o.eye;
        this.renderTarget = new RenderTarget(<u32>o.textureWidth, <u32>o.textureHeight, { type: HalfFloatType });

        const material = new ShaderMaterial({
            shader: "three/shaders/objects/water", lights: true, side: o.side, fog: o.fog,
        });
        material.name = "MirrorShader";
        // Values in this order make the shader's uniform block; the normal
        // map is the first texture (its sampler repeats).
        const u = material.uniforms;
        u.set("alpha", new Uniform<f64>(1.0));
        u.set("time", new Uniform<f64>(0.0));
        u.set("size", new Uniform<f64>(1.0));
        u.set("distortionScale", new Uniform<f64>(20.0));
        u.set("textureMatrix", new Uniform<Matrix4>(new Matrix4()));
        u.set("sunColor", new Uniform<Color>(new Color(0x7F7F7F)));
        u.set("sunDirection", new Uniform<Vector3>(new Vector3(0.70707, 0.70707, 0)));
        u.set("eye", new Uniform<Vector3>(new Vector3()));
        u.set("waterColor", new Uniform<Color>(new Color(0x555555)));
        u.set("normalSampler", new Uniform<Texture>(emptyTexture()));
        u.set("mirrorSampler", new Uniform<Texture>(emptyTexture()));

        material.uniform<Texture>("mirrorSampler").value = this.renderTarget.texture;
        material.uniform<Matrix4>("textureMatrix").value = this.textureMatrix;
        material.uniform<f64>("alpha").value = o.alpha;
        material.uniform<f64>("time").value = o.time;
        if (o.waterNormals != null) material.uniform<Texture>("normalSampler").value = o.waterNormals!;
        material.uniform<Color>("sunColor").value = new Color(<f64>o.sunColor);
        material.uniform<Color>("waterColor").value = new Color(<f64>o.waterColor);
        material.uniform<Vector3>("sunDirection").value = o.sunDirection;
        material.uniform<f64>("distortionScale").value = o.distortionScale;
        material.uniform<Vector3>("eye").value = this.eye;
        this.material = material;
    }

    /// The material, typed (three.js's `water.material`).
    get shaderMaterial(): ShaderMaterial { return this.material as ShaderMaterial; }

    /// Renders the reflection (the renderer calls it before the pass).
    override onBeforeRender(renderer: GPURenderer, scene: Object3D, camera: Camera, geometry: BufferGeometry?,
                            material: Material?, group: GeometryGroup?): void {
        const mirrorCamera = this.mirrorCamera;
        const normal = this.normal;
        const view = this.view;
        const target = this.target;
        const rotationMatrix = this.rotationMatrix;
        const lookAtPosition = this.lookAtPosition;
        const mirrorWorldPosition = this.mirrorWorldPosition;
        const cameraWorldPosition = this.cameraWorldPosition;

        mirrorWorldPosition.setFromMatrixPosition(this.matrixWorld);
        cameraWorldPosition.setFromMatrixPosition(camera.matrixWorld);

        rotationMatrix.extractRotation(this.matrixWorld);

        normal.set(0, 0, 1);
        normal.applyMatrix4(rotationMatrix);

        view.subVectors(mirrorWorldPosition, cameraWorldPosition);

        // Avoid rendering when mirror is facing away
        if (view.dot(normal) > 0) return;

        view.reflect(normal).negate();
        view.add(mirrorWorldPosition);

        rotationMatrix.extractRotation(camera.matrixWorld);

        lookAtPosition.set(0, 0, -1);
        lookAtPosition.applyMatrix4(rotationMatrix);
        lookAtPosition.add(cameraWorldPosition);

        target.subVectors(mirrorWorldPosition, lookAtPosition);
        target.reflect(normal).negate();
        target.add(mirrorWorldPosition);

        mirrorCamera.position.copy(view);
        mirrorCamera.up.set(0, 1, 0);
        mirrorCamera.up.applyMatrix4(rotationMatrix);
        mirrorCamera.up.reflect(normal);
        mirrorCamera.lookAt<Vector3>(target);

        mirrorCamera.far = cameraFar(camera); // Used in WebGLBackground

        mirrorCamera.updateMatrixWorld();
        mirrorCamera.projectionMatrix.copy(camera.projectionMatrix);

        // Update the texture matrix
        const textureMatrix = this.textureMatrix;
        textureMatrix.set(
            0.5, 0.0, 0.0, 0.5,
            0.0, 0.5, 0.0, 0.5,
            0.0, 0.0, 0.5, 0.5,
            0.0, 0.0, 0.0, 1.0
        );
        textureMatrix.multiply(mirrorCamera.projectionMatrix);
        textureMatrix.multiply(mirrorCamera.matrixWorldInverse);

        // Now update projection matrix with new clip plane, implementing code from: http://www.terathon.com/code/oblique.html
        // Paper explaining this technique: http://www.terathon.com/lengyel/Lengyel-Oblique.pdf
        const mirrorPlane = this.mirrorPlane;
        mirrorPlane.setFromNormalAndCoplanarPoint(normal, mirrorWorldPosition);
        mirrorPlane.applyMatrix4(mirrorCamera.matrixWorldInverse);

        this.clipPlane.set(mirrorPlane.normal.x, mirrorPlane.normal.y, mirrorPlane.normal.z, mirrorPlane.constant);
        obliqueClip(mirrorCamera.projectionMatrix, this.clipPlane, this.clipBias);

        this.eye.setFromMatrixPosition(camera.matrixWorld);

        // Render
        const currentRenderTarget = renderer.getRenderTarget();
        const currentShadowAutoUpdate = renderer.shadowMap.autoUpdate;

        this.visible = false;
        renderer.shadowMap.autoUpdate = false; // Avoid re-computing shadows

        renderer.setRenderTarget(this.renderTarget);
        if (renderer.autoClear == false) renderer.clear();
        renderer.render(scene, mirrorCamera);

        this.visible = true;
        renderer.shadowMap.autoUpdate = currentShadowAutoUpdate;
        renderer.setRenderTarget(currentRenderTarget);
    }

    getRenderTarget(): RenderTarget {
        return this.renderTarget;
    }

    dispose(): void {
        this.renderTarget.dispose();
        this.material.dispose();
    }
}
