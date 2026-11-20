// What long-running scenes drop must not stay alive or hold resources:
// mixer bindings, audio voices and analyser slots, view model listeners,
// helpers' materials and geometries, BVH trees. rive . --test

import { Tests } from "rive/test";
import { ViewModel } from "rive/data";
import { Object3D } from "../three/core/Object3D";
import { BufferGeometry, disposedGeometries } from "../three/core/BufferGeometry";
import { disposedMaterials } from "../three/materials/Material";
import { disposedTextures } from "../three/textures/Texture";
import { AnimationClip } from "../three/animation/AnimationClip";
import { AnimationMixer } from "../three/animation/AnimationMixer";
import { KeyframeTrack, VectorKeyframeTrack } from "../three/animation/KeyframeTrack";
import { AudioListener } from "../three/audio/AudioListener";
import { Audio } from "../three/audio/Audio";
import { AudioAnalyser } from "../three/audio/AudioAnalyser";
import { AudioBuffer } from "../three/audio/AudioNodes";
import { MIX_MAX_VOICES, MIX_MAX_ANALYSERS } from "../three/audio/AudioMixer";
import { PointLight } from "../three/lights/PointLight";
import { DirectionalLight } from "../three/lights/DirectionalLight";
import { DirectionalLightHelper } from "../three/helpers/LightHelpers";
import { PlaneHelper } from "../three/helpers/PlaneHelper";
import { Plane } from "../three/math/Plane";
import { Vector3 } from "../three/math/Vector3";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { TransformControls } from "../three/addons/controls/TransformControls";
import { RoomEnvironment } from "../three/addons/environments/RoomEnvironment";
import { Water as Water2 } from "../three/addons/objects/Water2";
import { PlaneGeometry } from "../three/geometries/PlaneGeometry";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { GeometryBVH } from "../three/rive/GeometryBVH";
import { SceneBindings, BindToScene } from "../three/rive/SceneBindings";
import { LUTPass } from "../three/addons/postprocessing/LUTPass";
import { Data3DTexture } from "../three/textures/DataArrayTexture";

function clip(name: string, paths: Array<string>): AnimationClip {
    const tracks: Array<KeyframeTrack> = [];
    for (let i = 0; i < paths.length; i++) tracks.push(new VectorKeyframeTrack(paths[i], [0, 1], [0, 0, 0, 1, 2, 3]));
    return new AnimationClip(name, 1, tracks);
}

function rig(): Object3D {
    const root = new Object3D();
    const a = new Object3D();
    a.name = "a";
    root.add(a);
    const b = new Object3D();
    b.name = "b";
    root.add(b);
    return root;
}

function silentBuffer(): AudioBuffer {
    return AudioBuffer.fromChannelData([new Float32Array(64)], 48000);
}

