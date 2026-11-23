// GamesFps: three.js's games_fps. A capsule player walks, jumps and slides
// along the walls of a level built from boxes, ramps, stairs and pillars;
// spheres thrown from the camera bounce off the level, the player and each
// other. The level becomes a collision world with Octree.fromGraphNode;
// the player is a Capsule pushed out by capsuleIntersect, the spheres by
// sphereIntersect (three.js's collision-world.glb is replaced by the
// level made here).
//
// Input: drag to look (three.js locks the pointer; Rive has no pointer
// lock), click or tap to throw (hold longer to throw harder), WASD or the
// arrows to move, Space to jump (the layout has a FocusData child for
// keys), H to show the octree (OctreeHelper, three.js's "debug").
// On-screen: a stick at the bottom left moves, the button at the bottom
// right jumps (touch). A gamepad: left stick moves, right stick looks,
// south jumps, right trigger throws. Until the first input the player
// looks around and throws spheres by itself. `--arg fpsTrace=1` logs the
// octree's build time and the player twice a second.

import * as THREE from "lib:threeas/three/Three";
import { Octree } from "lib:threeas/three/addons/math/Octree";
import { OctreeHelper } from "lib:threeas/three/addons/helpers/OctreeHelper";
import { Capsule } from "lib:threeas/three/addons/math/Capsule";
import { Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { PointerEvent, KeyboardEvent, GamepadEvent } from "rive/events";
import { Path } from "rive/path";
import { Paint, PaintStyle } from "rive/paint";
import { Color } from "rive/color";
import { Vector } from "rive/vector";
import { clock } from "rive/os";

const GRAVITY: f64 = 30;

const NUM_SPHERES = 100;
const SPHERE_RADIUS: f64 = 0.2;

const STEPS_PER_FRAME = 5;

const KEY_H = 72;

// The on-screen controls, in points from the layout's bottom corners.
const STICK_INSET: f64 = 84;
const STICK_RADIUS: f64 = 52;
const JUMP_INSET: f64 = 72;
const JUMP_RADIUS: f64 = 34;

class SphereBody {
    mesh: THREE.Mesh;
    collider: THREE.Sphere;
    velocity: THREE.Vector3 = new THREE.Vector3();

    constructor(mesh: THREE.Mesh, collider: THREE.Sphere) {
        this.mesh = mesh;
        this.collider = collider;
    }
}

/// A 64 x 64 tile for the floor: grey squares with a darker edge.
function floorTexture(): THREE.DataTexture {
    const size = 64;
    const data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const edge = x < 2 || y < 2 || x >= size - 2 || y >= size - 2;
            const half = ((x / 32) + (y / 32)) % 2 == 0;
            const g: i32 = edge ? 150 : half ? 205 : 190;
            const o = (y * size + x) * 4;
            data[o] = <u8>g; data[o + 1] = <u8>g; data[o + 2] = <u8>(g + 6); data[o + 3] = 255;
        }
    }
    const t = new THREE.DataTexture(data, size, size);
    t.colorSpace = THREE.SRGBColorSpace;
    t.wrapS = THREE.RepeatWrapping;
    t.wrapT = THREE.RepeatWrapping;
    t.magFilter = THREE.LinearFilter;
    t.minFilter = THREE.LinearMipmapLinearFilter;
    t.generateMipmaps = true;
    t.anisotropy = 4;
    return t;
}

function vxy(x: f64, y: f64): Vector { return Vector.xy(<f32>x, <f32>y); }

function addCircle(path: Path, cx: f64, cy: f64, r: f64): void {
    const k = 0.5522847498 * r;
    path.moveTo(vxy(cx + r, cy));
    path.cubicTo(vxy(cx + r, cy + k), vxy(cx + k, cy + r), vxy(cx, cy + r));
    path.cubicTo(vxy(cx - k, cy + r), vxy(cx - r, cy + k), vxy(cx - r, cy));
    path.cubicTo(vxy(cx - r, cy - k), vxy(cx - k, cy - r), vxy(cx, cy - r));
    path.cubicTo(vxy(cx + k, cy - r), vxy(cx + r, cy - k), vxy(cx + r, cy));
    path.close();
}

export class GamesFps extends THREE.ThreeLayout {
    /// Show the octree's boxes (three.js's "debug" checkbox; H toggles it).
    @input debug: bool = false;
    /// Draw the on-screen stick and jump button.
    @input touchControls: bool = true;
    /// Look around and throw by itself until the first input.
    @input autoplay: bool = true;

