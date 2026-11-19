// three.js examples/jsm/objects/Reflector.js (r170): a planar mirror. Each
// render, before the pass, onBeforeRender renders the scene from the
// camera mirrored in the reflector's plane (its local XY plane, facing +Z)
// into a HalfFloatType render target, with an oblique near plane on the
// mirror, and the ReflectorShader projects it back through `textureMatrix`.
//
//     const mirror = new Reflector(new PlaneGeometry(2, 2), {
//         textureWidth: 1024, textureHeight: 1024, color: 0xc1cbcb,
//     });
//     scene.add(mirror);
//
// Differences from three.js (see docs/DEVIATIONS.md): the options are a
// typed ReflectorOptions (`color` a hex number, `shader` a
// ShaderDefinition over a WGSL asset); onBeforeRender is a method the
// renderer calls before the render's pass; the oblique clipping writes
// WebGPU's [0, 1] depth (as three.js's ReflectorNode); `updateMatrices`
// is the camera and matrix half of onBeforeRender (Rive-only, for tests).

import { Mesh } from "../../objects/Mesh";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry, GeometryGroup } from "../../core/BufferGeometry";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { Material } from "../../materials/Material";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Color } from "../../math/Color";
import { Matrix4 } from "../../math/Matrix4";
import { Plane } from "../../math/Plane";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { Texture } from "../../textures/Texture";
import { RenderTarget } from "../../renderers/RenderTarget";
import { GPURenderer } from "../../renderers/GPURenderer";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { HalfFloatType } from "../../constants";

/// Reflector's options (three.js's options object).
export class ReflectorOptions {
    /// The mirror's tint (hex), blended with the reflection (overlay).
    color: u32 = 0x7F7F7F;
    /// The render target's size in pixels (0: 512, as three.js's `||`).
    textureWidth: i32 = 512;
    textureHeight: i32 = 512;
    /// Moves the oblique near plane off the mirror (three.js units of
    /// clip depth).
    clipBias: f64 = 0;
    /// The shader (null: Reflector.ReflectorShader). Its uniforms must hold
    /// `color`, `tDiffuse` and `textureMatrix`.
    shader: ShaderDefinition? = null;
    /// MSAA samples of the render target (4; 0 or 1 for none).
    multisample: i32 = 4;
}

