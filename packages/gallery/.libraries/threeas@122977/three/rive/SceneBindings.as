// Data binding between a three.js scene and a Rive view model: scene
// properties (transforms, material colours and numbers, light intensities
// and colours, visibility, morph weights, animation actions) follow view
// model properties, or write into them, or both. A Rive state machine,
// listener, timeline bind or the host then drives the 3D scene, and the
// scene can show its state in Rive UI.
//
//     const bindings = new SceneBindings(this.scene, context.viewModel());
//     bindings.bind("lamp", "Lamp.intensity");                    // both ways
//     bindings.bind("spin", "Turntable.rotation[y]", BindToScene, MathUtils.DEG2RAD);
//     bindings.bind("tint", "Car.material.color");                // a colour property
//     bindings.bind("height", "Ball.position[y]", BindToViewModel);
//     bindings.addAction("walk", walkAction);
//     bindings.bind("walking", "@walk.weight");                   // an action's weight
//     this.bindings = bindings;                                   // ThreeLayout updates it
//
// Or with no code at all: a view model with a `threeBindings` string
// lists them, one per line or `;`:
//
//     lamp -> Lamp.intensity            view model drives the scene
//     height <- Ball.position[y]        the scene writes the view model
//     tint <-> Car.material.color       both ways
//     spin -> Turntable.rotation[y] * 0.0174533    times a scale
//     wave -> @wave.play                a trigger plays an action
//
// ThreeLayout makes these bindings itself when its view model has that
// string (named actions come from `bindings.addAction`).
//
// Paths are PropertyBinding's (three.js's track names: "node.property",
// "node.property[x]", "node.material.color" ...); "@name.field" names an
// action added with addAction: weight, time, timeScale, paused, enabled,
// running (bool: play / stop), play and stop (triggers). The view model
// property's kind picks the conversion: a number takes one value (times
// `scale`, plus `offset`), a colour a colour (sRGB to linear), a boolean
// one value at 0 or 1, a trigger fires the target.

import { ViewModel, PropertyNumber, PropertyColor, PropertyBoolean, PropertyTrigger, PropertyString } from "rive/data";
import { Object3D } from "../core/Object3D";
import { Color } from "../math/Color";
import { PropertyBinding } from "../animation/PropertyBinding";
import { AnimationAction } from "../animation/AnimationMixer";

/// The view model drives the scene.
export const BindToScene: i32 = 1;
/// The scene writes the view model.
export const BindToViewModel: i32 = 2;
/// Both: whichever side changed since the last update wins.
export const BindBoth: i32 = 3;

/// The view model string property ThreeLayout reads bindings from.
export const BINDINGS_PROPERTY: string = "threeBindings";

/// What a binding reads and writes on the scene side. Subclass it to bind
/// anything else (override valueSize, getValue, setValue, and isColor /
/// isBoolean / fire as needed).
export class SceneBindingTarget {
    get valueSize(): i32 { return 1; }
    get isColor(): bool { return false; }
    get isBoolean(): bool { return false; }
    getValue(out: Float64Array): void {}
    setValue(v: Float64Array): void {}
    /// A view model trigger fired.
    fire(): void {}
}

/// A PropertyBinding path under a root.
export class PathTarget extends SceneBindingTarget {
    readonly binding: PropertyBinding;

    constructor(root: Object3D, path: string) {
        super();
        this.binding = PropertyBinding.create(root, path);
    }

    override get valueSize(): i32 { return this.binding.valueSize; }
    override get isColor(): bool { return this.binding.isColor; }
    override get isBoolean(): bool { return this.binding.isBoolean; }
    override getValue(out: Float64Array): void { this.binding.getValue(out); }
    override setValue(v: Float64Array): void { this.binding.setValue(v); }
    /// A trigger toggles a boolean (visible) or does nothing.
    override fire(): void {
        if (!this.binding.isBoolean) return;
        _v[0] = 0;
        this.binding.getValue(_v);
        _v[0] = _v[0] >= 0.5 ? 0 : 1;
        this.binding.setValue(_v);
    }
}

