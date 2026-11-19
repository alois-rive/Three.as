// Keyframe tracks, clips and the mixer: rive . --test

import { Expect, Tests } from "rive/test";
import { Object3D } from "../three/core/Object3D";
import { Mesh } from "../three/objects/Mesh";
import { MeshStandardMaterial } from "../three/materials/MeshStandardMaterial";
import { Quaternion } from "../three/math/Quaternion";
import { Vector3 } from "../three/math/Vector3";
import {
    KeyframeTrack, NumberKeyframeTrack, VectorKeyframeTrack, QuaternionKeyframeTrack, ColorKeyframeTrack,
    BooleanKeyframeTrack, InterpolateGLTFCubicSpline,
} from "../three/animation/KeyframeTrack";
import { AnimationClip } from "../three/animation/AnimationClip";
import { AnimationMixer } from "../three/animation/AnimationMixer";
import { PropertyBinding } from "../three/animation/PropertyBinding";
import { AnimationObjectGroup } from "../three/animation/AnimationObjectGroup";
import { AnimationUtils } from "../three/animation/AnimationUtils";
import { PointLight } from "../three/lights/PointLight";
import { Float32BufferAttribute } from "../three/core/BufferAttribute";
import {
    InterpolateDiscrete, InterpolateSmooth, LoopOnce, LoopPingPong, AdditiveAnimationBlendMode,
} from "../three/constants";

const EPS: f64 = 1e-4;

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(EPS);
}

@editTime
function at(track: KeyframeTrack, t: f64): Float64Array {
    const out = new Float64Array(4);
    track.evaluate(t, out);
    return out;
}

@editTime
function moving(): Object3D {
    const root = new Object3D();
    const box = new Object3D();
    box.name = "Box";
    root.add(box);
    return root;
}

