// three.js AnimationObjectGroup: several objects animated as one by a
// mixer, sharing its actions (one clip drives them all).
//
//     const group = new AnimationObjectGroup([a, b, c]);
//     const mixer = new AnimationMixer(group);
//     mixer.clipAction(clip).play();   // ".position" tracks move a, b and c
//
// It is an Object3D subclass here so it can be a mixer's root (three.js
// takes an Object3D or a group there): never add it to a scene. `add`,
// `remove` and `uncache` take one object each and do not parent it.
// Objects keep their bindings while removed, as three.js's cached objects;
// uncache forgets them.

import { Object3D } from "../core/Object3D";

export class AnimationObjectGroupObjectStats {
    /// Every object the group knows (in use and cached).
    total: i32 = 0;
    /// Objects the group animates.
    inUse: i32 = 0;
}

export class AnimationObjectGroupStats {
    objects: AnimationObjectGroupObjectStats = new AnimationObjectGroupObjectStats();
    /// Property bindings each object has (one per bound track path).
    bindingsPerObject: i32 = 0;
}

export class AnimationObjectGroup extends Object3D {
    readonly isAnimationObjectGroup: bool = true;
    /// The objects animated, in the order added.
    readonly activeObjects: Array<Object3D> = [];
    /// Removed objects whose bindings are kept until `uncache`.
    readonly cachedObjects: Array<Object3D> = [];
    /// Track paths bound so far (PropertyBinding.Composite registers them).
    readonly paths: Array<string> = [];

    constructor(objects: Array<Object3D> = []) {
        super();
        for (let i = 0; i < objects.length; i++) this.add(objects[i]);
    }

    /// The number of cached objects (three.js's threshold field).
    get nCachedObjects_(): i32 { return this.cachedObjects.length; }

    /// Counts, as three.js's `stats.objects.total / inUse` and
    /// `stats.bindingsPerObject`.
    get stats(): AnimationObjectGroupStats {
        const s = new AnimationObjectGroupStats();
        s.objects.total = this.activeObjects.length + this.cachedObjects.length;
        s.objects.inUse = this.activeObjects.length;
        s.bindingsPerObject = this.paths.length;
        return s;
    }

    /// Animates `object` too (or again, if it was removed).
    override add(object: Object3D): Object3D {
        const cached = this.cachedObjects.indexOf(object);
        if (cached >= 0) this.cachedObjects.splice(cached, 1);
        if (this.activeObjects.indexOf(object) < 0) this.activeObjects.push(object);
        this.version++;
        return this;
    }

    /// Stops animating `object`, keeping its bindings.
    override remove(object: Object3D): Object3D {
        const i = this.activeObjects.indexOf(object);
        if (i >= 0) {
            this.activeObjects.splice(i, 1);
            this.cachedObjects.push(object);
            this.version++;
        }
        return this;
    }

    /// Forgets `object` and its bindings.
    uncache(object: Object3D): void {
        let i = this.activeObjects.indexOf(object);
        if (i >= 0) this.activeObjects.splice(i, 1);
        i = this.cachedObjects.indexOf(object);
        if (i >= 0) this.cachedObjects.splice(i, 1);
        this.version++;
    }

    /// Bumped on every add / remove / uncache (bindings rebuild their lists).
    version: i32 = 0;
}
