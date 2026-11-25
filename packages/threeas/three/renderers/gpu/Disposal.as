// Where a renderer keeps its state, and how it learns it can free it
// (internal).
//
// State: three.js keeps a renderer's state for an object, material,
// geometry, texture or render target in WeakMaps keyed by it. AnimaScript has
// no weak references, so the state lives on the key itself
// (EventDispatcher._gpu, a RendererData per renderer index): it goes when
// the key does, its GPU handles freed when the collector collects them.
// Each renderer has an index (the lowest free one; freed by dispose()) and a
// serial (new for each renderer, and again after dispose()): data whose
// serial is not its renderer's is ignored, and released when replaced.
//
// Freeing now, as three.js: when a renderer first makes state for a
// geometry, texture, material, render target, InstancedMesh / BatchedMesh
// or skeleton, it listens for that object's "dispose" event; the event
// queues the state on the renderer's own DisposeQueue, which it drains at
// its next render (never in the middle of a pass), and the listener leaves
// the object. Every renderer has its own listeners, so each sees every
// dispose.
//
// AnimaScript has no closures: a listener is an object holding what the
// handler needs (core/EventDispatcher).

import { Event, EventDispatcher, EventListener } from "../../core/EventDispatcher";
import { RendererData } from "../../core/RendererData";

/// What a disposed state belongs to.
export const DISPOSED_GEOMETRY: i32 = 0;
export const DISPOSED_TEXTURE: i32 = 1;
export const DISPOSED_MATERIAL: i32 = 2;
export const DISPOSED_RENDER_TARGET: i32 = 3;
/// An InstancedMesh or BatchedMesh.
export const DISPOSED_OBJECT: i32 = 4;
export const DISPOSED_SKELETON: i32 = 5;
/// PMREMResult.dispose() of fromEquirectangular / fromCubemap: only the
/// texture's prefiltered chain is freed.
export const DISPOSED_PMREM: i32 = 6;

/// The event PMREMResult.dispose() dispatches on its texture.
export const PMREM_DISPOSE_EVENT: string = "pmremdispose";

/// A renderer's index in objects' `_gpu` and its serial.
export class RendererSlot {
    index: i32 = -1;
    serial: i32 = -1;
}

let _serial: i32 = 0;
const _usedIndices: Array<bool> = [];

/// Gives `slot` the lowest free index and a new serial.
export function acquireSlot(slot: RendererSlot): void {
    let i = 0;
    while (i < _usedIndices.length && _usedIndices[i]) i++;
    if (i == _usedIndices.length) _usedIndices.push(true);
    else _usedIndices[i] = true;
    slot.index = i;
    slot.serial = ++_serial;
}

/// Frees `slot`'s index (renderer.dispose()); the state it left on objects
/// no longer matches any renderer.
export function releaseSlot(slot: RendererSlot): void {
    if (slot.index >= 0 && slot.index < _usedIndices.length) _usedIndices[slot.index] = false;
    slot.index = -1;
    slot.serial = ++_serial;
}

/// The state of `slot`'s renderer on `owner`, or null.
export function dataOf(owner: EventDispatcher, slot: RendererSlot): RendererData? {
    const a = owner._gpu;
    const i = slot.index;
    if (a == null || i < 0 || i >= a.length) return null;
    const d = unchecked(a[i]);
    return d != null && d.serial == slot.serial ? d : null;
}

/// Stores `data` as the state of `slot`'s renderer on `owner`. State left
/// there by a disposed renderer is released.
export function setDataOf(owner: EventDispatcher, slot: RendererSlot, data: RendererData): void {
    let a = owner._gpu;
    if (a == null) {
        a = [];
        owner._gpu = a;
    }
    const i = slot.index;
    while (a.length <= i) a.push(null);
    const old = unchecked(a[i]);
    if (old != null && old !== data && old.serial >= 0 && old.serial != slot.serial) old.release();
    data.serial = slot.serial;
    unchecked(a[i] = data);
}

/// Removes `data` from `owner` (when it is there).
export function clearDataOf(owner: EventDispatcher, slot: RendererSlot, data: RendererData): void {
    const a = owner._gpu;
    const i = slot.index;
    if (a == null || i < 0 || i >= a.length) return;
    if (unchecked(a[i]) === data) unchecked(a[i] = null);
}

/// A renderer's disposed states since it last drained them.
export class DisposeQueue {
    kinds: Array<i32> = [];
    items: Array<RendererData> = [];
    /// True once the owning renderer was disposed: stale listeners detach
    /// without queuing into a dead queue.
    closed: bool = false;

    get length(): i32 { return this.items.length; }

    push(kind: i32, data: RendererData): void {
        if (this.closed) return;
        this.kinds.push(kind);
        this.items.push(data);
    }

    clear(): void {
        this.kinds.length = 0;
        this.items.length = 0;
    }
}

/// Listens for one object's "dispose" (or `type`) for one renderer, and
/// queues `data` when it comes.
export class DisposeListener extends EventListener {
    queue: DisposeQueue;
    kind: i32;
    data: RendererData;
    private target: EventDispatcher? = null;
    private type: string = "dispose";

    constructor(queue: DisposeQueue, kind: i32, data: RendererData) {
        super();
        this.queue = queue;
        this.kind = kind;
        this.data = data;
    }

    /// The object it listens to (null once detached).
    get owner(): EventDispatcher? { return this.target; }

    attach(target: EventDispatcher, type: string = "dispose"): DisposeListener {
        this.detach();
        this.target = target;
        this.type = type;
        target.addEventListener(type, this);
        return this;
    }

    detach(): void {
        const t = this.target;
        if (t == null) return;
        t.removeEventListener(this.type, this);
        this.target = null;
    }

    override handleEvent(event: Event): void {
        this.queue.push(this.kind, this.data);
        this.detach();
    }
}

/// Detaches `listener` when there is one (for nullable fields).
export function detach(listener: DisposeListener?): void {
    if (listener != null) listener.detach();
}