class ReflectorShaderDefinition extends ShaderDefinition {
    constructor() { super("ReflectorShader", "three/shaders/objects/reflector"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("color", new Uniform<Color>(new Color(0x7F7F7F)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("textureMatrix", new Uniform<Matrix4>(new Matrix4()));
        return m;
    }
}

/// The oblique near plane of Lengyel ("Oblique View Frustum Depth
/// Projection and Clipping") on `projection`, for `plane` in view space
/// (x, y, z normal, w constant), in WebGPU's [0, 1] depth range as
/// three.js's ReflectorNode: the near plane becomes the clip plane.
export function obliqueClip(projection: Matrix4, plane: Vector4, clipBias: f64): void {
    const e = projection.elements;
    const q = _q;
    q.x = (Math.sign(plane.x) + <f64>e[8]) / <f64>e[0];
    q.y = (Math.sign(plane.y) + <f64>e[9]) / <f64>e[5];
    q.z = -1.0;
    q.w = (1.0 + <f64>e[10]) / <f64>e[14];
    // Calculate the scaled plane vector
    plane.multiplyScalar(1.0 / plane.dot(q));
    // Replacing the third row of the projection matrix
    e[2] = <f32>plane.x;
    e[6] = <f32>plane.y;
    e[10] = <f32>(plane.z - clipBias);
    e[14] = <f32>plane.w;
}

const _q = new Vector4();

export class Reflector extends Mesh {
    readonly isReflector: bool = true;
    /// The mirrored camera the reflection renders from.
    camera: PerspectiveCamera = new PerspectiveCamera();
    /// Maps the reflector's local positions to the reflection's texture
    /// coordinates (the shader's `textureMatrix`).
    readonly textureMatrix: Matrix4 = new Matrix4();
    clipBias: f64;
    private renderTarget: RenderTarget;

    private reflectorPlane: Plane = new Plane();
    private normal: Vector3 = new Vector3();
    private reflectorWorldPosition: Vector3 = new Vector3();
    private cameraWorldPosition: Vector3 = new Vector3();
    private rotationMatrix: Matrix4 = new Matrix4();
    private lookAtPosition: Vector3 = new Vector3(0, 0, -1);
    private clipPlane: Vector4 = new Vector4();
    private view: Vector3 = new Vector3();
    private target: Vector3 = new Vector3();

    static ReflectorShader: ShaderDefinition = new ReflectorShaderDefinition();

    constructor(geometry: BufferGeometry, options: ReflectorOptions? = null) {
        super(geometry);
        this.type = "Reflector";
        const o = options != null ? options! : new ReflectorOptions();
        const color = new Color(<f64>o.color);
        const textureWidth = o.textureWidth > 0 ? o.textureWidth : 512;
        const textureHeight = o.textureHeight > 0 ? o.textureHeight : 512;
        this.clipBias = o.clipBias;
        const shader = o.shader != null ? o.shader! : Reflector.ReflectorShader;
        this.renderTarget = new RenderTarget(<u32>textureWidth, <u32>textureHeight,
            { samples: o.multisample, type: HalfFloatType });
        const material = new ShaderMaterial({
            shader: shader.shader, vertexEntryPoint: shader.vertexEntryPoint,
            fragmentEntryPoint: shader.fragmentEntryPoint,
        });
        material.name = shader.name;
        material.uniforms = shader.uniforms();
        material.uniform<Texture>("tDiffuse").value = this.renderTarget.texture;
        material.uniform<Color>("color").value = color;
        material.uniform<Matrix4>("textureMatrix").value = this.textureMatrix;
        this.material = material;
    }

    /// Places the mirrored camera for `camera` and updates textureMatrix
    /// and the camera's oblique projection: the first half of
    /// onBeforeRender (Rive-only). False when the reflector faces away from
    /// the camera (nothing to render).
    updateMatrices(camera: Camera): bool {
        const virtualCamera = this.camera;
        const normal = this.normal;
        const view = this.view;
        const target = this.target;
        const rotationMatrix = this.rotationMatrix;
        const lookAtPosition = this.lookAtPosition;
        this.reflectorWorldPosition.setFromMatrixPosition(this.matrixWorld);
        this.cameraWorldPosition.setFromMatrixPosition(camera.matrixWorld);

        rotationMatrix.extractRotation(this.matrixWorld);

        normal.set(0, 0, 1);
        normal.applyMatrix4(rotationMatrix);

        view.subVectors(this.reflectorWorldPosition, this.cameraWorldPosition);

        // Avoid rendering when reflector is facing away
        if (view.dot(normal) > 0) return false;

        view.reflect(normal).negate();
        view.add(this.reflectorWorldPosition);

        rotationMatrix.extractRotation(camera.matrixWorld);

        lookAtPosition.set(0, 0, -1);
        lookAtPosition.applyMatrix4(rotationMatrix);
        lookAtPosition.add(this.cameraWorldPosition);

        target.subVectors(this.reflectorWorldPosition, lookAtPosition);
        target.reflect(normal).negate();
        target.add(this.reflectorWorldPosition);

        virtualCamera.position.copy(view);
        virtualCamera.up.set(0, 1, 0);
        virtualCamera.up.applyMatrix4(rotationMatrix);
        virtualCamera.up.reflect(normal);
        virtualCamera.lookAt<Vector3>(target);

        virtualCamera.far = cameraFar(camera); // Used in WebGLBackground

        virtualCamera.updateMatrixWorld();
        virtualCamera.projectionMatrix.copy(camera.projectionMatrix);

        // Update the texture matrix
        const textureMatrix = this.textureMatrix;
        textureMatrix.set(
            0.5, 0.0, 0.0, 0.5,
            0.0, 0.5, 0.0, 0.5,
            0.0, 0.0, 0.5, 0.5,
            0.0, 0.0, 0.0, 1.0
        );
        textureMatrix.multiply(virtualCamera.projectionMatrix);
        textureMatrix.multiply(virtualCamera.matrixWorldInverse);
        textureMatrix.multiply(this.matrixWorld);

        // Now update projection matrix with new clip plane, implementing code from: http://www.terathon.com/code/oblique.html
        // Paper explaining this technique: http://www.terathon.com/lengyel/Lengyel-Oblique.pdf
        const reflectorPlane = this.reflectorPlane;
        reflectorPlane.setFromNormalAndCoplanarPoint(normal, this.reflectorWorldPosition);
        reflectorPlane.applyMatrix4(virtualCamera.matrixWorldInverse);

        this.clipPlane.set(reflectorPlane.normal.x, reflectorPlane.normal.y, reflectorPlane.normal.z,
            reflectorPlane.constant);
        obliqueClip(virtualCamera.projectionMatrix, this.clipPlane, this.clipBias);
        return true;
    }

    /// Renders the reflection (the renderer calls it before the pass).
    override onBeforeRender(renderer: GPURenderer, scene: Object3D, camera: Camera, geometry: BufferGeometry?,
                            material: Material?, group: GeometryGroup?): void {
        if (!this.updateMatrices(camera)) return;

        // Render
        this.visible = false;

        const currentRenderTarget = renderer.getRenderTarget();
        const currentShadowAutoUpdate = renderer.shadowMap.autoUpdate;
        renderer.shadowMap.autoUpdate = false; // Avoid re-computing shadows

        renderer.setRenderTarget(this.renderTarget);
        if (renderer.autoClear == false) renderer.clear();
        renderer.render(scene, this.camera);

        renderer.shadowMap.autoUpdate = currentShadowAutoUpdate;
        renderer.setRenderTarget(currentRenderTarget);

        this.visible = true;
    }

    getRenderTarget(): RenderTarget {
        return this.renderTarget;
    }

    dispose(): void {
        this.renderTarget.dispose();
        this.material.dispose();
    }
}

/// A camera's far plane (perspective or orthographic).
export function cameraFar(camera: Camera): f64 {
    if (camera instanceof PerspectiveCamera) return (camera as PerspectiveCamera).far;
    if (camera instanceof OrthographicCamera) return (camera as OrthographicCamera).far;
    return 2000;
}
