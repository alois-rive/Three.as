// SceneBindings (view model <-> scene): rive . --test

import { Expect, Tests } from "rive/test";
import { ViewModel } from "rive/data";
import { Object3D } from "../three/core/Object3D";
import { Mesh } from "../three/objects/Mesh";
import { PointLight } from "../three/lights/PointLight";
import { MeshStandardMaterial } from "../three/materials/MeshStandardMaterial";
import { AnimationClip } from "../three/animation/AnimationClip";
import { AnimationMixer } from "../three/animation/AnimationMixer";
import { NumberKeyframeTrack } from "../three/animation/KeyframeTrack";
import {
    SceneBindings, ActionTarget, PathTarget, BindToScene, BindToViewModel, BindBoth,
} from "../three/rive/SceneBindings";

const EPS: f64 = 1e-4;

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(EPS);
}

@editTime
function scene(): Object3D {
    const root = new Object3D();
    const lamp = new PointLight(0xffffff, 2);
    lamp.name = "Lamp";
    root.add(lamp);
    const crate = new Mesh();
    crate.name = "Crate";
    crate.material = new MeshStandardMaterial({ color: 0x336699 });
    root.add(crate);
    return root;
}

export class BindingsTests extends Tests {
    override run(): void {
        group("SceneBindings", () => {
            test("parses a spec", (expect) => {
                const b = new SceneBindings(scene());
                const made = b.parse("lamp -> Lamp.intensity * 0.5 + 1; height <- Crate.position[y]\n"
                    + "tint <-> Crate.material.color\n# a comment\nbad line\nmissing -> Nope.position[x]");
                expect.that(made).is(3);
                expect.that(b.bindings.length).is(3);
                expect.that(b.bindings[0].direction).is(BindToScene);
                near(expect, b.bindings[0].scale, 0.5);
                near(expect, b.bindings[0].offset, 1);
                expect.that(b.bindings[1].direction).is(BindToViewModel);
                expect.that(b.bindings[2].direction).is(BindBoth);
                expect.that(b.errors.length).is(2);
            });
            test("action targets", (expect) => {
                const root = scene();
                const mixer = new AnimationMixer(root);
                const clip = new AnimationClip("rise", -1, [new NumberKeyframeTrack("Crate.position[y]", [0, 1], [0, 1])]);
                const action = mixer.clipAction(clip);
                const b = new SceneBindings(root);
                b.addAction("rise", action);
                expect.that(b.bind("w", "@rise.weight") != null).is(true);
                expect.that(b.bind("w", "@rise.nope") == null).is(true);
                expect.that(b.bind("w", "@other.weight") == null).is(true);
                const t = new ActionTarget(action, "weight");
                const v = new Float64Array(4);
                v[0] = 0.25;
                t.setValue(v);
                near(expect, action.weight, 0.25);
                const run = new ActionTarget(action, "running");
                expect.that(run.isBoolean).is(true);
                v[0] = 1;
                run.setValue(v);
                expect.that(action.isScheduled()).is(true);
                const play = new ActionTarget(action, "play");
                action.stop();
                play.fire();
                expect.that(action.isScheduled()).is(true);
            });
            test("path targets", (expect) => {
                const root = scene();
                const t = new PathTarget(root, "Crate.material.color");
                expect.that(t.isColor).is(true);
                const vis = new PathTarget(root, "Lamp.visible");
                expect.that(vis.isBoolean).is(true);
                vis.fire();
                expect.that(root.getObjectByName("Lamp")!.visible).is(false);
            });
            test("syncs with a view model both ways", (expect) => {
                // Test runs have no Rive file: this runs where the view model exists.
                if (!ViewModel.exists("RiveDrivenScene")) return;
                const vm = ViewModel.create("RiveDrivenScene");
                const root = scene();
                const b = new SceneBindings(root, vm);
                b.bind("daylight", "Lamp.intensity", BindToScene, 0.5);
                b.bind("height", "Crate.position[y]", BindToViewModel);
                b.bind("tint", "Crate.material.color", BindBoth);
                b.bind("night", "Lamp.visible", BindToScene);
                expect.that(b.errors.length).is(0);
                vm.getNumber("daylight")!.value = 10;
                vm.getBoolean("night")!.value = false;
                b.update();
                const lamp = root.getObjectByName("Lamp") as PointLight;
                near(expect, lamp.intensity, 5);
                expect.that(lamp.visible).is(false);
                root.getObjectByName("Crate")!.position.y = 1.5;
                b.update();
                near(expect, vm.getNumber("height")!.value, 1.5);
                // The scene's colour reached the view model on the first
                // update (the view model wins first: both ways).
                const material = (root.getObjectByName("Crate") as Mesh).material as MeshStandardMaterial;
                material.color.setHex(0xff0000);
                b.update();
                expect.that(<f64>(vm.getColor("tint")!.value & 0xffffff)).is(<f64>0xff0000);
                vm.getColor("tint")!.value = 0xff00ff00;
                b.update();
                near(expect, material.color.g, 1);
                near(expect, material.color.r, 0);
            });
        });
    }
}
