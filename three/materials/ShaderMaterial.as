// three.js ShaderMaterial / RawShaderMaterial, with WGSL shader assets
// instead of GLSL strings (Rive compiles shaders from the project's .wgsl
// files; a script cannot hand it source).
//
//     const material = new ShaderMaterial({ shader: "shaders/wave" });   // shaders/wave.wgsl
//     material.uniforms.set("time", new Uniform<f64>(0));
//     material.uniforms.set("tint", new Uniform<Color>(new Color(0xff8800)));
//     material.uniforms.set("map", new Uniform<Texture>(texture));
//     // each frame:
//     material.uniform<f64>("time").value += seconds;
//
// The shader's bindings (declare only what you use, as prefix structs; the
// renderer's blocks are larger):
//
//     @group(0) @binding(0) var<uniform> frame: Frame;    // required
//     struct Frame { view_proj: mat4x4<f32>, view: mat4x4<f32>,
//                    inv_view_proj: mat4x4<f32>, camera_pos: vec4<f32> };
//     @group(1) @binding(0) var<uniform> object: Object;  // required
//     struct Object { model: mat4x4<f32>, normal_matrix: mat4x4<f32> };
//     @group(2) @binding(0) var<uniform> u: Uniforms;     // when there are
//         // non-texture uniforms: their values in insertion order, laid out
//         // with WGSL's alignment (f32 4, vec2 8, vec3/vec4/Color 16, mat4 16)
//     @group(2) @binding(1..n) var t_name: texture_2d<f32>;  // texture
//         // uniforms in insertion order, then one sampler at binding n + 1
//
// Vertex inputs: @location(0) position, (1) normal, (2) uv, (3) colour
// (vec4). The output goes straight to the canvas: write sRGB, premultiplied
// colour (the built-in materials do this in the shader).

import { Material, MaterialParameters } from "./Material";
import { MaterialUniforms } from "./MaterialUniforms";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Vector4 } from "../math/Vector4";
import { Color } from "../math/Color";
import { Matrix4 } from "../math/Matrix4";
import { Texture } from "../textures/Texture";

/// A uniform of any type (three.js's IUniform).
export abstract class UniformBase {
    /// Bytes and alignment in a WGSL uniform block (0 for textures).
    abstract size(): i32;
    abstract align(): i32;
    /// Writes the value at byte `offset` of `f`.
    abstract write(f: Float32Array, offset: i32): void;
    texture(): Texture? { return null; }
    /// A copy (vectors, colours and matrices copied; textures shared), as
    /// three.js's UniformsUtils.clone.
    abstract clone(): UniformBase;
}

/// A uniform holding `value`: f64 (f32 in WGSL), Vector2, Vector3,
/// Vector4, Color (vec3), Matrix4 or Texture.
export class Uniform<T> extends UniformBase {
    value: T;

    constructor(value: T) {
        super();
        this.value = value;
    }

    override size(): i32 {
        if (isReference<T>()) {
            const v = this.value;
            if (v instanceof Vector2) return 8;
            if (v instanceof Vector3 || v instanceof Color) return 12;
            if (v instanceof Vector4) return 16;
            if (v instanceof Matrix4) return 64;
            return 0;
        }
        return 4;
    }

    override align(): i32 {
        if (isReference<T>()) {
            const v = this.value;
            if (v instanceof Vector2) return 8;
            if (v instanceof Texture) return 1;
            return 16;
        }
        return 4;
    }

    override write(f: Float32Array, offset: i32): void {
        const o = offset >> 2;
        if (isReference<T>()) {
            const v = this.value;
            if (v instanceof Vector2) {
                f[o] = <f32>(v as Vector2).x; f[o + 1] = <f32>(v as Vector2).y;
            } else if (v instanceof Vector3) {
                f[o] = <f32>(v as Vector3).x; f[o + 1] = <f32>(v as Vector3).y; f[o + 2] = <f32>(v as Vector3).z;
            } else if (v instanceof Color) {
                f[o] = <f32>(v as Color).r; f[o + 1] = <f32>(v as Color).g; f[o + 2] = <f32>(v as Color).b;
            } else if (v instanceof Vector4) {
                const w = v as Vector4;
                f[o] = <f32>w.x; f[o + 1] = <f32>w.y; f[o + 2] = <f32>w.z; f[o + 3] = <f32>w.w;
            } else if (v instanceof Matrix4) {
                const e = (v as Matrix4).elements;
                for (let k = 0; k < 16; k++) f[o + k] = e[k];
            }
        } else if (isFloat<T>()) {
            f[o] = <f32>(<f64>this.value);
        } else {
            f[o] = <f32>(<f64>this.value);
        }
    }

    override texture(): Texture? {
        if (isReference<T>()) {
            const v = this.value;
            if (v instanceof Texture) return v as Texture;
        }
        return null;
    }

    override clone(): UniformBase {
        if (isReference<T>()) {
            const v = this.value;
            if (v instanceof Vector2) return new Uniform<Vector2>((v as Vector2).clone());
            if (v instanceof Vector3) return new Uniform<Vector3>((v as Vector3).clone());
            if (v instanceof Color) return new Uniform<Color>((v as Color).clone());
            if (v instanceof Vector4) return new Uniform<Vector4>((v as Vector4).clone());
            if (v instanceof Matrix4) return new Uniform<Matrix4>((v as Matrix4).clone());
        }
        return new Uniform<T>(this.value);
    }
}

export class ShaderMaterialParameters extends MaterialParameters {
    /// The shader asset's name: its path in the project without ".wgsl"
    /// ("shaders/wave"); a bare file name is tried too, as some CLI versions
    /// name shaders that way.
    shader: string = "";
    /// Entry points; empty takes the shader's first @vertex / @fragment.
    vertexEntryPoint: string = "";
    fragmentEntryPoint: string = "";
}

export class ShaderMaterial extends Material {
    readonly isShaderMaterial: bool = true;
    shader: string = "";
    vertexEntryPoint: string = "";
    fragmentEntryPoint: string = "";
    /// Uniforms, written in insertion order.
    uniforms: Map<string, UniformBase> = new Map<string, UniformBase>();

    constructor(parameters: ShaderMaterialParameters? = null) {
        super();
        this.type = "ShaderMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.shader = parameters.shader;
            this.vertexEntryPoint = parameters.vertexEntryPoint;
            this.fragmentEntryPoint = parameters.fragmentEntryPoint;
        }
    }

    /// The uniform `name`, typed (three.js: material.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
    }
}

/// three.js's RawShaderMaterial: the same here (nothing is prepended to a
/// ShaderMaterial's shader either).
export class RawShaderMaterial extends ShaderMaterial {
    readonly isRawShaderMaterial: bool = true;

    constructor(parameters: ShaderMaterialParameters? = null) {
        super(parameters);
        this.type = "RawShaderMaterial";
    }
}
