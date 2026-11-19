// three.js EventDispatcher. AnimaScript has no closures, so a listener is
// an object with `handleEvent(event)` (the DOM's EventListener shape):
//
//     class OnChange extends THREE.EventListener {
//         override handleEvent(event: THREE.Event): void { ... }
//     }
//     controls.addEventListener("change", new OnChange());
//
// Objects dispatch "added", "removed", "childadded", "childremoved";
// materials, geometries and textures "dispose"; controls "change",
// "start", "end".

export class Event {
    type: string;
    /// The dispatcher (set by dispatchEvent).
    target: EventDispatcher? = null;
    /// "childadded" / "childremoved": the child.
    child: EventDispatcher? = null;
    /// DragControls' "dragstart", "drag", "hoveron"...: the object.
    object: EventDispatcher? = null;
    /// TransformControls' "dragging-changed": whether dragging.
    value: bool = false;

    constructor(type: string) {
        this.type = type;
    }
}

export abstract class EventListener {
    abstract handleEvent(event: Event): void;
}

export class EventDispatcher {
    private _listeners: Map<string, Array<EventListener>>? = null;

    addEventListener(type: string, listener: EventListener): void {
        let map = this._listeners;
        if (map == null) {
            map = new Map<string, Array<EventListener>>();
            this._listeners = map;
        }
        if (!map.has(type)) map.set(type, []);
        const list = map.get(type);
        if (list.indexOf(listener) < 0) list.push(listener);
    }

    hasEventListener(type: string, listener: EventListener): bool {
        const map = this._listeners;
        return map != null && map.has(type) && map.get(type).indexOf(listener) >= 0;
    }

    /// Whether anything listens for `type` (to skip building events).
    hasListeners(type: string): bool {
        const map = this._listeners;
        return map != null && map.has(type) && map.get(type).length > 0;
    }

    removeEventListener(type: string, listener: EventListener): void {
        const map = this._listeners;
        if (map == null || !map.has(type)) return;
        const list = map.get(type);
        const i = list.indexOf(listener);
        if (i >= 0) list.splice(i, 1);
    }

    dispatchEvent(event: Event): void {
        const map = this._listeners;
        if (map == null || !map.has(event.type)) return;
        event.target = this;
        const list = map.get(event.type).slice();   // listeners may remove themselves
        for (let i = 0; i < list.length; i++) list[i].handleEvent(event);
        event.target = null;
    }
}
