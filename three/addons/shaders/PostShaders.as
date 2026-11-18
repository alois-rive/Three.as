// The post-processing shaders three.js's passes use (CopyShader,
// OutputShader, FXAAShader, LuminosityHighPassShader...), as shader
// definitions over WGSL assets in three/shaders/post. three.js's shader
// objects ({ uniforms, vertexShader, fragmentShader }) become a class
// whose uniforms() makes fresh uniforms for each pass.

import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { NoBlending } from "../../constants";

/// A post shader: its WGSL asset, entry points and uniforms (in binding
/// order: values, then textures; see ShaderMaterial).
export class ShaderDefinition {
    name: string;
    /// The shader asset (project path without ".wgsl").
    shader: string;
    vertexEntryPoint: string;
    fragmentEntryPoint: string;

    constructor(name: string, shader: string, fragmentEntryPoint: string = "fs_main", vertexEntryPoint: string = "vs_main") {
        this.name = name;
        this.shader = shader;
        this.fragmentEntryPoint = fragmentEntryPoint;
        this.vertexEntryPoint = vertexEntryPoint;
    }

    /// Fresh uniforms for one material (three.js clones shader.uniforms).
    uniforms(): Map<string, UniformBase> { return new Map<string, UniformBase>(); }

    /// A ShaderMaterial for a fullscreen pass (no depth, no blending).
    createMaterial(): ShaderMaterial {
        const m = new ShaderMaterial({
            shader: this.shader, vertexEntryPoint: this.vertexEntryPoint, fragmentEntryPoint: this.fragmentEntryPoint,
        });
        m.name = this.name;
        m.uniforms = this.uniforms();
        m.depthTest = false;
        m.depthWrite = false;
        m.blending = NoBlending;
        return m;
    }
}

/// A texture slot not yet bound (renders as white).
export function emptyTexture(): Texture { return new Texture(); }

class CopyShaderDefinition extends ShaderDefinition {
    constructor() { super("CopyShader", "three/shaders/post/copy"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("opacity", new Uniform<f64>(1));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class OutputShaderDefinition extends ShaderDefinition {
    constructor() { super("OutputShader", "three/shaders/post/output"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("toneMapping", new Uniform<f64>(0));
        m.set("toneMappingExposure", new Uniform<f64>(1));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class FXAAShaderDefinition extends ShaderDefinition {
    constructor() { super("FXAAShader", "three/shaders/post/fxaa"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("resolution", new Uniform<Vector2>(new Vector2(1 / 1024, 1 / 512)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

/// The three stages of UnrealBloomPass share one shader and one uniform
/// layout (see three/shaders/post/bloom.wgsl).
export class BloomShaderDefinition extends ShaderDefinition {
    constructor(name: string, fragmentEntryPoint: string) { super(name, "three/shaders/post/bloom", fragmentEntryPoint); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("luminosityThreshold", new Uniform<f64>(1));
        m.set("smoothWidth", new Uniform<f64>(0.01));
        m.set("direction", new Uniform<Vector2>(new Vector2(1, 0)));
        m.set("kernelRadius", new Uniform<f64>(3));
        m.set("bloomStrength", new Uniform<f64>(1));
        m.set("bloomRadius", new Uniform<f64>(0));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("blurTexture1", new Uniform<Texture>(emptyTexture()));
        m.set("blurTexture2", new Uniform<Texture>(emptyTexture()));
        m.set("blurTexture3", new Uniform<Texture>(emptyTexture()));
        m.set("blurTexture4", new Uniform<Texture>(emptyTexture()));
        m.set("blurTexture5", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const CopyShader: ShaderDefinition = new CopyShaderDefinition();
export const OutputShader: ShaderDefinition = new OutputShaderDefinition();
export const FXAAShader: ShaderDefinition = new FXAAShaderDefinition();
export const LuminosityHighPassShader: ShaderDefinition = new BloomShaderDefinition("LuminosityHighPassShader", "fs_high_pass");
