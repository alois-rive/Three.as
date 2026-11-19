// The addon objects of three/addons/objects (M16) without a GPU: Reflector
// and Refractor matrices (virtual camera, texture matrix, oblique near
// plane), Water / Water2 / Sky uniforms, Lensflare set-up.
// rive . --test

import { Tests } from "rive/test";
import { Reflector, obliqueClip } from "../three/addons/objects/Reflector";
import { Refractor } from "../three/addons/objects/Refractor";
import { Water } from "../three/addons/objects/Water";
import { Water as Water2 } from "../three/addons/objects/Water2";
import { Sky } from "../three/addons/objects/Sky";
import { Lensflare, LensflareElement } from "../three/addons/objects/Lensflare";
import { PlaneGeometry } from "../three/geometries/PlaneGeometry";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { ShaderMaterial } from "../three/materials/ShaderMaterial";
import { Matrix4 } from "../three/math/Matrix4";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { Vector4 } from "../three/math/Vector4";
import { Color } from "../three/math/Color";
import { Texture } from "../three/textures/Texture";
import { Dynamic } from "rive/dynamic";
import { BackSide, HalfFloatType } from "../three/constants";

function near(a: f64, b: f64, eps: f64 = 1e-4): bool { return Math.abs(a - b) < eps; }

function camera(x: f64, y: f64, z: f64): PerspectiveCamera {
    const c = new PerspectiveCamera(50, 1.5, 0.1, 100);
    c.position.set(x, y, z);
    c.lookAt<f64>(0, 0, 0);
    c.updateMatrixWorld();
    return c;
}

/// `p` (world) projected by the camera's view and projection (NDC, z in [0, 1]).
function project(c: PerspectiveCamera, p: Vector3): Vector3 {
    return p.clone().applyMatrix4(c.matrixWorldInverse).applyMatrix4(c.projectionMatrix);
}

/// Bytes of a ShaderMaterial's uniform block, as the renderer packs it.
function blockOffsets(m: ShaderMaterial): Array<i32> {
    const out: Array<i32> = [];
    const names = m.uniforms.keys();
    let offset = 0;
    for (let i = 0; i < names.length; i++) {
        const u = m.uniforms.get(names[i]);
        const s = u.size();
        if (s == 0) continue;
        const a = u.align();
        offset = (offset + a - 1) / a * a;
        out.push(offset);
        offset += s;
    }
    return out;
}

function firstTexture(m: ShaderMaterial): string {
    const names = m.uniforms.keys();
    for (let i = 0; i < names.length; i++) if (m.uniforms.get(names[i]).texture() != null) return names[i];
    return "";
}