const ACTION_WEIGHT: i32 = 0;
const ACTION_TIME: i32 = 1;
const ACTION_TIME_SCALE: i32 = 2;
const ACTION_PAUSED: i32 = 3;
const ACTION_ENABLED: i32 = 4;
const ACTION_RUNNING: i32 = 5;
const ACTION_PLAY: i32 = 6;
const ACTION_STOP: i32 = 7;

/// A field of an AnimationAction: "weight", "time", "timeScale", "paused",
/// "enabled", "running", "play" or "stop".
export class ActionTarget extends SceneBindingTarget {
    readonly action: AnimationAction;
    readonly field: i32;

    constructor(action: AnimationAction, field: string) {
        super();
        this.action = action;
        this.field = actionField(field);
    }

    get isValid(): bool { return this.field >= 0; }

    override get isBoolean(): bool {
        const f = this.field;
        return f == ACTION_PAUSED || f == ACTION_ENABLED || f == ACTION_RUNNING;
    }

    override getValue(out: Float64Array): void {
        const a = this.action;
        const f = this.field;
        if (f == ACTION_WEIGHT) out[0] = a.weight;
        else if (f == ACTION_TIME) out[0] = a.time;
        else if (f == ACTION_TIME_SCALE) out[0] = a.timeScale;
        else if (f == ACTION_PAUSED) out[0] = a.paused ? 1 : 0;
        else if (f == ACTION_ENABLED) out[0] = a.enabled ? 1 : 0;
        else if (f == ACTION_RUNNING) out[0] = a.isScheduled() && a.enabled ? 1 : 0;
        else out[0] = 0;
    }

    override setValue(v: Float64Array): void {
        const a = this.action;
        const f = this.field;
        if (f == ACTION_WEIGHT) a.setEffectiveWeight(v[0]);
        else if (f == ACTION_TIME) a.time = v[0];
        else if (f == ACTION_TIME_SCALE) a.setEffectiveTimeScale(v[0]);
        else if (f == ACTION_PAUSED) a.paused = v[0] >= 0.5;
        else if (f == ACTION_ENABLED) a.enabled = v[0] >= 0.5;
        else if (f == ACTION_RUNNING) {
            const on = v[0] >= 0.5;
            if (on && !(a.isScheduled() && a.enabled)) a.reset().play();
            else if (!on && a.isScheduled()) a.stop();
        }
    }

    override fire(): void {
        if (this.field == ACTION_PLAY) this.action.reset().play();
        else if (this.field == ACTION_STOP) this.action.stop();
        else if (this.isBoolean) {
            this.getValue(_v);
            _v[0] = _v[0] >= 0.5 ? 0 : 1;
            this.setValue(_v);
        }
    }
}

const KIND_NONE: i32 = 0;
const KIND_NUMBER: i32 = 1;
const KIND_COLOR: i32 = 2;
const KIND_BOOLEAN: i32 = 3;
const KIND_TRIGGER: i32 = 4;

/// One view model property bound to one scene target.
export class SceneBinding {
    readonly propertyName: string;
    readonly target: SceneBindingTarget;
    /// BindToScene, BindToViewModel or BindBoth.
    direction: i32;
    /// scene = viewModel x scale + offset (numbers).
    scale: f64;
    offset: f64;
    private kind: i32 = KIND_NONE;
    private number: PropertyNumber? = null;
    private color: PropertyColor? = null;
    private boolean: PropertyBoolean? = null;
    private trigger: PropertyTrigger? = null;
    private fired: bool = false;
    private started: bool = false;
    private lastViewModel: f64 = NaN;
    private lastScene: f64 = NaN;
    private value: Float64Array = new Float64Array(4);

