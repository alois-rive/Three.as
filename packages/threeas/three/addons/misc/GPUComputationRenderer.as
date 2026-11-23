// three.js examples/jsm/misc/GPUComputationRenderer.js: GPGPU by render to
// texture. Each variable is a sizeX x sizeY texture of RGBA floats,
// computed every compute() by a fragment shader that reads the variables
// it depends on (their previous values, itself included); two render
// targets per variable ping-pong.
//
//     const gpuCompute = new GPUComputationRenderer(1024, 1024, renderer);
//     const pos0 = gpuCompute.createTexture();
//     const vel0 = gpuCompute.createTexture();
//     // fill (pos0.data as Float32Array) and vel0's ...
//     const velVar = gpuCompute.addVariable("textureVelocity", "shaders/velocity", vel0);
//     const posVar = gpuCompute.addVariable("texturePosition", "shaders/position", pos0);
//     gpuCompute.setVariableDependencies(velVar, [velVar, posVar]);
//     gpuCompute.setVariableDependencies(posVar, [velVar, posVar]);
//     velVar.material.uniforms.set("time", new Uniform<f64>(0));
//     const error = gpuCompute.init();
//     if (error != null) context.log(error);
//     // each frame, from draw(), before rendering the scene:
//     gpuCompute.compute();
//     myMaterial.uniform<Texture>("texturePosition").value = gpuCompute.getCurrentRenderTarget(posVar).texture;
//
// Differences from three.js (see docs/DEVIATIONS.md):
// - A compute shader is a WGSL shader asset (its project path without
//   ".wgsl"), not a GLSL string, holding both stages: copy the vertex
//   stage of three/shaders/misc/gpu_computation.wgsl. Nothing is injected;
//   the ShaderMaterial contract binds its uniforms at group 2, in insertion
//   order: `resolution` first (vec2<f32>, three.js's define), the values
//   the caller adds, then the textures: the caller's, then one per
//   dependency in setVariableDependencies' order (added by init(), named
//   after the variable), then one sampler (the first texture's: nearest).
//   Read texels with textureLoad at @builtin(position): row 0 of each
//   variable is row 0 of every texture, texel (x, y) is data index
//   (y * sizeX + x) * 4.
// - FloatType (the default) variables are rgba32float where the device
//   renders 32-bit floats (`features().colorBufferFloat`), rgba16float
//   elsewhere; createTexture()'s DataTextures upload as 32-bit floats.
// - init() renders nothing (scripts render only from draw()): the initial
//   values are copied into the targets by the next compute() (or
//   flushInitialValues(), from draw()).
// - `renderer` may be null, in headless tests: init() then skips the
//   device check and compute() only swaps the targets.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Material } from "../../materials/Material";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { Vector2 } from "../../math/Vector2";
import { FullScreenQuad } from "../postprocessing/Pass";
import {
    ClampToEdgeWrapping, FloatType, HalfFloatType, NearestFilter, RGBAFormat, UnsignedByteType,
} from "../../constants";

/// The pass-through shader (renderTexture) and the template of compute
/// shaders.
export const GPU_COMPUTATION_SHADER = "three/shaders/misc/gpu_computation";

/// A variable (three.js's object literal): its state is a pair of render
/// targets computed by `material`.
export class GPUComputationVariable {
    name: string;
    initialValueTexture: Texture;
    material: ShaderMaterial;
    /// The variables its shader reads (null: none).
    dependencies: Array<GPUComputationVariable>? = null;
    renderTargets: Array<RenderTarget> = [];
    /// The targets' wrapping (0: three.js's null, ClampToEdgeWrapping).
    wrapS: i32 = 0;
    wrapT: i32 = 0;
    minFilter: i32 = NearestFilter;
    magFilter: i32 = NearestFilter;

    constructor(name: string, initialValueTexture: Texture, material: ShaderMaterial) {
        this.name = name;
        this.initialValueTexture = initialValueTexture;
        this.material = material;
    }
}

export class GPUComputationRenderer {
    variables: Array<GPUComputationVariable> = [];
    currentTextureIndex: i32 = 0;

    private sizeX: i32;
    private sizeY: i32;
    private renderer: GPURenderer?;
    private dataType: i32 = FloatType;
    private passThruUniforms: Map<string, UniformBase> = new Map<string, UniformBase>();
    private passThruShader: ShaderMaterial;
    private quad: FullScreenQuad;
    // Initial values init() queued for the next compute (input, output).
    private pendingInputs: Array<Texture> = [];
    private pendingOutputs: Array<RenderTarget> = [];

    /// `sizeX` x `sizeY` elements per variable.
    constructor(sizeX: i32, sizeY: i32, renderer: GPURenderer?) {
        this.sizeX = sizeX;
        this.sizeY = sizeY;
        this.renderer = renderer;
        this.passThruUniforms.set("passThruTexture", new Uniform<Texture>(new Texture()));
        this.passThruShader = this.createShaderMaterial(GPU_COMPUTATION_SHADER, this.passThruUniforms);
        this.quad = new FullScreenQuad(this.passThruShader);
    }