    worldOctree: Octree = new Octree();
    helper: OctreeHelper? = null;
    world: THREE.Group = new THREE.Group();

    spheres: Array<SphereBody> = [];
    sphereIdx: i32 = 0;

    playerCollider: Capsule = new Capsule(new THREE.Vector3(0, 0.35, 0), new THREE.Vector3(0, 1, 0), 0.35);
    playerVelocity: THREE.Vector3 = new THREE.Vector3();
    playerDirection: THREE.Vector3 = new THREE.Vector3();
    playerOnFloor: bool = false;

    vector1: THREE.Vector3 = new THREE.Vector3();
    vector2: THREE.Vector3 = new THREE.Vector3();
    vector3: THREE.Vector3 = new THREE.Vector3();

    /// Seconds fromGraphNode took (logged once).
    buildSeconds: f64 = 0;
    time: f64 = 0;
    mouseTime: f64 = 0;

    // Keys (three.js's keyStates), the on-screen stick and button, the pad.
    keyForward: bool = false;
    keyBackward: bool = false;
    keyLeft: bool = false;
    keyRight: bool = false;
    keyJump: bool = false;
    stickId: f64 = -1;
    stickX: f64 = 0;
    stickY: f64 = 0;
    jumpId: f64 = -1;
    padMoveX: f64 = 0;
    padMoveY: f64 = 0;
    padLookX: f64 = 0;
    padLookY: f64 = 0;
    padJump: bool = false;
    padThrow: bool = false;

    // The pointer that looks: its id, last position, travel since the press.
    lookId: f64 = -1;
    lookX: f64 = 0;
    lookY: f64 = 0;
    lookTravel: f64 = 0;

    // Autoplay: until the first input.
    idle: bool = true;
    nextThrow: f64 = 0.4;

    // `--arg fpsTrace=1`: log the player twice a second.
    trace: bool = false;
    nextTrace: f64 = 0;
    context2: Context? = null;

    hudPath: Path = new Path();
    hudFill: Paint = new Paint();
    hudStroke: Paint = new Paint();

    override setup(context: Context): bool {
        const camera = new THREE.PerspectiveCamera(70, 1, 0.1, 1000);
        camera.rotation.order = "YXZ";
        this.camera = camera;

        this.scene.background = new THREE.Color(0x88ccee);
        this.scene.fog = new THREE.Fog(0x88ccee, 0, 50);

        const fillLight1 = new THREE.HemisphereLight(0x8dc1de, 0x00668d, 1.5);
        fillLight1.position.set(2, 1, 1);
        this.scene.add(fillLight1);

        const directionalLight = new THREE.DirectionalLight(0xffffff, 2.5);
        directionalLight.position.set(-5, 25, -1);
        directionalLight.castShadow = true;
        const sc = directionalLight.shadow.camera as THREE.OrthographicCamera;
        sc.near = 0.01;
        sc.far = 500;
        sc.right = 30;
        sc.left = -30;
        sc.top = 30;
        sc.bottom = -30;
        sc.updateProjectionMatrix();
        directionalLight.shadow.mapSize.set(2048, 2048);
        directionalLight.shadow.radius = 4;
        directionalLight.shadow.bias = -0.0005;
        directionalLight.shadow.normalBias = 0.02;
        this.scene.add(directionalLight);

        const renderer = this.renderer!;
        renderer.shadowMap.enabled = true;
        renderer.shadowMap.type = THREE.VSMShadowMap;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;

        const sphereGeometry = new THREE.IcosahedronGeometry(SPHERE_RADIUS, 5);
        const sphereMaterial = new THREE.MeshLambertMaterial({ color: 0xdede8d });

        for (let i = 0; i < NUM_SPHERES; i++) {
            const sphere = new THREE.Mesh(sphereGeometry, sphereMaterial);
            sphere.castShadow = true;
            sphere.receiveShadow = true;
            this.scene.add(sphere);

            this.spheres.push(new SphereBody(sphere, new THREE.Sphere(new THREE.Vector3(0, -100, 0), SPHERE_RADIUS)));
        }

        this.buildLevel();
        this.scene.add(this.world);

        const t0 = clock();
        this.worldOctree.fromGraphNode(this.world);
        this.buildSeconds = clock() - t0;
        if (context.arg("fpsTrace") != null) {
            context.log("GamesFps: octree of " + this.world.children.length.toString() + " meshes built in "
                + (Math.round(this.buildSeconds * 10000) / 10).toString() + " ms");
        }

        const helper = new OctreeHelper(this.worldOctree);
        helper.visible = false;
        this.scene.add(helper);
        this.helper = helper;

        this.hudFill.style = PaintStyle.fill;
        this.hudStroke.style = PaintStyle.stroke;
        this.hudStroke.thickness = 2;

        this.trace = context.arg("fpsTrace") != null;
        this.context2 = context;

        this.teleport();
        return true;
    }

