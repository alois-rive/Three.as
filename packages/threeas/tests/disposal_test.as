// How renderers keep and free their state (renderers/gpu/Disposal), without
// a GPU: state kept on its object per renderer index, "dispose" events
// queued for every renderer that listens, index and serial reuse.
// rive . --test

import { Tests } from "rive/test";
import { RendererData } from "../three/core/RendererData";
import { EventDispatcher } from "../three/core/EventDispatcher";
import {
    DisposeQueue, DisposeListener, RendererSlot, acquireSlot, releaseSlot, dataOf, setDataOf, clearDataOf,
    DISPOSED_GEOMETRY, DISPOSED_TEXTURE, DISPOSED_MATERIAL, DISPOSED_RENDER_TARGET, DISPOSED_OBJECT,
    DISPOSED_SKELETON, DISPOSED_PMREM, PMREM_DISPOSE_EVENT,
} from "../three/renderers/gpu/Disposal";
import { MeshLambertMaterial } from "../three/materials/MeshLambertMaterial";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { Texture } from "../three/textures/Texture";
import { DataTexture } from "../three/textures/DataTexture";
import { RenderTarget } from "../three/renderers/RenderTarget";
import { WebGLCubeRenderTarget } from "../three/renderers/WebGLCubeRenderTarget";
import { InstancedMesh } from "../three/objects/InstancedMesh";
import { BatchedMesh } from "../three/objects/BatchedMesh";
import { Skeleton, Bone } from "../three/objects/Skeleton";
import { PMREMGenerator } from "../three/extras/PMREMGenerator";

/// State that counts its releases.
class Counted extends RendererData {
    released: i32 = 0;
    override release(): void { this.released++; }
}

/// A renderer's queue and slot, as GPURenderer has them.
class FakeRenderer {
    queue: DisposeQueue = new DisposeQueue();
    slot: RendererSlot = new RendererSlot();

    constructor() {
        acquireSlot(this.slot);
    }

    /// Makes state for `owner` and listens for its `type` event.
    track(owner: EventDispatcher, kind: i32, type: string = "dispose"): Counted {
        const d = new Counted();
        setDataOf(owner, this.slot, d);
        new DisposeListener(this.queue, kind, d).attach(owner, type);
        return d;
    }

    /// Whether the queue holds `data` as `kind`.
    queued(kind: i32, data: RendererData): bool {
        for (let i = 0; i < this.queue.length; i++) {
            if (this.queue.kinds[i] == kind && this.queue.items[i] === data) return true;
        }
        return false;
    }
}

