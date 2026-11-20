// Material options reach the renderer's uniforms: rive . --test

import { Tests } from "rive/test";
import { MeshPhysicalMaterial } from "../three/materials/MeshPhysicalMaterial";
import { MeshLambertMaterial } from "../three/materials/MeshLambertMaterial";
import {
    MaterialUniforms, ROLE_TRANSMISSION, ROLE_THICKNESS, ROLE_LIGHT, ROLE_BUMP, ROLE_DISPLACEMENT, SLOT_ENV,
} from "../three/materials/MaterialUniforms";
import { Texture } from "../three/textures/Texture";
import { disposedMaterials } from "../three/materials/Material";
import { AddOperation, ObjectSpaceNormalMap } from "../three/constants";

export class MaterialTests extends Tests {
    override run(): void {
        group("Material.dispose", () => {
            test("queues the material for the renderer to free", (expect) => {
                const m = new MeshLambertMaterial();
                const before = disposedMaterials.length;
                m.dispose();
                expect.that(disposedMaterials.length).is(before + 1);
                expect.that(disposedMaterials[disposedMaterials.length - 1]).is(m.id);
                disposedMaterials.pop();
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