    // ------------------------------------------------------------ level

    box(w: f64, h: f64, d: f64, x: f64, y: f64, z: f64, color: u32): THREE.Mesh {
        const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d),
            new THREE.MeshStandardMaterial({ color: color, roughness: 0.85 }));
        m.position.set(x, y, z);
        m.castShadow = true;
        m.receiveShadow = true;
        this.world.add(m);
        return m;
    }

    pillar(x: f64, z: f64, h: f64, color: u32): void {
        const m = new THREE.Mesh(new THREE.CylinderGeometry(0.5, 0.6, h, 16),
            new THREE.MeshStandardMaterial({ color: color, roughness: 0.7 }));
        m.position.set(x, h / 2, z);
        m.castShadow = true;
        m.receiveShadow = true;
        this.world.add(m);
    }

    /// A ramp `w` wide from the ground at z0 up to height `rise` at z1
    /// (its top surface), at x.
    ramp(x: f64, z0: f64, z1: f64, rise: f64, w: f64, color: u32): void {
        const run = z1 - z0;
        const len = Math.sqrt(run * run + rise * rise);
        const angle = Math.atan2(rise, Math.abs(run));
        const thick: f64 = 0.3;
        const m = this.box(w, thick, len, x, 0, (z0 + z1) / 2, color);
        // Down towards +z when it rises towards -z.
        m.rotation.x = run < 0 ? angle : -angle;
        m.position.y = rise / 2 - thick / 2 / Math.cos(angle);
    }

    buildLevel(): void {
        const floorMap = floorTexture();
        floorMap.repeat.set(25, 25);
        const floor = new THREE.Mesh(new THREE.BoxGeometry(50, 1, 50),
            new THREE.MeshStandardMaterial({ color: 0xffffff, map: floorMap, roughness: 0.9 }));
        floor.position.y = -0.5;
        floor.receiveShadow = true;
        this.world.add(floor);

        // Walls around.
        const wall: u32 = 0xb8c4cc;
        this.box(52, 5, 1, 0, 2.5, -25.5, wall);
        this.box(52, 5, 1, 0, 2.5, 25.5, wall);
        this.box(1, 5, 50, -25.5, 2.5, 0, wall);
        this.box(1, 5, 50, 25.5, 2.5, 0, wall);

        // Stairs up to a block, ahead and left: ten 0.2 steps.
        for (let i = 0; i < 10; i++) {
            const h = 0.2 * <f64>(i + 1);
            this.box(4, h, 0.5, -8, h / 2, -4.25 - 0.5 * <f64>i, 0xd9a066);
        }
        this.box(6, 2, 6, -8, 1, -12, 0xc98b55);

        // A ramp up to a taller block, ahead and right.
        this.ramp(8, 1, -9, 3.5, 4, 0x8fae7b);
        this.box(6, 3.5, 6, 8, 1.75, -12, 0x7d9c6a);

        // A bridge between the blocks, rising from one to the other.
        const tilt = Math.atan2(1.5, 10);
        const bridge = this.box(10.4, 0.3, 2.2, 0, 0, -12, 0x9a8f86);
        bridge.rotation.z = tilt;
        bridge.position.y = 2.75 - 0.15 / Math.cos(tilt);

        // A tower at the back with a ledge.
        this.box(5, 6, 5, 0, 3, -21, 0xa98fb5);
        this.box(5, 0.4, 3, 0, 3.3, -17.3, 0x8f7a9b);

        // An arch to walk under.
        this.box(1, 2.6, 4, -14, 1.3, 6, 0xc7b79a);
        this.box(1, 2.6, 4, -10, 1.3, 6, 0xc7b79a);
        this.box(5, 0.6, 4, -12, 2.9, 6, 0xb3a385);

        // A low wall to jump over, and crates.
        this.box(8, 0.8, 0.5, 8, 0.4, 6, 0xb07a6a);
        const crate: u32 = 0xc9a15a;
        this.box(1.2, 1.2, 1.2, 4, 0.6, 12, crate).rotation.y = 0.4;
        this.box(1.2, 1.2, 1.2, 5.3, 0.6, 13, crate).rotation.y = -0.2;
        this.box(1.2, 1.2, 1.2, 4.6, 1.8, 12.6, crate).rotation.y = 0.9;
        this.box(2, 1, 2, -5, 0.5, 14, crate);
        this.box(1.5, 0.6, 1.5, -18, 0.3, -6, crate);
        this.box(1.5, 1.2, 1.5, -18, 0.6, -8, crate);
        this.box(1.5, 1.8, 1.5, -18, 0.9, -10, crate);

        // A slab sunk in the ground: a slope on each side.
        const hill = this.box(8, 2, 8, 16, -0.4, 16, 0x92ad86);
        hill.rotation.x = 0.18;
        hill.rotation.z = 0.12;

        // Pillars.
        this.pillar(-4, -16, 4, 0xd0d0c8);
        this.pillar(4, -16, 4, 0xd0d0c8);
        this.pillar(18, -4, 3, 0xd0d0c8);
        this.pillar(-20, 16, 5, 0xd0d0c8);
    }

    // ------------------------------------------------------------ input

    wake(): void {
        this.idle = false;
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        const down = event.phase != "up";
        const k = <i32>event.key;
        if (k == THREE.KEY_W || k == THREE.KEY_UP) this.keyForward = down;
        else if (k == THREE.KEY_S || k == THREE.KEY_DOWN) this.keyBackward = down;
        else if (k == THREE.KEY_A || k == THREE.KEY_LEFT) this.keyLeft = down;
        else if (k == THREE.KEY_D || k == THREE.KEY_RIGHT) this.keyRight = down;
        else if (k == THREE.KEY_SPACE) this.keyJump = down;
        else if (k == KEY_H) {
            if (event.phase == "down") this.debug = !this.debug;
        } else return false;
        this.wake();
        return true;
    }

    override gamepadEvent(event: GamepadEvent): bool {
        this.padMoveX = deadZone(<f64>event.axis(0));
        this.padMoveY = deadZone(<f64>event.axis(1));
        this.padLookX = deadZone(<f64>event.axis(2));
        this.padLookY = deadZone(<f64>event.axis(3));
        this.padJump = event.buttonPressed(0);
        const trigger = event.buttonPressed(7);
        if (trigger && !this.padThrow) this.mouseTime = this.time;
        if (!trigger && this.padThrow) this.throwBall();
        this.padThrow = trigger;
        this.wake();
        return true;
    }

    stickCenterX(): f64 { return STICK_INSET; }
    stickCenterY(): f64 { return this.height - STICK_INSET; }
    jumpCenterX(): f64 { return this.width - JUMP_INSET; }
    jumpCenterY(): f64 { return this.height - JUMP_INSET; }

    setStick(x: f64, y: f64): void {
        let dx = (x - this.stickCenterX()) / STICK_RADIUS;
        let dy = (y - this.stickCenterY()) / STICK_RADIUS;
        const l = Math.sqrt(dx * dx + dy * dy);
        if (l > 1) { dx /= l; dy /= l; }
        this.stickX = dx;
        this.stickY = dy;
    }

    override onPointerDown(event: PointerEvent): void {
        const x = <f64>event.position.x, y = <f64>event.position.y;
        if (!this.contains(x, y)) return;
        this.wake();
        event.hit();
        if (this.touchControls) {
            const sx = x - this.stickCenterX(), sy = y - this.stickCenterY();
            if (this.stickId < 0 && sx * sx + sy * sy < STICK_RADIUS * STICK_RADIUS * 1.7) {
                this.stickId = event.id;
                this.setStick(x, y);
                return;
            }
            const jx = x - this.jumpCenterX(), jy = y - this.jumpCenterY();
            if (jx * jx + jy * jy < JUMP_RADIUS * JUMP_RADIUS * 1.7) {
                this.jumpId = event.id;
                return;
            }
        }
        if (this.lookId < 0) {
            this.lookId = event.id;
            this.lookX = x;
            this.lookY = y;
            this.lookTravel = 0;
            this.mouseTime = this.time;
        }
    }

    override onPointerMove(event: PointerEvent): void {
        const x = <f64>event.position.x, y = <f64>event.position.y;
        if (event.id == this.stickId) {
            this.setStick(x, y);
            event.hit();
        } else if (event.id == this.lookId) {
            const dx = x - this.lookX, dy = y - this.lookY;
            this.lookX = x;
            this.lookY = y;
            this.lookTravel += Math.abs(dx) + Math.abs(dy);
            this.look(dx / 300, dy / 300);
            event.hit();
        }
    }

    override onPointerUp(event: PointerEvent): void {
        this.release(event.id, true);
        // Passed on (downs and moves stay claimed, so a drag never scrolls
        // the gallery page): the state machine's "Focus on release" listener
        // gives the Scene keyboard focus back after a click elsewhere.
        event.hit(true);
    }

    override pointerExit(event: PointerEvent): void {
        super.pointerExit(event);
        this.release(this.stickId, false);
        this.release(this.jumpId, false);
        this.release(this.lookId, false);
    }

    release(id: f64, canThrow: bool): void {
        if (id < 0) return;
        if (id == this.stickId) {
            this.stickId = -1;
            this.stickX = 0;
            this.stickY = 0;
        } else if (id == this.jumpId) {
            this.jumpId = -1;
        } else if (id == this.lookId) {
            this.lookId = -1;
            // A click (not a look drag) throws, harder the longer it was held.
            if (canThrow && this.lookTravel < 12) this.throwBall();
        }
    }

    look(dx: f64, dy: f64): void {
        const r = this.camera.rotation;
        r.y -= dx;
        r.x = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, r.x - dy));
    }

    // ------------------------------------------------------------ physics (three.js's)

    throwBall(): void {
        const sphere = this.spheres[this.sphereIdx];

        this.camera.getWorldDirection(this.playerDirection);

        sphere.collider.center.copy(this.playerCollider.end).addScaledVector(this.playerDirection, this.playerCollider.radius * 1.5);

        // throw the ball with more force if we hold the button longer, and if we move forward

        const impulse = 15 + 30 * (1 - Math.exp(this.mouseTime - this.time));

        sphere.velocity.copy(this.playerDirection).multiplyScalar(impulse);
        sphere.velocity.addScaledVector(this.playerVelocity, 2);

        this.sphereIdx = (this.sphereIdx + 1) % this.spheres.length;
    }

    playerCollisions(): void {
        const result = this.worldOctree.capsuleIntersect(this.playerCollider);

        this.playerOnFloor = false;

        if (result != null) {
            // determine if the surface we bumped into is something we can stand on
            this.playerOnFloor = result.normal.y >= 0.15; // allow slopes up to ~81° but ignore sheer vertical walls

            if (!this.playerOnFloor) {
                this.playerVelocity.addScaledVector(result.normal, -result.normal.dot(this.playerVelocity));
            }

            if (result.depth >= 1e-10) {
                this.playerCollider.translate(result.normal.multiplyScalar(result.depth));
            }
        }
    }

    updatePlayer(deltaTime: f64): void {
        let damping = Math.exp(-4 * deltaTime) - 1;

        if (!this.playerOnFloor) {
            this.playerVelocity.y -= GRAVITY * deltaTime;

            // small air resistance
            damping *= 0.1;
        }

        this.playerVelocity.addScaledVector(this.playerVelocity, damping);

        const deltaPosition = this.vector1.copy(this.playerVelocity).multiplyScalar(deltaTime);
        this.playerCollider.translate(deltaPosition);

        this.playerCollisions();

        this.camera.position.copy(this.playerCollider.end);
    }

    playerSphereCollision(sphere: SphereBody): void {
        const center = this.vector1.addVectors(this.playerCollider.start, this.playerCollider.end).multiplyScalar(0.5);
        const sphere_center = sphere.collider.center;

        const r = this.playerCollider.radius + sphere.collider.radius;
        const r2 = r * r;

        // approximation: player = 3 spheres

        for (let k = 0; k < 3; k++) {
            const point = k == 0 ? this.playerCollider.start : k == 1 ? this.playerCollider.end : center;
            const d2 = point.distanceToSquared(sphere_center);

            if (d2 < r2) {
                const normal = this.vector1.subVectors(point, sphere_center).normalize();
                const v1 = this.vector2.copy(normal).multiplyScalar(normal.dot(this.playerVelocity));
                const v2 = this.vector3.copy(normal).multiplyScalar(normal.dot(sphere.velocity));

                this.playerVelocity.add(v2).sub(v1);
                sphere.velocity.add(v1).sub(v2);

                const d = (r - Math.sqrt(d2)) / 2;
                sphere_center.addScaledVector(normal, -d);
            }
        }
    }

    spheresCollisions(): void {
        const spheres = this.spheres;
        for (let i = 0, length = spheres.length; i < length; i++) {
            const s1 = spheres[i];

            for (let j = i + 1; j < length; j++) {
                const s2 = spheres[j];

                const d2 = s1.collider.center.distanceToSquared(s2.collider.center);
                const r = s1.collider.radius + s2.collider.radius;
                const r2 = r * r;

                if (d2 < r2) {
                    const normal = this.vector1.subVectors(s1.collider.center, s2.collider.center).normalize();
                    const v1 = this.vector2.copy(normal).multiplyScalar(normal.dot(s1.velocity));
                    const v2 = this.vector3.copy(normal).multiplyScalar(normal.dot(s2.velocity));

                    s1.velocity.add(v2).sub(v1);
                    s2.velocity.add(v1).sub(v2);

                    const d = (r - Math.sqrt(d2)) / 2;

                    s1.collider.center.addScaledVector(normal, d);
                    s2.collider.center.addScaledVector(normal, -d);
                }
            }
        }
    }

    updateSpheres(deltaTime: f64): void {
        for (let i = 0; i < this.spheres.length; i++) {
            const sphere = this.spheres[i];
            sphere.collider.center.addScaledVector(sphere.velocity, deltaTime);

            const result = this.worldOctree.sphereIntersect(sphere.collider);

            if (result != null) {
                sphere.velocity.addScaledVector(result.normal, -result.normal.dot(sphere.velocity) * 1.5);
                sphere.collider.center.add(result.normal.multiplyScalar(result.depth));
            } else {
                sphere.velocity.y -= GRAVITY * deltaTime;
            }

            const damping = Math.exp(-1.5 * deltaTime) - 1;
            sphere.velocity.addScaledVector(sphere.velocity, damping);

            this.playerSphereCollision(sphere);
        }

        this.spheresCollisions();

        for (let i = 0; i < this.spheres.length; i++) {
            const sphere = this.spheres[i];
            sphere.mesh.position.copy(sphere.collider.center);
        }
    }

    getForwardVector(): THREE.Vector3 {
        this.camera.getWorldDirection(this.playerDirection);
        this.playerDirection.y = 0;
        this.playerDirection.normalize();

        return this.playerDirection;
    }

    getSideVector(): THREE.Vector3 {
        this.camera.getWorldDirection(this.playerDirection);
        this.playerDirection.y = 0;
        this.playerDirection.normalize();
        this.playerDirection.cross(this.camera.up);

        return this.playerDirection;
    }

    // three.js's controls() (ThreeLayout has a `controls` field).
    playerControls(deltaTime: f64): void {
        // gives a bit of air control
        const speedDelta = deltaTime * (this.playerOnFloor ? 25 : 8);

        // Keys, the on-screen stick and the pad, -1 to 1.
        let forward = (this.keyForward ? 1.0 : 0.0) - (this.keyBackward ? 1.0 : 0.0) - this.stickY - this.padMoveY;
        let side = (this.keyRight ? 1.0 : 0.0) - (this.keyLeft ? 1.0 : 0.0) + this.stickX + this.padMoveX;
        forward = Math.max(-1, Math.min(1, forward));
        side = Math.max(-1, Math.min(1, side));

        if (forward != 0) {
            this.playerVelocity.add(this.getForwardVector().multiplyScalar(speedDelta * forward));
        }

        if (side != 0) {
            this.playerVelocity.add(this.getSideVector().multiplyScalar(speedDelta * side));
        }

        if (this.playerOnFloor) {
            if (this.keyJump || this.jumpId >= 0 || this.padJump) {
                this.playerVelocity.y = 15;
            }
        }
    }

    teleport(): void {
        this.playerCollider.start.set(0, 0.35, 8);
        this.playerCollider.end.set(0, 1, 8);
        this.playerCollider.radius = 0.35;
        this.playerVelocity.set(0, 0, 0);
        this.camera.position.copy(this.playerCollider.end);
        this.camera.rotation.set(0, 0, 0);
    }

    teleportPlayerIfOob(): void {
        if (this.camera.position.y <= -25) this.teleport();
    }

    override animate(seconds: f64): void {
        this.time += seconds;
        const helper = this.helper;
        if (helper != null) helper.visible = this.debug;

        if (this.idle && this.autoplay) {
            // Look around slowly, throwing now and then.
            const r = this.camera.rotation;
            r.y = 0.6 * Math.sin(this.time * 0.35);
            r.x = -0.06 + 0.06 * Math.sin(this.time * 0.6);
            if (this.time >= this.nextThrow) {
                this.mouseTime = this.time - 0.15 - 0.4 * (0.5 + 0.5 * Math.sin(this.time * 2.3));
                this.throwBall();
                this.nextThrow = this.time + 0.35;
            }
        }
        if (this.padLookX != 0 || this.padLookY != 0) this.look(this.padLookX * 2.5 * seconds, this.padLookY * 2.5 * seconds);

        const deltaTime = Math.min(0.05, seconds) / <f64>STEPS_PER_FRAME;

        // we look for collisions in substeps to mitigate the risk of
        // an object traversing another too quickly for detection.

        for (let i = 0; i < STEPS_PER_FRAME; i++) {
            this.playerControls(deltaTime);

            this.updatePlayer(deltaTime);

            this.updateSpheres(deltaTime);

            this.teleportPlayerIfOob();
        }

        if (this.trace && this.time >= this.nextTrace) {
            this.nextTrace = this.time + 0.5;
            const p = this.playerCollider.start;
            let moving = 0;
            for (let i = 0; i < this.spheres.length; i++) {
                if (this.spheres[i].collider.center.y > -50 && this.spheres[i].velocity.length() > 0.5) moving++;
            }
            this.context2!.log("t " + fmt(this.time) + " player " + fmt(p.x) + " " + fmt(p.y) + " " + fmt(p.z)
                + (this.playerOnFloor ? " floor" : " air") + " v " + fmt(this.playerVelocity.length())
                + " yaw " + fmt(this.camera.rotation.y) + " spheres moving " + moving.toString());
        }
    }

    // ------------------------------------------------------------ on-screen controls

    override draw(renderer: Renderer): void {
        super.draw(renderer);
        const w = this.width, h = this.height;
        if (w <= 0 || h <= 0) return;
        const path = this.hudPath;
        const fill = this.hudFill, stroke = this.hudStroke;

        // Crosshair.
        path.reset();
        addCircle(path, w / 2, h / 2, 3);
        fill.color = Color.rgba(255, 255, 255, 200);
        renderer.drawPath(path, fill);

        if (!this.touchControls) return;

        // The stick: a ring and its knob.
        const cx = this.stickCenterX(), cy = this.stickCenterY();
        path.reset();
        addCircle(path, cx, cy, STICK_RADIUS);
        fill.color = Color.rgba(255, 255, 255, 40);
        renderer.drawPath(path, fill);
        stroke.color = Color.rgba(255, 255, 255, 140);
        renderer.drawPath(path, stroke);
        path.reset();
        addCircle(path, cx + this.stickX * STICK_RADIUS * 0.6, cy + this.stickY * STICK_RADIUS * 0.6, STICK_RADIUS * 0.42);
        fill.color = Color.rgba(255, 255, 255, this.stickId >= 0 ? 190 : 120);
        renderer.drawPath(path, fill);

        // The jump button: a ring with an up chevron.
        const jx = this.jumpCenterX(), jy = this.jumpCenterY();
        path.reset();
        addCircle(path, jx, jy, JUMP_RADIUS);
        fill.color = Color.rgba(255, 255, 255, this.jumpId >= 0 ? 110 : 40);
        renderer.drawPath(path, fill);
        renderer.drawPath(path, stroke);
        path.reset();
        path.moveTo(vxy(jx - 11, jy + 5));
        path.lineTo(vxy(jx, jy - 7));
        path.lineTo(vxy(jx + 11, jy + 5));
        stroke.thickness = 3;
        renderer.drawPath(path, stroke);
        stroke.thickness = 2;
    }
}

function fmt(v: f64): string {
    return (Math.round(v * 100) / 100).toString();
}

function deadZone(v: f64): f64 {
    return Math.abs(v) < 0.15 ? 0 : v;
}