export class ObjectsTests extends Tests {
    override run(): void {
        group("Reflector", () => {
            test("options, material and render target", (expect) => {
                const r = new Reflector(new PlaneGeometry(2, 2), { textureWidth: 256, textureHeight: 128, color: 0x889999 });
                expect.that(r.isReflector).is(true);
                expect.that(r.type).is("Reflector");
                const rt = r.getRenderTarget();
                expect.that(<f64>rt.width).is(256);
                expect.that(<f64>rt.height).is(128);
                expect.that(<f64>rt.type).is(<f64>HalfFloatType);
                const m = r.material as ShaderMaterial;
                expect.that(m.shader).is("three/shaders/objects/reflector");
                expect.that(m.uniform<Texture>("tDiffuse").value === rt.texture).is(true);
                expect.that(m.uniform<Matrix4>("textureMatrix").value === r.textureMatrix).is(true);
                expect.that(near(m.uniform<Color>("color").value.getHex(), 0x889999)).is(true);
                // WGSL block: color (vec3) at 0, textureMatrix at 16.
                const o = blockOffsets(m);
                expect.that(<f64>o[0]).is(0);
                expect.that(<f64>o[1]).is(16);
                // three.js's `||` defaults.
                const d = new Reflector(new PlaneGeometry(1, 1), { textureWidth: 0, textureHeight: 0 });
                expect.that(<f64>d.getRenderTarget().width).is(512);
            });
            test("the mirrored camera and texture matrix", (expect) => {
                const r = new Reflector(new PlaneGeometry(2, 2));
                r.updateMatrixWorld();
                const c = camera(1, 0.5, 5);
                expect.that(r.updateMatrices(c)).is(true);
                // The virtual camera is the camera mirrored in z = 0.
                const v = r.camera;
                expect.that(near(v.position.x, 1)).is(true);
                expect.that(near(v.position.y, 0.5)).is(true);
                expect.that(near(v.position.z, -5)).is(true);
                // The texture matrix maps a mirror point where the mirrored
                // camera sees it, in [0, 1].
                const p = new Vector3(0.3, -0.2, 0);
                const uv = p.clone().applyMatrix4(r.textureMatrix);
                const ndc = new Vector3(0.3, -0.2, 0).applyMatrix4(v.matrixWorldInverse);
                const unclipped = new PerspectiveCamera(50, 1.5, 0.1, 100);
                ndc.applyMatrix4(unclipped.projectionMatrix);
                expect.that(near(uv.x, ndc.x * 0.5 + 0.5)).is(true);
                expect.that(near(uv.y, ndc.y * 0.5 + 0.5)).is(true);
                // Seen from the mirror's side, +x lands on the left.
                const right = new Vector3(0.5, 0, 0).applyMatrix4(r.textureMatrix);
                const left = new Vector3(-0.5, 0, 0).applyMatrix4(r.textureMatrix);
                expect.that(right.x < left.x).is(true);
                const up = new Vector3(0, 0.5, 0).applyMatrix4(r.textureMatrix);
                const down = new Vector3(0, -0.5, 0).applyMatrix4(r.textureMatrix);
                expect.that(up.y > down.y).is(true);
            });
            test("the oblique near plane is the mirror", (expect) => {
                const r = new Reflector(new PlaneGeometry(2, 2));
                r.position.set(0, 0, -1);
                r.updateMatrixWorld();
                const c = camera(0.4, 0.3, 4);
                expect.that(r.updateMatrices(c)).is(true);
                const v = r.camera;
                // On the mirror: depth 0; in front of it (the camera's
                // side: what the mirror shows): inside [0, 1]; behind it
                // (between the mirrored camera and the mirror): clipped.
                const on = project(v, new Vector3(0.2, -0.1, -1));
                expect.that(near(on.z, 0, 1e-3)).is(true);
                const front = project(v, new Vector3(0.2, -0.1, 0));
                expect.that(front.z > 0 && front.z < 1).is(true);
                const behind = project(v, new Vector3(0.2, -0.1, -3));
                expect.that(behind.z < 0).is(true);
                // x and y are the camera's projection's.
                const plain = new PerspectiveCamera(50, 1.5, 0.1, 100);
                const e = v.projectionMatrix.elements, f = plain.projectionMatrix.elements;
                expect.that(near(e[0], f[0]) && near(e[5], f[5]) && near(e[8], f[8])).is(true);
            });
            test("clipBias moves the near plane", (expect) => {
                const proj = new PerspectiveCamera(50, 1, 0.1, 100).projectionMatrix;
                const a = proj.clone(), b = proj.clone();
                obliqueClip(a, new Vector4(0, 0, 1, 2), 0);
                obliqueClip(b, new Vector4(0, 0, 1, 2), 0.1);
                expect.that(near(a.elements[10] - b.elements[10], 0.1)).is(true);
                // The plane z = -2 (view space) is the new near plane.
                const p = new Vector3(0.1, 0.1, -2).applyMatrix4(a);
                expect.that(near(p.z, 0, 1e-4)).is(true);
            });
            test("nothing to render facing away", (expect) => {
                const r = new Reflector(new PlaneGeometry(2, 2));
                r.updateMatrixWorld();
                expect.that(r.updateMatrices(camera(0, 0, -5))).is(false);
            });
        });

        group("Refractor", () => {
            test("plane, texture matrix and clipped camera", (expect) => {
                const r = new Refractor(new PlaneGeometry(2, 2), { color: 0x999999 });
                expect.that(r.isRefractor).is(true);
                expect.that((r.material as ShaderMaterial).transparent).is(true);
                r.updateMatrixWorld();
                const c = camera(0.5, 0.5, 5);
                expect.that(r.updateMatrices(c)).is(true);
                // The texture matrix is the camera's own projection.
                const p = new Vector3(0.25, 0.4, 0);
                const uv = p.clone().applyMatrix4(r.textureMatrix);
                const ndc = project(c, p);
                expect.that(near(uv.x, ndc.x * 0.5 + 0.5)).is(true);
                expect.that(near(uv.y, ndc.y * 0.5 + 0.5)).is(true);
                // Clipped at the plane: what is behind it remains.
                const v = r.camera;
                expect.that(near(project(v, new Vector3(0.1, 0.2, 0)).z, 0, 1e-3)).is(true);
                expect.that(project(v, new Vector3(0.1, 0.2, 1)).z < 0).is(true);
                const behind = project(v, new Vector3(0.1, 0.2, -2)).z;
                expect.that(behind > 0 && behind < 1).is(true);
            });
            test("seen from behind, or by a refractor's camera", (expect) => {
                const r = new Refractor(new PlaneGeometry(2, 2));
                r.updateMatrixWorld();
                expect.that(r.updateMatrices(camera(0, 0, -5))).is(false);
                const c = camera(0, 0, 5);
                c.userData.set("refractor", Dynamic.fromBool(true));
                expect.that(r.updateMatrices(c)).is(false);
                expect.that(Dynamic.truthy(r.camera.userData.get("refractor"))).is(true);
            });
        });

        group("Water", () => {
            test("Water.js uniforms", (expect) => {
                const normals = new Texture();
                const w = new Water(new PlaneGeometry(100, 100), {
                    waterNormals: normals, sunColor: 0xffffff, waterColor: 0x001e0f, distortionScale: 3.7,
                    sunDirection: new Vector3(0, 1, 0), alpha: 0.9,
                });
                const m = w.shaderMaterial;
                expect.that(m.lights).is(true);
                expect.that(m.shader).is("three/shaders/objects/water");
                expect.that(near(m.uniform<f64>("distortionScale").value, 3.7)).is(true);
                expect.that(near(m.uniform<f64>("alpha").value, 0.9)).is(true);
                expect.that(near(m.uniform<Color>("waterColor").value.getHex(), 0x001e0f)).is(true);
                expect.that(m.uniform<Texture>("normalSampler").value === normals).is(true);
                expect.that(m.uniform<Texture>("mirrorSampler").value === w.getRenderTarget().texture).is(true);
                expect.that(<f64>w.getRenderTarget().type).is(<f64>HalfFloatType);
                // The repeating normal map owns the shader's sampler.
                expect.that(firstTexture(m)).is("normalSampler");
                // alpha time size distortionScale | textureMatrix | sunColor sunDirection eye waterColor
                const o = blockOffsets(m);
                expect.that(o.toString()).is("0,4,8,12,16,80,96,112,128");
            });
            test("Water2 uniforms and flow", (expect) => {
                const w = new Water2(new PlaneGeometry(10, 10), {
                    scale: 4, flowDirection: new Vector2(1, 1), reflectivity: 0.05, color: 0xccddff,
                });
                const m = w.shaderMaterial;
                expect.that(m.fragmentEntryPoint).is("fs_main");
                expect.that(m.transparent && m.fog).is(true);
                const config = m.uniform<Vector4>("config").value;
                expect.that(near(config.x, 0) && near(config.y, 0.075) && near(config.z, 0.075)).is(true);
                expect.that(near(config.w, 4)).is(true);
                expect.that(near(m.uniform<Vector2>("flowDirection").value.y, 1)).is(true);
                expect.that(firstTexture(m)).is("tNormalMap0");
                // color reflectivity | textureMatrix | config | flowDirection
                expect.that(blockOffsets(m).toString()).is("0,12,16,80,96");
                const flowMap = new Texture();
                const f = new Water2(new PlaneGeometry(10, 10), { flowMap: flowMap });
                expect.that(f.shaderMaterial.fragmentEntryPoint).is("fs_flowmap");
                expect.that(f.shaderMaterial.uniform<Texture>("tFlowMap").value === flowMap).is(true);
            });
        });

        group("Sky", () => {
            test("SkyShader uniforms", (expect) => {
                const sky = new Sky();
                expect.that(sky.isSky).is(true);
                const m = sky.shaderMaterial;
                expect.that(<f64>m.side).is(<f64>BackSide);
                expect.that(m.depthWrite).is(false);
                expect.that(near(m.uniform<f64>("turbidity").value, 2)).is(true);
                expect.that(near(m.uniform<f64>("rayleigh").value, 1)).is(true);
                expect.that(near(m.uniform<f64>("mieCoefficient").value, 0.005)).is(true);
                expect.that(near(m.uniform<f64>("mieDirectionalG").value, 0.8)).is(true);
                expect.that(near(m.uniform<Vector3>("up").value.y, 1)).is(true);
                // turbidity rayleigh mieCoefficient mieDirectionalG | sunPosition | up
                expect.that(blockOffsets(m).toString()).is("0,4,8,12,16,32");
                // Each Sky gets uniforms of its own (UniformsUtils.clone).
                const other = new Sky();
                other.shaderMaterial.uniform<f64>("turbidity").value = 10;
                expect.that(near(m.uniform<f64>("turbidity").value, 2)).is(true);
                // The sun from elevation and azimuth, as three.js's examples.
                const sun = m.uniform<Vector3>("sunPosition").value;
                sun.setFromSphericalCoords(1, (90 - 2) * Math.PI / 180, 180 * Math.PI / 180);
                expect.that(near(sun.y, Math.sin(2 * Math.PI / 180))).is(true);
                expect.that(sun.z < -0.99).is(true);
            });
        });

        group("Lensflare", () => {
            test("elements and set-up", (expect) => {
                const flare = new Lensflare();
                expect.that(flare.isLensflare).is(true);
                expect.that(flare.frustumCulled).is(false);
                expect.that(flare.renderOrder > 1000000).is(true);
                expect.that(flare.material.transparent).is(true);
                expect.that(near(flare.material.opacity, 0)).is(true);
                const t = new Texture();
                const e = new LensflareElement(t, 700, 0.6);
                expect.that(near(e.size, 700) && near(e.distance, 0.6)).is(true);
                expect.that(near(e.color.getHex(), 0xffffff)).is(true);
                flare.addElement(e);
                const g = Lensflare.Geometry;
                expect.that(<f64>g.getAttribute("position")!.count).is(4);
                expect.that(<f64>g.getAttribute("uv")!.count).is(4);
                expect.that(<f64>g.index!.count).is(6);
            });
        });
    }
}
