// three.js Controls (src/extras/Controls.js): the base of camera controls,
// an EventDispatcher ("change", "start", "end"). Rive delivers input as
// pointer and scroll events instead of DOM listeners, so controls take
// them through these methods (ThreeLayout forwards them to its
// `controls`); `connect` / `disconnect` keep three.js's names and do
// nothing.

import { EventDispatcher, Event } from "../core/EventDispatcher";
import { Object3D } from "../core/Object3D";
import { PointerEvent, ScrollEvent } from "rive/events";

const _change = new Event("change");
const _start = new Event("start");
const _end = new Event("end");

export class Controls extends EventDispatcher {
    object: Object3D;
    enabled: bool = true;

    constructor(object: Object3D) {
        super();
        this.object = object;
    }

    connect(): void {}
    disconnect(): void {}
    dispose(): void {}

    /// Advances damping or motion; true when the object moved.
    update(delta: f64 = -1): bool { return false; }

    pointerDown(event: PointerEvent): void {}
    pointerMove(event: PointerEvent): void {}
    pointerUp(event: PointerEvent): void {}
    pointerExit(event: PointerEvent): void { this.pointerUp(event); }
    pointerScroll(event: ScrollEvent): void {}

    /// Dispatches "change" / "start" / "end" when something listens.
    protected changed(): void { if (this.hasListeners("change")) this.dispatchEvent(_change); }
    protected started(): void { if (this.hasListeners("start")) this.dispatchEvent(_start); }
    protected ended(): void { if (this.hasListeners("end")) this.dispatchEvent(_end); }
}