export class AnimationTests extends Tests {
    override run(): void {
        group("KeyframeTrack", () => {
            test("linear, clamped at the ends", (expect) => {
                const t = new NumberKeyframeTrack(".x", [0, 1, 3], [0, 10, 30]);
                near(expect, at(t, 0.5)[0], 5);
                near(expect, at(t, 2)[0], 20);
                near(expect, at(t, -1)[0], 0);
                near(expect, at(t, 9)[0], 30);
                expect.that(<f64>t.getValueSize()).is(1);
            });
            test("discrete holds", (expect) => {
                const t = new NumberKeyframeTrack(".x", [0, 1], [3, 7], InterpolateDiscrete);
                near(expect, at(t, 0.99)[0], 3);
                near(expect, at(t, 1)[0], 7);
            });
            test("smooth passes through its keys", (expect) => {
                const t = new NumberKeyframeTrack(".x", [0, 1, 2], [0, 1, 0], InterpolateSmooth);
                near(expect, at(t, 1)[0], 1);
                expect.that(at(t, 0.5)[0]).greaterThan(0.4);
            });
            test("glTF cubic spline with zero tangents is smoothstep", (expect) => {
                // Per key: in-tangent, value, out-tangent.
                const t = new NumberKeyframeTrack(".x", [0, 1], [0, 0, 0, 0, 1, 0], InterpolateGLTFCubicSpline);
                expect.that(<f64>t.getValueSize()).is(1);
                near(expect, at(t, 0.5)[0], 0.5);
                near(expect, at(t, 0.25)[0], 0.15625);
            });
            test("quaternions slerp", (expect) => {
                const a = new Quaternion();
                const b = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), Math.PI / 2);
                const t = new QuaternionKeyframeTrack(".quaternion", [0, 1], [a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w]);
                const q = at(t, 0.5);
                near(expect, q[1], Math.sin(Math.PI / 8));
                near(expect, q[3], Math.cos(Math.PI / 8));
            });
        });

        group("PropertyBinding", () => {
            test("parses track names", (expect) => {
                const p = PropertyBinding.parseTrackName("Face.morphTargetInfluences[smile]");
                expect.that(p.nodeName).is("Face");
                expect.that(p.propertyName).is("morphTargetInfluences");
                expect.that(p.propertyIndex).is("smile");
                const m = PropertyBinding.parseTrackName("Cube.material.opacity");
                expect.that(m.objectName).is("material");
                expect.that(m.propertyName).is("opacity");
                expect.that(PropertyBinding.sanitizeNodeName("my node.1")).is("my_node1");
            });
            test("binds morph targets by name and material colours", (expect) => {
                const mesh = new Mesh();
                mesh.name = "Face";
                mesh.morphTargetDictionary.set("smile", 1);
                mesh.morphTargetInfluences = [0, 0];
                mesh.material = new MeshStandardMaterial();
                const b = new PropertyBinding(mesh, "Face.morphTargetInfluences[smile]");
                const v = new Float64Array(3);
                v[0] = 0.75;
                b.setValue(v);
                near(expect, mesh.morphTargetInfluences[1], 0.75);
                const c = new PropertyBinding(mesh, ".material.color");
                v[0] = 0.1; v[1] = 0.2; v[2] = 0.3;
                c.setValue(v);
                near(expect, (mesh.material as MeshStandardMaterial).color.g, 0.2);
            });
        });

        group("AnimationMixer", () => {
            test("plays a clip on a named node", (expect) => {
                const root = moving();
                const clip = new AnimationClip("move", -1, [new VectorKeyframeTrack("Box.position", [0, 2], [0, 0, 0, 4, 0, 0])]);
                near(expect, clip.duration, 2);
                const mixer = new AnimationMixer(root);
                mixer.clipAction(clip).play();
                mixer.update(0.5);
                near(expect, root.getObjectByName("Box")!.position.x, 1);
                mixer.update(2);   // loops: 2.5 -> 0.5
                near(expect, root.getObjectByName("Box")!.position.x, 1);
            });
            test("LoopOnce clamps when finished", (expect) => {
                const root = moving();
                const clip = new AnimationClip("move", -1, [new NumberKeyframeTrack("Box.visible", [0], [1]),
                    new VectorKeyframeTrack("Box.position", [0, 1], [0, 0, 0, 2, 0, 0])]);
                const mixer = new AnimationMixer(root);
                const action = mixer.clipAction(clip).setLoop(LoopOnce);
                action.clampWhenFinished = true;
                action.play();
                mixer.update(5);
                near(expect, root.getObjectByName("Box")!.position.x, 2);
                expect.that(action.paused).is(true);
                expect.that(action.isRunning()).is(false);
            });
            test("ping-pong runs back", (expect) => {
                const root = moving();
                const clip = new AnimationClip("move", -1, [new VectorKeyframeTrack("Box.position", [0, 1], [0, 0, 0, 1, 0, 0])]);
                const mixer = new AnimationMixer(root);
                mixer.clipAction(clip).setLoop(LoopPingPong).play();
                mixer.update(1.25);
                near(expect, root.getObjectByName("Box")!.position.x, 0.75);
            });
            test("blends actions by weight, and towards the original below 1", (expect) => {
                const root = moving();
                const box = root.getObjectByName("Box")!;
                const a = new AnimationClip("a", 1, [new VectorKeyframeTrack("Box.position", [0], [2, 0, 0])]);
                const b = new AnimationClip("b", 1, [new VectorKeyframeTrack("Box.position", [0], [4, 0, 0])]);
                const mixer = new AnimationMixer(root);
                mixer.clipAction(a).play();
                mixer.clipAction(b).setEffectiveWeight(1).play();
                mixer.update(0.1);
                near(expect, box.position.x, 3);
                mixer.clipAction(b).stop();
                mixer.clipAction(a).setEffectiveWeight(0.5);
                mixer.update(0.1);
                near(expect, box.position.x, 1);   // half way from the original 0
            });
            test("cross-fades", (expect) => {
                const root = moving();
                const box = root.getObjectByName("Box")!;
                const a = new AnimationClip("a", 1, [new VectorKeyframeTrack("Box.position", [0], [0, 0, 0])]);
                const b = new AnimationClip("b", 1, [new VectorKeyframeTrack("Box.position", [0], [10, 0, 0])]);
                const mixer = new AnimationMixer(root);
                const actionA = mixer.clipAction(a).play();
                const actionB = mixer.clipAction(b).play();
                actionA.crossFadeTo(actionB, 1);
                mixer.update(0.5);
                near(expect, box.position.x, 5);
                mixer.update(0.6);
                near(expect, box.position.x, 10);
                expect.that(actionA.enabled).is(false);
            });
            test("colour and boolean tracks", (expect) => {
                const mesh = new Mesh();
                mesh.material = new MeshStandardMaterial();
                mesh.name = "M";
                const clip = new AnimationClip("c", -1, [
                    new ColorKeyframeTrack("M.material.color", [0, 1], [0, 0, 0, 1, 1, 1]),
                    new BooleanKeyframeTrack("M.visible", [0, 0.5], [1, 0]),
                ]);
                const mixer = new AnimationMixer(mesh);
                mixer.clipAction(clip).play();
                mixer.update(0.25);
                near(expect, (mesh.material as MeshStandardMaterial).color.r, 0.25);
                expect.that(mesh.visible).is(true);
                mixer.update(0.5);
                expect.that(mesh.visible).is(false);
            });
        });

        group("AnimationUtils", () => {
            test("subclip keeps a frame range, shifted to 0", (expect) => {
                const clip = new AnimationClip("walk", -1, [
                    new NumberKeyframeTrack("Box.position[x]", [0, 1, 2, 3], [0, 10, 20, 30]),
                    new NumberKeyframeTrack("Box.position[y]", [0, 3], [0, 3]),
                ]);
                const sub = AnimationUtils.subclip(clip, "mid", 30, 90, 30);   // frames 30-89: times 1, 2
                expect.that(sub.name).is("mid");
                expect.that(sub.tracks.length).is(1);
                expect.that(sub.tracks[0].times.length).is(2);
                near(expect, sub.tracks[0].times[0], 0);
                near(expect, sub.tracks[0].values[1], 20);
                near(expect, sub.duration, 1);
                expect.that(clip.tracks[0].times.length).is(4);   // the source is untouched
            });
            test("makeClipAdditive subtracts the reference frame", (expect) => {
                const q = new Quaternion().setFromAxisAngle(new Vector3(0, 0, 1), 0.5);
                const clip = new AnimationClip("lean", -1, [
                    new VectorKeyframeTrack("Box.position", [0, 1], [1, 2, 3, 2, 2, 3]),
                    new QuaternionKeyframeTrack("Box.quaternion", [0, 1], [q.x, q.y, q.z, q.w, 0, 0, 0, 1]),
                ]);
                AnimationUtils.makeClipAdditive(clip);
                expect.that(<f64>clip.blendMode).is(<f64>AdditiveAnimationBlendMode);
                near(expect, clip.tracks[0].values[0], 0);
                near(expect, clip.tracks[0].values[3], 1);
                near(expect, clip.tracks[1].values[3], 1);   // the first key becomes the identity
                near(expect, clip.tracks[1].values[2], 0);
            });
            test("key order and sorting", (expect) => {
                const order = AnimationUtils.getKeyframeOrder([2, 0, 1]);
                expect.that(order[0]).is(1);
                expect.that(order[2]).is(0);
                const sorted = AnimationUtils.sortedArray([20, 21, 0, 1, 10, 11], 2, order);
                near(expect, sorted[0], 0);
                near(expect, sorted[5], 21);
            });
            test("clone, trim, optimize, validate", (expect) => {
                const track = new NumberKeyframeTrack(".x", [0, 1, 2, 3, 4], [0, 1, 1, 1, 2]);
                const copy = track.clone();
                expect.that(copy instanceof NumberKeyframeTrack).is(true);
                copy.optimize();
                expect.that(copy.times.length).is(4);   // the middle 1 goes
                expect.that(track.times.length).is(5);
                track.trim(1, 3);
                expect.that(track.times.length).is(3);
                expect.that(track.validate()).is(true);
                const bad = new NumberKeyframeTrack(".x", [1, 0], [0, 0]);
                expect.that(bad.validate()).is(false);
            });
            test("morph target sequences", (expect) => {
                const a = new Float32BufferAttribute([0, 0, 0], 3); a.name = "run0";
                const b = new Float32BufferAttribute([0, 0, 0], 3); b.name = "run1";
                const c = new Float32BufferAttribute([0, 0, 0], 3); c.name = "jump0";
                const clips = AnimationClip.CreateClipsFromMorphTargetSequences([a, b, c], 10);
                expect.that(clips.length).is(2);
                expect.that(clips[0].name).is("run");
                expect.that(clips[0].tracks.length).is(2);
                expect.that(clips[0].tracks[0].name).is(".morphTargetInfluences[run0]");
                near(expect, clips[0].duration, 0.2);
            });
        });

        group("additive blending", () => {
            test("an additive action adds on top of the normal blend", (expect) => {
                const root = moving();
                const box = root.getObjectByName("Box")!;
                const base = new AnimationClip("base", 1, [new VectorKeyframeTrack("Box.position", [0], [2, 0, 0])]);
                const offset = new AnimationClip("offset", 1, [new VectorKeyframeTrack("Box.position", [0, 1], [0, 0, 0, 0, 4, 0])]);
                AnimationUtils.makeClipAdditive(offset);
                const mixer = new AnimationMixer(root);
                mixer.clipAction(base).play();
                const add = mixer.clipAction(offset).play();
                expect.that(<f64>add.blendMode).is(<f64>AdditiveAnimationBlendMode);
                mixer.update(0.5);
                near(expect, box.position.x, 2);
                near(expect, box.position.y, 2);
                add.setEffectiveWeight(0.5);
                mixer.update(0);
                near(expect, box.position.y, 1);
            });
            test("additive quaternions multiply", (expect) => {
                const root = moving();
                const box = root.getObjectByName("Box")!;
                const turn = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), 0.6);
                const clip = new AnimationClip("turn", 1, [new QuaternionKeyframeTrack("Box.quaternion", [0],
                    [turn.x, turn.y, turn.z, turn.w])]);
                box.quaternion.setFromAxisAngle(new Vector3(0, 1, 0), 0.4);
                const mixer = new AnimationMixer(root);
                mixer.clipAction(clip, null, AdditiveAnimationBlendMode).play();
                mixer.update(0.1);
                const want = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), 1.0);
                near(expect, box.quaternion.y, want.y);
                near(expect, box.quaternion.w, want.w);
            });
        });

        group("AnimationObjectGroup", () => {
            test("one action drives every object", (expect) => {
                const a = new Object3D(), b = new Object3D(), c = new Object3D();
                const group = new AnimationObjectGroup([a, b]);
                group.add(c);
                const clip = new AnimationClip("rise", -1, [new NumberKeyframeTrack(".position[y]", [0, 1], [0, 2])]);
                const mixer = new AnimationMixer(group);
                mixer.clipAction(clip).play();
                mixer.update(0.5);
                near(expect, a.position.y, 1);
                near(expect, c.position.y, 1);
                expect.that(a.parent == null).is(true);   // not parented
                group.remove(b);
                mixer.update(0.25);
                near(expect, a.position.y, 1.5);
                near(expect, b.position.y, 1);
                expect.that(group.stats.objects.total).is(3);
                expect.that(group.stats.objects.inUse).is(2);
                expect.that(group.stats.bindingsPerObject).is(1);
            });
        });

        group("PropertyBinding paths", () => {
            test("components, lights and material numbers", (expect) => {
                const root = new Object3D();
                const lamp = new PointLight(0xffffff, 2);
                lamp.name = "Lamp";
                root.add(lamp);
                const mesh = new Mesh();
                mesh.name = "M";
                mesh.material = new MeshStandardMaterial({ roughness: 0.3 });
                root.add(mesh);
                const v = new Float64Array(4);
                const i = new PropertyBinding(root, "Lamp.intensity");
                expect.that(i.valueSize).is(1);
                i.getValue(v);
                near(expect, v[0], 2);
                v[0] = 5; i.setValue(v);
                near(expect, lamp.intensity, 5);
                const x = new PropertyBinding(root, "M.position[x]");
                v[0] = 3; x.setValue(v);
                near(expect, mesh.position.x, 3);
                const r = new PropertyBinding(root, "M.material.roughness");
                r.getValue(v);
                near(expect, v[0], 0.3);
                const lc = new PropertyBinding(root, "Lamp.color");
                expect.that(lc.valueSize).is(3);
                expect.that(lc.isColor).is(true);
                const bad = new PropertyBinding(root, "M.position[q]");
                expect.that(bad.isBound).is(false);
            });
        });
    }
}