    constructor(propertyName: string, target: SceneBindingTarget, direction: i32, scale: f64, offset: f64) {
        this.propertyName = propertyName;
        this.target = target;
        this.direction = direction;
        this.scale = scale != 0 ? scale : 1;
        this.offset = offset;
    }

    /// Whether the view model has the property (of a kind the target takes).
    get isBound(): bool { return this.kind != KIND_NONE; }

    /// Looks the property up in `vm` (called by SceneBindings).
    attach(vm: ViewModel?): void {
        this.kind = KIND_NONE;
        this.number = null; this.color = null; this.boolean = null;
        const trigger = this.trigger;
        if (trigger != null) trigger.removeListenerWith(this, SceneBinding.onTrigger);
        this.trigger = null;
        this.started = false;
        if (vm == null) return;
        const name = this.propertyName;
        const t = this.target;
        if (t.isColor) {
            const c = vm.getColor(name);
            if (c != null) { this.color = c; this.kind = KIND_COLOR; }
        } else if (t.valueSize == 1) {
            const n = vm.getNumber(name);
            if (n != null) { this.number = n; this.kind = KIND_NUMBER; }
            else {
                const b = vm.getBoolean(name);
                if (b != null) { this.boolean = b; this.kind = KIND_BOOLEAN; }
            }
        }
        if (this.kind == KIND_NONE) {
            const tr = vm.getTrigger(name);
            if (tr != null) {
                tr.addListenerWith(this, SceneBinding.onTrigger);
                this.trigger = tr;
                this.kind = KIND_TRIGGER;
            }
        }
    }

    private static onTrigger(self: SceneBinding): void {
        self.fired = true;
    }

    /// Syncs once: the side that changed since the last sync wins (the
    /// view model on the first sync, unless the direction is
    /// BindToViewModel).
    update(): void {
        const k = this.kind;
        if (k == KIND_NONE) return;
        const t = this.target;
        if (k == KIND_TRIGGER) {
            if (this.fired) {
                this.fired = false;
                if ((this.direction & BindToScene) != 0) t.fire();
            }
            return;
        }
        const toScene = (this.direction & BindToScene) != 0;
        const toViewModel = (this.direction & BindToViewModel) != 0;
        const vmValue = this.readViewModel();
        t.getValue(this.value);
        const sceneValue = this.sceneKey();
        if (!this.started) {
            this.started = true;
            if (toScene) this.writeScene(vmValue);
            else if (toViewModel) this.writeViewModel();
            this.lastViewModel = this.readViewModel();
            t.getValue(this.value);
            this.lastScene = this.sceneKey();
            return;
        }
        if (toScene && vmValue != this.lastViewModel) {
            this.writeScene(vmValue);
            this.lastViewModel = vmValue;
            t.getValue(this.value);
            this.lastScene = this.sceneKey();
        } else if (toViewModel && sceneValue != this.lastScene) {
            this.writeViewModel();
            this.lastScene = sceneValue;
            this.lastViewModel = this.readViewModel();
        }
    }

    // The view model value as a number (a colour's 32 bits).
    private readViewModel(): f64 {
        const k = this.kind;
        if (k == KIND_NUMBER) return this.number!.value;
        if (k == KIND_COLOR) return <f64>(<u32>this.color!.value);
        if (k == KIND_BOOLEAN) return this.boolean!.value ? 1 : 0;
        return 0;
    }

    // The scene value as one comparable number (a colour as sRGB hex).
    private sceneKey(): f64 {
        const v = this.value;
        if (this.kind == KIND_COLOR) {
            _color.setRGB(v[0], v[1], v[2]);
            return <f64>_color.getHex();
        }
        if (this.kind == KIND_BOOLEAN) return v[0] >= 0.5 ? 1 : 0;
        return v[0];
    }

    private writeScene(vmValue: f64): void {
        const v = this.value;
        const k = this.kind;
        if (k == KIND_NUMBER) v[0] = vmValue * this.scale + this.offset;
        else if (k == KIND_BOOLEAN) v[0] = vmValue;
        else if (k == KIND_COLOR) {
            _color.setHex(<u32>vmValue);
            v[0] = _color.r; v[1] = _color.g; v[2] = _color.b;
        }
        this.target.setValue(v);
    }