export class DisposalTests extends Tests {
    override run(): void {
        group("state on objects", () => {
            test("each renderer has its own entry", (expect) => {
                const a = new FakeRenderer();
                const b = new FakeRenderer();
                expect.that(a.slot.index).never.is(b.slot.index);
                const m = new MeshLambertMaterial();
                expect.that(dataOf(m, a.slot) == null).is(true);
                const da = a.track(m, DISPOSED_MATERIAL);
                const db = b.track(m, DISPOSED_MATERIAL);
                expect.that(dataOf(m, a.slot) === da).is(true);
                expect.that(dataOf(m, b.slot) === db).is(true);
                clearDataOf(m, a.slot, da);
                expect.that(dataOf(m, a.slot) == null).is(true);
                expect.that(dataOf(m, b.slot) === db).is(true);
                releaseSlot(a.slot);
                releaseSlot(b.slot);
            });
            test("a disposed renderer's state no longer matches, and is released when replaced", (expect) => {
                const r = new FakeRenderer();
                const m = new MeshLambertMaterial();
                const old = r.track(m, DISPOSED_MATERIAL);
                const index = r.slot.index;
                releaseSlot(r.slot);
                expect.that(r.slot.index).is(-1);
                // The next renderer takes the free index, with a new serial.
                const next = new FakeRenderer();
                expect.that(next.slot.index).is(index);
                expect.that(dataOf(m, next.slot) == null).is(true);
                const fresh = next.track(m, DISPOSED_MATERIAL);
                expect.that(old.released).is(1);
                expect.that(fresh.released).is(0);
                expect.that(dataOf(m, next.slot) === fresh).is(true);
                releaseSlot(next.slot);
            });
            test("freed state (serial -1) is not found and not released again", (expect) => {
                const r = new FakeRenderer();
                const g = new BoxGeometry();
                const d = r.track(g, DISPOSED_GEOMETRY);
                d.serial = -1;
                expect.that(dataOf(g, r.slot) == null).is(true);
                r.track(g, DISPOSED_GEOMETRY);
                expect.that(d.released).is(0);
                releaseSlot(r.slot);
            });
        });
        group("dispose events", () => {
            test("every listening renderer queues a material's dispose, once", (expect) => {
                const a = new FakeRenderer();
                const b = new FakeRenderer();
                const m = new MeshLambertMaterial();
                const da = a.track(m, DISPOSED_MATERIAL);
                const db = b.track(m, DISPOSED_MATERIAL);
                m.dispose();
                expect.that(a.queued(DISPOSED_MATERIAL, da)).is(true);
                expect.that(b.queued(DISPOSED_MATERIAL, db)).is(true);
                // The listeners left: a second dispose queues nothing.
                expect.that(m.hasListeners("dispose")).is(false);
                m.dispose();
                expect.that(a.queue.length).is(1);
                expect.that(b.queue.length).is(1);
                releaseSlot(a.slot);
                releaseSlot(b.slot);
            });
            test("a detached listener queues nothing", (expect) => {
                const r = new FakeRenderer();
                const t = new Texture();
                const l = new DisposeListener(r.queue, DISPOSED_TEXTURE, new Counted()).attach(t);
                l.detach();
                t.dispose();
                expect.that(r.queue.length).is(0);
                releaseSlot(r.slot);
            });
            test("geometries, textures and their subclasses", (expect) => {
                const r = new FakeRenderer();
                const g = new BoxGeometry();
                const dg = r.track(g, DISPOSED_GEOMETRY);
                const t = new DataTexture(new Uint8Array(4), 1, 1);
                const dt = r.track(t, DISPOSED_TEXTURE);
                g.dispose();
                t.dispose();
                expect.that(r.queued(DISPOSED_GEOMETRY, dg)).is(true);
                expect.that(r.queued(DISPOSED_TEXTURE, dt)).is(true);
                releaseSlot(r.slot);
            });
            test("render targets, and a cube target's faces and texture", (expect) => {
                const r = new FakeRenderer();
                const rt = new RenderTarget(4, 4);
                const drt = r.track(rt, DISPOSED_RENDER_TARGET);
                const dtex = r.track(rt.texture, DISPOSED_TEXTURE);
                rt.dispose();
                expect.that(r.queued(DISPOSED_RENDER_TARGET, drt)).is(true);
                expect.that(r.queued(DISPOSED_TEXTURE, dtex)).is(true);
                const cube = new WebGLCubeRenderTarget(4);
                const face = r.track(cube.faces[2], DISPOSED_RENDER_TARGET);
                const cubeTexture = r.track(cube.texture, DISPOSED_TEXTURE);
                cube.dispose();
                expect.that(r.queued(DISPOSED_RENDER_TARGET, face)).is(true);
                expect.that(r.queued(DISPOSED_TEXTURE, cubeTexture)).is(true);
                releaseSlot(r.slot);
            });
            test("InstancedMesh, BatchedMesh (and its geometry), Skeleton", (expect) => {
                const r = new FakeRenderer();
                const im = new InstancedMesh(new BoxGeometry(), new MeshLambertMaterial(), 4);
                const di = r.track(im, DISPOSED_OBJECT);
                im.dispose();
                expect.that(r.queued(DISPOSED_OBJECT, di)).is(true);
                const bm = new BatchedMesh(4, 100, 200);
                const db = r.track(bm, DISPOSED_OBJECT);
                const dbg = r.track(bm.geometry, DISPOSED_GEOMETRY);
                bm.dispose();
                expect.that(r.queued(DISPOSED_OBJECT, db)).is(true);
                expect.that(r.queued(DISPOSED_GEOMETRY, dbg)).is(true);
                const skeleton = new Skeleton([new Bone()]);
                const ds = r.track(skeleton, DISPOSED_SKELETON);
                skeleton.dispose();
                expect.that(r.queued(DISPOSED_SKELETON, ds)).is(true);
                releaseSlot(r.slot);
            });
            test("PMREMResult.dispose frees the PMREM, not the texture", (expect) => {
                const r = new FakeRenderer();
                const t = new Texture();
                const dt = r.track(t, DISPOSED_TEXTURE);
                const dp = new DisposeListener(r.queue, DISPOSED_PMREM, dt).attach(t, PMREM_DISPOSE_EVENT);
                const result = new PMREMGenerator().fromEquirectangular(t);
                result.dispose();
                expect.that(r.queued(DISPOSED_PMREM, dt)).is(true);
                expect.that(r.queued(DISPOSED_TEXTURE, dt)).is(false);
                expect.that(dp.owner == null).is(true);
                expect.that(t.hasListeners("dispose")).is(true);
                releaseSlot(r.slot);
            });
        });
    }
}