export class LeakTests extends Tests {
    override run(): void {
        group("AnimationMixer bindings", () => {
            test("are shared and counted, and go with the last action using them", (expect) => {
                const root = rig();
                const mixer = new AnimationMixer(root);
                const walk = clip("walk", ["a.position", "a.scale"]);
                const run = clip("run", ["a.position", "b.position"]);
                const walkAction = mixer.clipAction(walk);
                const runAction = mixer.clipAction(run);
                expect.that(mixer.stats.actions.total).is(2);
                expect.that(mixer.stats.bindings.total).is(3);   // a.position is shared
                expect.that(mixer.stats.bindings.inUse).is(0);
                walkAction.play();
                expect.that(mixer.stats.bindings.inUse).is(2);
                runAction.play();
                expect.that(mixer.stats.bindings.inUse).is(3);
                mixer.update(0.5);
                expect.that(root.getObjectByName("b")!.position.y).is(1);
                walkAction.stop();
                expect.that(mixer.stats.bindings.inUse).is(2);   // a.position still runs
                mixer.uncacheAction(walk);
                expect.that(mixer.stats.actions.total).is(1);
                expect.that(mixer.stats.bindings.total).is(2);   // a.scale went
                mixer.uncacheClip(run);
                expect.that(mixer.stats.actions.total).is(0);
                expect.that(mixer.stats.bindings.total).is(0);
                expect.that(mixer.stats.bindings.inUse).is(0);
                mixer.update(0.5);
                // A clip action made again binds again.
                mixer.clipAction(walk).play();
                expect.that(mixer.stats.bindings.total).is(2);
                expect.that(mixer.stats.bindings.inUse).is(2);
            });
            test("uncacheRoot forgets a root's actions and bindings", (expect) => {
                const root = rig();
                const other = rig();
                const mixer = new AnimationMixer(root);
                const walk = clip("walk", ["a.position"]);
                const a = other.getObjectByName("a")!;
                a.position.set(5, 5, 5);
                mixer.clipAction(walk).play();
                mixer.clipAction(walk, other).play();
                expect.that(mixer.stats.actions.total).is(2);
                expect.that(mixer.stats.bindings.total).is(2);
                mixer.update(0.5);
                expect.that(a.position.x).is(0.5);
                mixer.uncacheRoot(other);
                expect.that(mixer.stats.actions.total).is(1);
                expect.that(mixer.stats.actions.inUse).is(1);
                expect.that(mixer.stats.bindings.total).is(1);
                // three.js writes the original values back.
                expect.that(a.position.x).is(5);
                mixer.update(0.5);
                expect.that(a.position.x).is(5);
            });
        });

        group("Audio voices and analysers", () => {
            test("the listener keeps no list of its Audio objects", (expect) => {
                const listener = new AudioListener();
                for (let i = 0; i < 3 * MIX_MAX_VOICES; i++) {
                    const audio = new Audio(listener);
                    audio.setBuffer(silentBuffer());
                    audio.play();
                    listener.update();
                    audio.stop();
                    listener.update();
                    expect.that(audio.voice).is(-1);
                }
                let used = 0;
                for (let v = 0; v < MIX_MAX_VOICES; v++) if (listener.context.voices[v] != null) used++;
                expect.that(used).is(0);
            });
            test("an oscillator gives its voice back when stopped, and takes one to play again", (expect) => {
                const listener = new AudioListener();
                const audio = new Audio(listener);
                const osc = listener.context.createOscillator();
                audio.setNodeSource(osc);
                osc.start();
                listener.update();
                expect.that(audio.voice >= 0).is(true);
                expect.that(audio.isPlaying).is(true);
                osc.stop();
                listener.update();
                expect.that(audio.voice).is(-1);
                osc.start();
                listener.update();
                expect.that(audio.voice >= 0).is(true);
                audio.disconnect();
                listener.update();
                expect.that(audio.voice).is(-1);
                audio.connect();
                listener.update();
                expect.that(audio.voice >= 0).is(true);
                audio.dispose();
                listener.update();
                expect.that(audio.voice).is(-1);
            });
            test("dispose frees a paused Audio's voice and its analyser slot", (expect) => {
                const listener = new AudioListener();
                const audio = new Audio(listener);
                audio.setBuffer(silentBuffer());
                const analyser = new AudioAnalyser(audio, 256);
                expect.that(analyser.analyser.slot).is(0);
                audio.play();
                listener.update();
                audio.pause();
                listener.update();
                expect.that(audio.voice >= 0).is(true);   // paused: it keeps its place
                audio.dispose();
                expect.that(analyser.analyser.slot).is(-1);
                expect.that(audio.analyser == null).is(true);
                listener.update();
                expect.that(audio.voice).is(-1);
                expect.that(listener.context.analysers[0] == null).is(true);
            });
            test("analyser slots come back: dispose, or reclaimed from idle Audio", (expect) => {
                const listener = new AudioListener();
                const analysers: Array<AudioAnalyser> = [];
                for (let i = 0; i < MIX_MAX_ANALYSERS; i++) {
                    const audio = new Audio(listener);
                    analysers.push(new AudioAnalyser(audio, 64));
                }
                analysers[1].dispose();
                expect.that(analysers[1].analyser.slot).is(-1);
                const audio = new Audio(listener);
                const one = new AudioAnalyser(audio, 64);
                expect.that(one.analyser.slot).is(1);
                // All taken, none listening to a playing Audio: idle ones go.
                const late = new AudioAnalyser(new Audio(listener), 64);
                expect.that(late.analyser.slot >= 0).is(true);
                // A playing Audio's analyser takes a slot back when mixed.
                audio.setBuffer(silentBuffer());
                audio.play();
                listener.update();
                expect.that(one.analyser.slot >= 0).is(true);
            });
        });

        group("SceneBindings.dispose", () => {
            test("detaches every binding", (expect) => {
                const root = new Object3D();
                const lamp = new PointLight(0xffffff, 1);
                lamp.name = "Lamp";
                root.add(lamp);
                const b = new SceneBindings(root);
                b.bind("night", "Lamp.visible", BindToScene);
                b.bind("x", "Lamp.position[x]", BindToScene);
                expect.that(b.bindings.length).is(2);
                b.dispose();
                expect.that(b.bindings.length).is(0);
                expect.that(b.viewModel == null).is(true);
            });
            test("removes trigger listeners from the view model", (expect) => {
                // Test runs have no Rive file: this runs where the view model exists.
                if (!ViewModel.exists("RiveDrivenScene")) return;
                const vm = ViewModel.create("RiveDrivenScene");
                const root = new Object3D();
                const lamp = new PointLight(0xffffff, 1);
                lamp.name = "Lamp";
                root.add(lamp);
                const b = new SceneBindings(root, vm);
                const binding = b.bind("jump", "Lamp.visible", BindToScene)!;
                expect.that(binding.isBound).is(true);
                b.dispose();
                expect.that(binding.isBound).is(false);
                vm.getTrigger("jump")!.fire();
                binding.update();
                b.update();
                expect.that(lamp.visible).is(true);
            });
        });

        group("dispose queues helpers' materials and geometries", () => {
            test("DirectionalLightHelper and PlaneHelper", (expect) => {
                const m0 = disposedMaterials.length, g0 = disposedGeometries.length;
                const helper = new DirectionalLightHelper(new DirectionalLight(0xffffff, 1), 2);
                helper.dispose();
                expect.that(disposedMaterials.length).is(m0 + 2);
                expect.that(disposedMaterials.indexOf(helper.lightPlane.material.id) >= 0).is(true);
                expect.that(disposedMaterials.indexOf(helper.targetLine.material.id) >= 0).is(true);
                expect.that(disposedGeometries.length).is(g0 + 2);
                const plane = new PlaneHelper(new Plane(new Vector3(0, 1, 0), 0), 2);
                plane.dispose();
                expect.that(disposedMaterials.indexOf(plane.fill.material.id) >= 0).is(true);
                expect.that(disposedGeometries.indexOf(plane.fill.geometry.id) >= 0).is(true);
                expect.that(disposedMaterials.length).is(m0 + 4);
                disposedMaterials.length = m0;
                disposedGeometries.length = g0;
            });
            test("TransformControls disposes its gizmo", (expect) => {
                const m0 = disposedMaterials.length, g0 = disposedGeometries.length;
                const controls = new TransformControls(new PerspectiveCamera());
                let meshes = 0;
                const gizmo = controls.getHelper();
                for (let i = 0; i < gizmo.children.length; i++) meshes++;
                controls.dispose();
                expect.that(disposedMaterials.length).is(m0 + meshes);
                // Nine shared geometries, each once.
                expect.that(disposedGeometries.length).is(g0 + 9);
                disposedMaterials.length = m0;
                disposedGeometries.length = g0;
            });
            test("RoomEnvironment", (expect) => {
                const m0 = disposedMaterials.length, g0 = disposedGeometries.length;
                const room = new RoomEnvironment();
                room.dispose();
                expect.that(disposedGeometries.length).is(g0 + 1);   // one box shared
                expect.that(disposedMaterials.length).is(m0 + 8);    // room, boxes, six lights
                disposedMaterials.length = m0;
                disposedGeometries.length = g0;
            });
            test("Water2 and its flat normal maps", (expect) => {
                const m0 = disposedMaterials.length, t0 = disposedTextures.length;
                const water = new Water2(new PlaneGeometry(10, 10));
                water.dispose();
                // The reflector's, the refractor's and its own.
                expect.that(disposedMaterials.length).is(m0 + 3);
                expect.that(disposedMaterials.indexOf(water.material.id) >= 0).is(true);
                // Two render target textures and the two flat maps (at least).
                expect.that(disposedTextures.length >= t0 + 4).is(true);
                disposedMaterials.length = m0;
                disposedTextures.length = t0;
            });
            test("LUTPass disposes its placeholder LUT once replaced", (expect) => {
                const t0 = disposedTextures.length;
                const m0 = disposedMaterials.length, g0 = disposedGeometries.length;
                const pass = new LUTPass();
                const white = new Uint8Array(4 * 8);
                pass.lut = new Data3DTexture(white, 2, 2, 2);
                expect.that(disposedTextures.length).is(t0 + 1);
                pass.dispose();
                expect.that(disposedTextures.length).is(t0 + 1);   // the LUT set is the caller's
                disposedTextures.length = t0;
                disposedMaterials.length = m0;
                disposedGeometries.length = g0;
            });
        });

        group("GeometryBVH trees", () => {
            test("go with GeometryBVH.dispose and geometry.dispose", (expect) => {
                const count = GeometryBVH.count();
                const a = new BoxGeometry(1, 1, 1, 4, 4, 4);
                const b = new BoxGeometry(1, 1, 1, 4, 4, 4);
                expect.that(GeometryBVH.build(a) != null).is(true);
                expect.that(GeometryBVH.build(b) != null).is(true);
                expect.that(GeometryBVH.count()).is(count + 2);
                GeometryBVH.dispose(a);
                expect.that(GeometryBVH.count()).is(count + 1);
                expect.that(GeometryBVH.get(a) == null).is(true);
                const g0 = disposedGeometries.length;
                b.dispose();
                expect.that(GeometryBVH.count()).is(count);
                expect.that(b.hasListeners("dispose")).is(false);
                disposedGeometries.length = g0;
            });
            test("past maxTrees the least recently used goes", (expect) => {
                const max = GeometryBVH.maxTrees;
                const count = GeometryBVH.count();
                GeometryBVH.maxTrees = count + 2;
                const geometries: Array<BufferGeometry> = [];
                for (let i = 0; i < 3; i++) {
                    const g = new BoxGeometry();
                    geometries.push(g);
                    GeometryBVH.build(g);
                    if (i == 1) GeometryBVH.get(geometries[0]);   // the first is used again
                }
                expect.that(GeometryBVH.count()).is(count + 2);
                expect.that(GeometryBVH.get(geometries[0]) != null).is(true);
                expect.that(GeometryBVH.get(geometries[1]) == null).is(true);
                expect.that(GeometryBVH.get(geometries[2]) != null).is(true);
                expect.that(geometries[1].hasListeners("dispose")).is(false);
                for (let i = 0; i < 3; i++) GeometryBVH.dispose(geometries[i]);
                GeometryBVH.maxTrees = max;
                expect.that(GeometryBVH.count()).is(count);
            });
        });
    }
}