    private writeViewModel(): void {
        const v = this.value;
        const k = this.kind;
        if (k == KIND_NUMBER) this.number!.value = (v[0] - this.offset) / this.scale;
        else if (k == KIND_BOOLEAN) this.boolean!.value = v[0] >= 0.5;
        else if (k == KIND_COLOR) {
            _color.setRGB(v[0], v[1], v[2]);
            this.color!.value = _color.getRiveColor(1);
        }
    }
}

/// A set of SceneBindings between `root` and a view model, synced by
/// `update()` (ThreeLayout calls it each frame when it is its `bindings`).
export class SceneBindings {
    readonly root: Object3D;
    viewModel: ViewModel? = null;
    readonly bindings: Array<SceneBinding> = [];
    /// What could not be bound (unknown paths, missing view model
    /// properties, malformed spec lines), one message each.
    readonly errors: Array<string> = [];
    private actionNames: Array<string> = [];
    private actions: Array<AnimationAction> = [];
    private spec: string = "";
    private specProperty: PropertyString? = null;
    private specRoot: bool = false;
    private stale: bool = false;

    constructor(root: Object3D, viewModel: ViewModel? = null) {
        this.root = root;
        this.viewModel = viewModel;
    }

    /// Bindings listed in `vm`'s string property `property`: parsed at the
    /// first update (so the scene and named actions can be set up first),
    /// and again whenever the string changes, an action is added or
    /// `refresh()` is called.
    static fromViewModel(root: Object3D, vm: ViewModel, property: string = BINDINGS_PROPERTY): SceneBindings {
        const b = new SceneBindings(root, vm);
        const spec = vm.getString(property);
        if (spec != null) {
            b.specProperty = spec;
            b.specRoot = true;
            b.stale = true;
        }
        return b;
    }

    /// Parses the view model's spec again at the next update (after adding
    /// objects the spec names).
    refresh(): void { this.stale = true; }

    /// Binds to `vm` instead (every binding looks its property up again).
    setViewModel(vm: ViewModel?): void {
        this.viewModel = vm;
        for (let i = 0; i < this.bindings.length; i++) this.bindings[i].attach(vm);
    }

    /// Names `action` for "@name.field" paths.
    addAction(name: string, action: AnimationAction): void {
        const i = this.actionNames.indexOf(name);
        if (i >= 0) this.actions[i] = action;
        else {
            this.actionNames.push(name);
            this.actions.push(action);
        }
        if (this.specRoot) this.stale = true;
    }

    /// Binds view model property `property` to a scene `path` (or
    /// "@action.field"); null when the path resolves to nothing.
    bind(property: string, path: string, direction: i32 = BindBoth, scale: f64 = 1, offset: f64 = 0): SceneBinding? {
        let target: SceneBindingTarget;
        if (path.startsWith("@")) {
            const dot = path.lastIndexOf(".");
            const name = dot > 1 ? path.substring(1, dot) : path.substring(1);
            const field = dot > 1 ? path.substring(dot + 1) : "weight";
            const i = this.actionNames.indexOf(name);
            if (i < 0) {
                this.errors.push("no action named " + name);
                return null;
            }
            const at = new ActionTarget(this.actions[i], field);
            if (!at.isValid) {
                this.errors.push("unknown action field " + field);
                return null;
            }
            target = at;
        } else {
            const pt = new PathTarget(this.root, path);
            if (!pt.binding.isBound) {
                this.errors.push("unresolved path " + path);
                return null;
            }
            target = pt;
        }
        return this.bindTarget(property, target, direction, scale, offset);
    }