    /// FloatType (the default), HalfFloatType or UnsignedByteType targets
    /// for the variables init() makes next.
    setDataType(type: i32): GPUComputationRenderer {
        this.dataType = type;
        return this;
    }

    /// A variable named `variableName` (its texture's uniform name in the
    /// shaders that depend on it), computed by the shader asset
    /// `computeFragmentShader`, starting from `initialValueTexture`.
    addVariable(variableName: string, computeFragmentShader: string,
                initialValueTexture: Texture): GPUComputationVariable {
        const material = this.createShaderMaterial(computeFragmentShader);
        const variable = new GPUComputationVariable(variableName, initialValueTexture, material);
        this.variables.push(variable);
        return variable;
    }

    setVariableDependencies(variable: GPUComputationVariable, dependencies: Array<GPUComputationVariable>?): void {
        variable.dependencies = dependencies;
    }

    /// Why the device cannot run a computation of `dataType` (null: it
    /// can). `known` false (no device yet) passes.
    static supportError(dataType: i32, known: bool, colorBufferFloat: bool, colorBufferHalfFloat: bool): string? {
        if (!known || dataType == UnsignedByteType) return null;
        if (dataType == HalfFloatType && !colorBufferHalfFloat) return "No support for half float render targets.";
        if (dataType == FloatType && !colorBufferFloat && !colorBufferHalfFloat) {
            return "No support for float render targets.";
        }
        return null;
    }

    /// Makes each variable's two render targets (filled with its initial
    /// value at the next compute) and adds its dependencies' texture
    /// uniforms. Returns an error, or null.
    init(): string? {
        const r = this.renderer;
        if (r != null) {
            const f = r.context.features();
            const error = GPUComputationRenderer.supportError(this.dataType, f.known, f.colorBufferFloat,
                f.colorBufferHalfFloat);
            if (error != null) return error;
        }
        for (let i = 0; i < this.variables.length; i++) {
            const variable = this.variables[i];
            // Creates rendertargets and initialize them with input texture
            variable.renderTargets.length = 0;
            variable.renderTargets.push(this.createRenderTarget(this.sizeX, this.sizeY, variable.wrapS, variable.wrapT,
                variable.minFilter, variable.magFilter));
            variable.renderTargets.push(this.createRenderTarget(this.sizeX, this.sizeY, variable.wrapS, variable.wrapT,
                variable.minFilter, variable.magFilter));
            this.queueInitialValue(variable.initialValueTexture, variable.renderTargets[0]);
            this.queueInitialValue(variable.initialValueTexture, variable.renderTargets[1]);

            // Adds dependencies uniforms to the ShaderMaterial
            const deps = variable.dependencies;
            if (deps != null) {
                for (let d = 0; d < deps.length; d++) {
                    const depVar = deps[d];
                    if (depVar.name != variable.name) {
                        // Checks if variable exists
                        let found = false;
                        for (let j = 0; j < this.variables.length; j++) {
                            if (depVar.name == this.variables[j].name) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            return "Variable dependency not found. Variable=" + variable.name + ", dependency="
                                + depVar.name;
                        }
                    }
                    variable.material.uniforms.set(depVar.name, new Uniform<Texture>(new Texture()));
                }
            }
        }
        this.currentTextureIndex = 0;
        return null;
    }

    private queueInitialValue(input: Texture, output: RenderTarget): void {
        this.pendingInputs.push(input);
        this.pendingOutputs.push(output);
    }

    /// Copies the initial values init() queued into the targets (compute()
    /// does it first; call it from draw()).
    flushInitialValues(): void {
        if (this.pendingInputs.length == 0 || this.renderer == null) return;
        const inputs = this.pendingInputs;
        const outputs = this.pendingOutputs;
        this.pendingInputs = [];
        this.pendingOutputs = [];
        for (let i = 0; i < inputs.length; i++) this.renderTexture(inputs[i], outputs[i]);
    }

    /// Computes every variable once, in the order they were added, each
    /// reading its dependencies' current values; then swaps the targets.
    compute(): void {
        this.flushInitialValues();
        const currentTextureIndex = this.currentTextureIndex;
        const nextTextureIndex = this.currentTextureIndex == 0 ? 1 : 0;
        for (let i = 0, il = this.variables.length; i < il; i++) {
            const variable = this.variables[i];
            // Sets texture dependencies uniforms
            const deps = variable.dependencies;
            if (deps != null) {
                const uniforms = variable.material.uniforms;
                for (let d = 0, dl = deps.length; d < dl; d++) {
                    const depVar = deps[d];
                    (uniforms.get(depVar.name) as Uniform<Texture>).value = depVar.renderTargets[currentTextureIndex].texture;
                }
            }
            // Performs the computation for this variable
            this.doRenderTarget(variable.material, variable.renderTargets[nextTextureIndex]);
        }
        this.currentTextureIndex = nextTextureIndex;
    }

