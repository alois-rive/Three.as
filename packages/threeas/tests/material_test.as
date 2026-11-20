// Material options reach the renderer's uniforms: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { MeshPhysicalMaterial } from "../three/materials/MeshPhysicalMaterial";
import { MeshLambertMaterial } from "../three/materials/MeshLambertMaterial";
import {
    MaterialUniforms, ROLE_TRANSMISSION, ROLE_THICKNESS, ROLE_LIGHT, ROLE_BUMP, ROLE_DISPLACEMENT, SLOT_ENV,
} from "../three/materials/MaterialUniforms";
import { Texture } from "../three/textures/Texture";
import { Event, EventListener } from "../three/core/EventDispatcher";
import { AddOperation, ObjectSpaceNormalMap } from "../three/constants";

class CountDisposes extends EventListener {
    count: i32 = 0;
    override handleEvent(event: Event): void { this.count++; }
}

export class MaterialTests extends Tests {
    override run(): void {
        group("Material.dispose", () => {
            test("dispatches dispose for the renderers to free their state", (expect) => {
                const m = new MeshLambertMaterial();
                const l = new CountDisposes();
                m.addEventListener("dispose", l);
                m.dispose();
                expect.that(l.count).is(1);
            });
        });
        group("MeshPhysicalMaterial", () => {
            test("transmission, volume, iridescence, anisotropy", (expect) => {
                const map = new Texture();
                const m = new MeshPhysicalMaterial({
                    transmission: 0.8, thickness: 1.5, attenuationColor: 0x00ff00, attenuationDistance: 2,
                    dispersion: 3, iridescence: 1, iridescenceIOR: 1.4, iridescenceThicknessRange: [150, 450],
                    anisotropy: 0.5, anisotropyRotation: 1, transmissionMap: map, thicknessMap: map,
                });
                const u = new MaterialUniforms();
                m.fillUniforms(u);
                expect.that(u.transmission).is(0.8);
                expect.that(u.thickness).is(1.5);
                expect.that(u.attenuationG).is(1);
                expect.that(u.attenuationR).is(0);
                expect.that(u.dispersion).is(3);
                expect.that(u.iridescenceThicknessMax).is(450);
                expect.that(u.anisotropyRotation).is(1);
                // Packed maps share one texture.
                expect.that(u.roles[ROLE_TRANSMISSION] === u.roles[ROLE_THICKNESS]).is(true);
            });
            test("reflectivity getter and setter round-trip with ior", (expect) => {
                const m = new MeshPhysicalMaterial();
                expect.that(Math.abs(m.ior - 1.5) < 1e-9).is(true);
                expect.that(Math.abs(m.reflectivity - 0.5) < 1e-9).is(true);
                // Idempotent self-assignment.
                const r0 = m.reflectivity;
                m.reflectivity = r0;
                expect.that(Math.abs(m.ior - 1.5) < 1e-9).is(true);
                expect.that(Math.abs(m.reflectivity - 0.5) < 1e-9).is(true);
                m.reflectivity = 0.8;
                expect.that(Math.abs(m.reflectivity - 0.8) < 1e-9).is(true);
            });
        });
        group("Material.copy and clone", () => {
            test("base Material copies all 17 stencil, polygonOffset, clipping, alphaHash and depthFunc fields", (expect) => {
                const p = new THREE.Plane(new THREE.Vector3(0, 1, 0), -2);
                const m = new THREE.MeshBasicMaterial({
                    polygonOffset: true, polygonOffsetFactor: 2, polygonOffsetUnits: 3,
                    depthFunc: THREE.GreaterDepth,
                    stencilWrite: true, stencilWriteMask: 0x0f, stencilFunc: THREE.EqualStencilFunc,
                    stencilRef: 7, stencilFuncMask: 0xf0, stencilFail: THREE.ZeroStencilOp,
                    stencilZFail: THREE.ReplaceStencilOp, stencilZPass: THREE.IncrementStencilOp,
                    clippingPlanes: [p], clipIntersection: true, clipShadows: true,
                    alphaHash: true, alphaToCoverage: true, shadowSide: THREE.DoubleSide,
                });
                const c = m.clone() as THREE.MeshBasicMaterial;
                expect.that(c.polygonOffset).is(true);
                expect.that(c.polygonOffsetFactor).is(2);
                expect.that(c.polygonOffsetUnits).is(3);
                expect.that(<f64>c.depthFunc).is(<f64>THREE.GreaterDepth);
                expect.that(c.stencilWrite).is(true);
                expect.that(<f64>c.stencilWriteMask).is(0x0f);
                expect.that(<f64>c.stencilFunc).is(<f64>THREE.EqualStencilFunc);
                expect.that(<f64>c.stencilRef).is(7);
                expect.that(<f64>c.stencilFuncMask).is(0xf0);
                expect.that(<f64>c.stencilFail).is(<f64>THREE.ZeroStencilOp);
                expect.that(<f64>c.stencilZFail).is(<f64>THREE.ReplaceStencilOp);
                expect.that(<f64>c.stencilZPass).is(<f64>THREE.IncrementStencilOp);
                expect.that(c.clippingPlanes != null && c.clippingPlanes!.length == 1).is(true);
                expect.that(c.clippingPlanes![0] !== p).is(true);
                expect.that(c.clippingPlanes![0].constant).is(-2);
                expect.that(c.clipIntersection).is(true);
                expect.that(c.clipShadows).is(true);
                expect.that(c.alphaHash).is(true);
                expect.that(c.alphaToCoverage).is(true);
                expect.that(<f64>c.shadowSide).is(<f64>THREE.DoubleSide);
            });
            test("every material subclass implements copy and clone cleanly", (expect) => {
                const tex = new Texture();
                const basic = new THREE.MeshBasicMaterial({ color: 0x112233, map: tex, reflectivity: 0.4 }).clone() as THREE.MeshBasicMaterial;
                expect.that(basic.isMeshBasicMaterial && basic.color.getHex() == 0x112233 && basic.map === tex && basic.reflectivity == 0.4).is(true);

                const lambert = new THREE.MeshLambertMaterial({ color: 0x223344, emissive: 0x101010, bumpScale: 2.5, map: tex }).clone() as THREE.MeshLambertMaterial;
                expect.that(lambert.isMeshLambertMaterial && lambert.color.getHex() == 0x223344 && lambert.emissive.getHex() == 0x101010 && lambert.bumpScale == 2.5).is(true);

                const phong = new THREE.MeshPhongMaterial({ color: 0x334455, specular: 0x667788, shininess: 90 }).clone() as THREE.MeshPhongMaterial;
                expect.that(phong.isMeshPhongMaterial && phong.specular.getHex() == 0x667788 && phong.shininess == 90).is(true);

                const std = new THREE.MeshStandardMaterial({ color: 0x445566, roughness: 0.3, metalness: 0.8, normalScale: new THREE.Vector2(2, 3) }).clone() as THREE.MeshStandardMaterial;
                expect.that(std.isMeshStandardMaterial && std.roughness == 0.3 && std.metalness == 0.8 && std.normalScale.x == 2 && std.normalScale.y == 3).is(true);

                const physSrc = new MeshPhysicalMaterial({
                    color: 0x556677, clearcoat: 0.7, sheen: 0.5, sheenColor: 0xff00ff, ior: 1.8,
                    transmission: 0.6, thickness: 1.2, dispersion: 2.0, iridescence: 0.9,
                    iridescenceThicknessRange: [200, 500], anisotropy: 0.4, anisotropyRotation: 0.7,
                });
                const phys = physSrc.clone() as MeshPhysicalMaterial;
                expect.that(phys.isMeshPhysicalMaterial && phys.clearcoat == 0.7 && phys.sheen == 0.5 && phys.sheenColor.getHex() == 0xff00ff).is(true);
                expect.that(phys.ior == 1.8 && phys.transmission == 0.6 && phys.dispersion == 2.0 && phys.anisotropy == 0.4).is(true);
                phys.iridescenceThicknessRange[0] = 999;
                expect.that(physSrc.iridescenceThicknessRange[0]).is(200);

                const toon = new THREE.MeshToonMaterial({ color: 0x667788, gradientMap: tex }).clone() as THREE.MeshToonMaterial;
                expect.that(toon.isMeshToonMaterial && toon.gradientMap === tex).is(true);

                const matcap = new THREE.MeshMatcapMaterial({ color: 0x778899, matcap: tex }).clone() as THREE.MeshMatcapMaterial;
                expect.that(matcap.isMeshMatcapMaterial && matcap.matcap === tex).is(true);

                const normal = new THREE.MeshNormalMaterial({ side: THREE.DoubleSide, bumpScale: 4 }).clone() as THREE.MeshNormalMaterial;
                expect.that(normal.isMeshNormalMaterial && normal.fog == false && normal.bumpScale == 4).is(true);

                const depth = new THREE.MeshDepthMaterial({ side: THREE.DoubleSide, displacementScale: 0.5 }).clone() as THREE.MeshDepthMaterial;
                expect.that(depth.isMeshDepthMaterial && depth.fog == false && depth.displacementScale == 0.5).is(true);

                const dist = new THREE.MeshDistanceMaterial({
                    side: THREE.DoubleSide, referencePosition: new THREE.Vector3(1, 2, 3), nearDistance: 0.5, farDistance: 50,
                }).clone() as THREE.MeshDistanceMaterial;
                expect.that(dist.isMeshDistanceMaterial && dist.fog == false && dist.referencePosition.y == 2 && dist.farDistance == 50).is(true);

                const shadow = new THREE.ShadowMaterial({ color: 0x123456 }).clone() as THREE.ShadowMaterial;
                expect.that(shadow.isShadowMaterial && shadow.transparent == true && shadow.color.getHex() == 0x123456).is(true);

                const shaderSrc = new THREE.ShaderMaterial({ shader: "foo/bar", lights: true });
                shaderSrc.uniforms.set("u", new THREE.Uniform<THREE.Vector3>(new THREE.Vector3(1, 2, 3)));
                const shader = shaderSrc.clone() as THREE.ShaderMaterial;
                expect.that(shader.isShaderMaterial && shader.shader == "foo/bar" && shader.lights == true).is(true);
                shader.uniform<THREE.Vector3>("u").value.x = 99;
                expect.that(shaderSrc.uniform<THREE.Vector3>("u").value.x).is(1);

                const raw = new THREE.RawShaderMaterial({ shader: "raw/s" }).clone() as THREE.RawShaderMaterial;
                expect.that(raw.isRawShaderMaterial && raw.type == "RawShaderMaterial" && raw.shader == "raw/s").is(true);

                const line = new THREE.LineBasicMaterial({ color: 0xaabbcc, linewidth: 3 }).clone() as THREE.LineBasicMaterial;
                expect.that(line.isLineBasicMaterial && line.color.getHex() == 0xaabbcc && line.linewidth == 3).is(true);

                const dashed = new THREE.LineDashedMaterial({ color: 0xbbccdd, dashSize: 5, gapSize: 2, scale: 1.5 }).clone() as THREE.LineDashedMaterial;
                expect.that(dashed.isLineDashedMaterial && dashed.dashSize == 5 && dashed.gapSize == 2 && dashed.scale == 1.5).is(true);

                const pts = new THREE.PointsMaterial({ color: 0xccddee, size: 7, sizeAttenuation: false }).clone() as THREE.PointsMaterial;
                expect.that(pts.isPointsMaterial && pts.size == 7 && pts.sizeAttenuation == false).is(true);

                const spr = new THREE.SpriteMaterial({ color: 0xddeeff, rotation: 0.6, sizeAttenuation: false }).clone() as THREE.SpriteMaterial;
                expect.that(spr.isSpriteMaterial && spr.transparent == true && spr.rotation == 0.6 && spr.sizeAttenuation == false).is(true);
            });
        });
        group("MeshLambertMaterial", () => {
            test("light, bump, displacement and env options", (expect) => {
                const t = new Texture();
                const m = new MeshLambertMaterial({
                    lightMap: t, lightMapIntensity: 2, bumpMap: t, bumpScale: 3, displacementMap: t,
                    displacementScale: 0.5, envMap: t, combine: AddOperation, reflectivity: 0.25,
                    normalMapType: ObjectSpaceNormalMap,
                });
                const u = new MaterialUniforms();
                m.fillUniforms(u);
                expect.that(u.roles[ROLE_LIGHT] === t && u.roles[ROLE_BUMP] === t && u.roles[ROLE_DISPLACEMENT] === t).is(true);
                expect.that(u.textures[SLOT_ENV] === t).is(true);
                expect.that(u.lightMapIntensity).is(2);
                expect.that(u.bumpScale).is(3);
                expect.that(u.displacementScale).is(0.5);
                expect.that(<f64>u.combine).is(<f64>AddOperation);
                expect.that(u.reflectivity).is(0.25);
                expect.that(<f64>u.normalMapType).is(<f64>ObjectSpaceNormalMap);
            });
        });
    }
}
