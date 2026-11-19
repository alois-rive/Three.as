// three.js Controls (src/extras/Controls.js): the base of camera controls,
// an EventDispatcher ("change", "start", "end"). Rive delivers input as
// pointer and scroll events instead of DOM listeners, so controls take
// them through these methods (ThreeLayout forwards them to its
// `controls`); `connect` / `disconnect` keep three.js's names and do
// nothing.

import { EventDispatcher, Event } from "../core/EventDispatcher";
import { Object3D } from "../core/Object3D";
import { PointerEvent, ScrollEvent, KeyboardEvent } from "rive/events";

/// GLFW key codes, as Rive's KeyboardEvent.key reports them.
export const KEY_SPACE: i32 = 32;
export const KEY_A: i32 = 65;
export const KEY_D: i32 = 68;
export const KEY_E: i32 = 69;
export const KEY_F: i32 = 70;
export const KEY_Q: i32 = 81;
export const KEY_R: i32 = 82;
export const KEY_S: i32 = 83;
export const KEY_W: i32 = 87;
export const KEY_RIGHT: i32 = 262;
export const KEY_LEFT: i32 = 263;
export const KEY_DOWN: i32 = 264;
export const KEY_UP: i32 = 265;
export const KEY_LEFT_SHIFT: i32 = 340;

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
    /// Keys (the layout needs a FocusData child to receive them); true
    /// when handled.
    keyboardEvent(event: KeyboardEvent): bool { return false; }

    /// Whether a gesture of these controls is under way (ThreeLayout then
    /// keeps the pointer from its other controls).
    capturing(): bool { return false; }

    /// Dispatches "change" / "start" / "end" when something listens.
    protected changed(): void { if (this.hasListeners("change")) this.dispatchEvent(_change); }
    protected started(): void { if (this.hasListeners("start")) this.dispatchEvent(_start); }
    protected ended(): void { if (this.hasListeners("end")) this.dispatchEvent(_end); }
}