    getCurrentRenderTarget(variable: GPUComputationVariable): RenderTarget {
        return variable.renderTargets[this.currentTextureIndex];
    }

    getAlternateRenderTarget(variable: GPUComputationVariable): RenderTarget {
        return variable.renderTargets[this.currentTextureIndex == 0 ? 1 : 0];
    }

    /// Frees the quad, the initial textures and the render targets.
    dispose(): void {
        this.quad.dispose();
        this.pendingInputs.length = 0;
        this.pendingOutputs.length = 0;
        const variables = this.variables;
        for (let i = 0; i < variables.length; i++) {
            const variable = variables[i];
            variable.initialValueTexture.dispose();
            const renderTargets = variable.renderTargets;
            for (let j = 0; j < renderTargets.length; j++) renderTargets[j].dispose();
        }
    }

    /// Sets the material's `resolution` uniform (three.js's define) to the
    /// computation's size: a vec2<f32>, first in its uniform block when
    /// added first (createShaderMaterial does).
    addResolutionDefine(materialShader: ShaderMaterial): void {
        const u = materialShader.uniforms;
        if (u.has("resolution")) {
            (u.get("resolution") as Uniform<Vector2>).value.set(<f64>this.sizeX, <f64>this.sizeY);
        } else {
            u.set("resolution", new Uniform<Vector2>(new Vector2(<f64>this.sizeX, <f64>this.sizeY)));
        }
    }

    // The following functions can be used to compute things manually

    /// A ShaderMaterial of the shader asset `computeFragmentShader` (its
    /// project path without ".wgsl"), its uniforms `resolution` and then
    /// `uniforms`' (shared, as three.js).
    createShaderMaterial(computeFragmentShader: string, uniforms: Map<string, UniformBase>? = null): ShaderMaterial {
        const material = new ShaderMaterial({ shader: computeFragmentShader });
        material.name = "GPUComputationShader";
        this.addResolutionDefine(material);
        if (uniforms != null) {
            const names = uniforms.keys();
            for (let i = 0; i < names.length; i++) material.uniforms.set(names[i], uniforms.get(names[i]));
        }
        return material;
    }

    /// A render target for computing (0 arguments take the computation's
    /// size, ClampToEdgeWrapping and NearestFilter, as three.js's nulls).
    createRenderTarget(sizeXTexture: i32 = 0, sizeYTexture: i32 = 0, wrapS: i32 = 0, wrapT: i32 = 0,
                       minFilter: i32 = 0, magFilter: i32 = 0): RenderTarget {
        const o = new RenderTargetOptions();
        o.wrapS = wrapS != 0 ? wrapS : ClampToEdgeWrapping;
        o.wrapT = wrapT != 0 ? wrapT : ClampToEdgeWrapping;
        o.minFilter = minFilter != 0 ? minFilter : NearestFilter;
        o.magFilter = magFilter != 0 ? magFilter : NearestFilter;
        o.type = this.dataType;
        // 32-bit floats where the device renders them (see RenderTarget).
        if (this.dataType == FloatType) o.internalFormat = "RGBA32F";
        o.depthBuffer = false;
        return new RenderTarget(<u32>(sizeXTexture != 0 ? sizeXTexture : this.sizeX),
            <u32>(sizeYTexture != 0 ? sizeYTexture : this.sizeY), o);
    }

    /// A sizeX x sizeY RGBA FloatType DataTexture of zeros, uploaded as
    /// 32-bit floats: fill `texture.data as Float32Array`.
    createTexture(): DataTexture {
        const data = new Float32Array(this.sizeX * this.sizeY * 4);
        const texture = new DataTexture(data, <u32>this.sizeX, <u32>this.sizeY, RGBAFormat, FloatType);
        texture.internalFormat = "RGBA32F";
        texture.needsUpdate = true;
        return texture;
    }

    /// Takes a texture, and render out in rendertarget (from draw()).
    renderTexture(input: Texture, output: RenderTarget): void {
        const u = this.passThruUniforms.get("passThruTexture") as Uniform<Texture>;
        const placeholder = u.value;
        u.value = input;
        this.doRenderTarget(this.passThruShader, output);
        u.value = placeholder;
    }

    /// Renders `material` over the whole of `output` (from draw()).
    doRenderTarget(material: Material, output: RenderTarget): void {
        const renderer = this.renderer;
        if (renderer == null) return;
        const currentRenderTarget = renderer.getRenderTarget();
        const currentShadowAutoUpdate = renderer.shadowMap.autoUpdate;
        renderer.shadowMap.autoUpdate = false;   // Avoid re-computing shadows
        this.quad.material = material;
        renderer.setRenderTarget(output);
        this.quad.render(renderer);
        this.quad.material = this.passThruShader;
        renderer.shadowMap.autoUpdate = currentShadowAutoUpdate;
        renderer.setRenderTarget(currentRenderTarget);
    }
}