    /// Binds `property` to an action field ("weight", "time" ...).
    bindAction(property: string, action: AnimationAction, field: string = "weight", direction: i32 = BindBoth,
               scale: f64 = 1, offset: f64 = 0): SceneBinding? {
        const at = new ActionTarget(action, field);
        if (!at.isValid) {
            this.errors.push("unknown action field " + field);
            return null;
        }
        return this.bindTarget(property, at, direction, scale, offset);
    }

    /// Binds `property` to a target of your own.
    bindTarget(property: string, target: SceneBindingTarget, direction: i32 = BindBoth, scale: f64 = 1,
               offset: f64 = 0): SceneBinding {
        const b = new SceneBinding(property, target, direction, scale, offset);
        b.attach(this.viewModel);
        if (this.viewModel != null && !b.isBound) this.errors.push("no usable view model property " + property);
        this.bindings.push(b);
        return b;
    }

    /// Removes every binding of `property`.
    unbind(property: string): void {
        for (let i = this.bindings.length - 1; i >= 0; i--) {
            if (this.bindings[i].propertyName == property) {
                this.bindings[i].attach(null);
                this.bindings.splice(i, 1);
            }
        }
    }

    /// Adds the bindings of a spec: entries separated by new lines or ";",
    /// each "property -> path", "property <- path" or "property <-> path"
    /// (or "="), optionally followed by "* scale" and "+ offset". Returns
    /// how many were made.
    parse(spec: string): i32 {
        let made = 0;
        const lines = spec.replaceAll("\r", "\n").replaceAll(";", "\n").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line.length == 0 || line.startsWith("#") || line.startsWith("//")) continue;
            let direction = BindBoth;
            let op = line.indexOf("<->");
            let opLength = 3;
            if (op < 0) { op = line.indexOf("->"); opLength = 2; direction = BindToScene; }
            if (op < 0) { op = line.indexOf("<-"); opLength = 2; direction = BindToViewModel; }
            if (op < 0) { op = line.indexOf("="); opLength = 1; direction = BindBoth; }
            if (op <= 0) {
                this.errors.push("malformed binding: " + line);
                continue;
            }
            const property = line.substring(0, op).trim();
            let rest = line.substring(op + opLength).trim();
            let scale: f64 = 1, offset: f64 = 0;
            const plus = rest.indexOf(" + ");
            if (plus > 0) {
                offset = parseFloat(rest.substring(plus + 3).trim());
                rest = rest.substring(0, plus).trim();
            }
            const times = rest.indexOf(" * ");
            if (times > 0) {
                scale = parseFloat(rest.substring(times + 3).trim());
                rest = rest.substring(0, times).trim();
            }
            if (isNaN(scale) || isNaN(offset) || property.length == 0 || rest.length == 0) {
                this.errors.push("malformed binding: " + line);
                continue;
            }
            if (this.bind(property, rest, direction, scale, offset) != null) made++;
        }
        return made;
    }

    /// Syncs every binding (and re-reads a spec property that changed).
    update(): void {
        const sp = this.specProperty;
        if (sp != null && this.specRoot) {
            const spec = sp.value;
            if (spec != this.spec || this.stale) {
                this.stale = false;
                for (let i = 0; i < this.bindings.length; i++) this.bindings[i].attach(null);
                this.bindings.length = 0;
                this.errors.length = 0;
                this.spec = spec;
                this.parse(spec);
            }
        }
        for (let i = 0; i < this.bindings.length; i++) this.bindings[i].update();
    }
}

function actionField(name: string): i32 {
    if (name == "weight") return ACTION_WEIGHT;
    if (name == "time") return ACTION_TIME;
    if (name == "timeScale") return ACTION_TIME_SCALE;
    if (name == "paused") return ACTION_PAUSED;
    if (name == "enabled") return ACTION_ENABLED;
    if (name == "running") return ACTION_RUNNING;
    if (name == "play") return ACTION_PLAY;
    if (name == "stop") return ACTION_STOP;
    return -1;
}

const _v = new Float64Array(4);
const _color = new Color();
