// Earcut polygon triangulation (mapbox/earcut, ISC), as three.js's
// Earcut.triangulate: `data` is flat x, y (dim 2) coordinates, outer ring
// first then each hole from holeIndices[i]; returns vertex index triples.

class Node {
    i: i32;
    x: f64;
    y: f64;
    prev: Node;
    next: Node;
    z: i32 = 0;
    prevZ: Node? = null;
    nextZ: Node? = null;
    steiner: bool = false;

    constructor(i: i32, x: f64, y: f64) {
        this.i = i;
        this.x = x;
        this.y = y;
        this.prev = this;
        this.next = this;
    }
}

export class Earcut {
    static triangulate(data: Array<f64>, holeIndices: Array<i32> = [], dim: i32 = 2): Array<i32> {
        const hasHoles = holeIndices.length > 0;
        const outerLen = hasHoles ? holeIndices[0] * dim : data.length;
        let outerNode = linkedList(data, 0, outerLen, dim, true);
        const triangles: Array<i32> = [];
        if (outerNode == null || outerNode.next === outerNode.prev) return triangles;
        if (hasHoles) outerNode = eliminateHoles(data, holeIndices, outerNode, dim);
        let minX: f64 = 0, minY: f64 = 0, invSize: f64 = 0;
        if (data.length > 80 * dim) {
            minX = Infinity; minY = Infinity;
            let maxX = -Infinity, maxY = -Infinity;
            for (let i = 0; i < outerLen; i += dim) {
                const x = data[i], y = data[i + 1];
                if (x < minX) minX = x;
                if (y < minY) minY = y;
                if (x > maxX) maxX = x;
                if (y > maxY) maxY = y;
            }
            invSize = Math.max(maxX - minX, maxY - minY);
            invSize = invSize != 0 ? 32767 / invSize : 0;
        }
        earcutLinked(outerNode, triangles, dim, minX, minY, invSize, 0);
        return triangles;
    }
}

function linkedList(data: Array<f64>, start: i32, end: i32, dim: i32, clockwise: bool): Node? {
    let last: Node? = null;
    if (clockwise == (signedArea(data, start, end, dim) > 0)) {
        for (let i = start; i < end; i += dim) last = insertNode(i, data[i], data[i + 1], last);
    } else {
        for (let i = end - dim; i >= start; i -= dim) last = insertNode(i, data[i], data[i + 1], last);
    }
    if (last != null && equals(last, last.next)) {
        removeNode(last);
        last = last.next;
    }
    return last;
}

function filterPoints(start: Node?, end: Node? = null): Node? {
    if (start == null) return start;
    let e: Node = end != null ? end : start;
    let p: Node = start;
    let again: bool;
    do {
        again = false;
        if (!p.steiner && (equals(p, p.next) || area(p.prev, p, p.next) == 0)) {
            removeNode(p);
            p = e = p.prev;
            if (p === p.next) break;
            again = true;
        } else {
            p = p.next;
        }
    } while (again || p !== e);
    return e;
}

function earcutLinked(earIn: Node?, triangles: Array<i32>, dim: i32, minX: f64, minY: f64, invSize: f64,
                      pass: i32): void {
    if (earIn == null) return;
    let ear: Node = earIn;
    if (pass == 0 && invSize != 0) indexCurve(ear, minX, minY, invSize);
    let stop = ear;
    while (ear.prev !== ear.next) {
        const prev = ear.prev, next = ear.next;
        if (invSize != 0 ? isEarHashed(ear, minX, minY, invSize) : isEar(ear)) {
            triangles.push(prev.i / dim);
            triangles.push(ear.i / dim);
            triangles.push(next.i / dim);
            removeNode(ear);
            ear = next.next;
            stop = next.next;
            continue;
        }
        ear = next;
        if (ear === stop) {
            if (pass == 0) {
                earcutLinked(filterPoints(ear), triangles, dim, minX, minY, invSize, 1);
            } else if (pass == 1) {
                const cured = cureLocalIntersections(filterPoints(ear), triangles, dim);
                earcutLinked(cured, triangles, dim, minX, minY, invSize, 2);
            } else if (pass == 2) {
                splitEarcut(ear, triangles, dim, minX, minY, invSize);
            }
            break;
        }
    }
}

function isEar(ear: Node): bool {
    const a = ear.prev, b = ear, c = ear.next;
    if (area(a, b, c) >= 0) return false;
    const ax = a.x, bx = b.x, cx = c.x, ay = a.y, by = b.y, cy = c.y;
    const x0 = Math.min(ax, Math.min(bx, cx)), y0 = Math.min(ay, Math.min(by, cy));
    const x1 = Math.max(ax, Math.max(bx, cx)), y1 = Math.max(ay, Math.max(by, cy));
    let p = c.next;
    while (p !== a) {
        if (p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1
                && pointInTriangle(ax, ay, bx, by, cx, cy, p.x, p.y) && area(p.prev, p, p.next) >= 0) return false;
        p = p.next;
    }
    return true;
}

function isEarHashed(ear: Node, minX: f64, minY: f64, invSize: f64): bool {
    const a = ear.prev, b = ear, c = ear.next;
    if (area(a, b, c) >= 0) return false;
    const ax = a.x, bx = b.x, cx = c.x, ay = a.y, by = b.y, cy = c.y;
    const x0 = Math.min(ax, Math.min(bx, cx)), y0 = Math.min(ay, Math.min(by, cy));
    const x1 = Math.max(ax, Math.max(bx, cx)), y1 = Math.max(ay, Math.max(by, cy));
    const minZ = zOrder(x0, y0, minX, minY, invSize), maxZ = zOrder(x1, y1, minX, minY, invSize);
    let p = ear.prevZ, n = ear.nextZ;
    while (p != null && p.z >= minZ && n != null && n.z <= maxZ) {
        if (p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 && p !== a && p !== c
                && pointInTriangle(ax, ay, bx, by, cx, cy, p.x, p.y) && area(p.prev, p, p.next) >= 0) return false;
        p = p.prevZ;
        if (n.x >= x0 && n.x <= x1 && n.y >= y0 && n.y <= y1 && n !== a && n !== c
                && pointInTriangle(ax, ay, bx, by, cx, cy, n.x, n.y) && area(n.prev, n, n.next) >= 0) return false;
        n = n.nextZ;
    }
    while (p != null && p.z >= minZ) {
        if (p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 && p !== a && p !== c
                && pointInTriangle(ax, ay, bx, by, cx, cy, p.x, p.y) && area(p.prev, p, p.next) >= 0) return false;
        p = p.prevZ;
    }
    while (n != null && n.z <= maxZ) {
        if (n.x >= x0 && n.x <= x1 && n.y >= y0 && n.y <= y1 && n !== a && n !== c
                && pointInTriangle(ax, ay, bx, by, cx, cy, n.x, n.y) && area(n.prev, n, n.next) >= 0) return false;
        n = n.nextZ;
    }
    return true;
}

function cureLocalIntersections(startIn: Node?, triangles: Array<i32>, dim: i32): Node? {
    if (startIn == null) return null;
    let start: Node = startIn;
    let p: Node = start;
    do {
        const a = p.prev, b = p.next.next;
        if (!equals(a, b) && intersects(a, p, p.next, b) && locallyInside(a, b) && locallyInside(b, a)) {
            triangles.push(a.i / dim);
            triangles.push(p.i / dim);
            triangles.push(b.i / dim);
            removeNode(p);
            removeNode(p.next);
            p = start = b;
        }
        p = p.next;
    } while (p !== start);
    return filterPoints(p);
}

function splitEarcut(start: Node, triangles: Array<i32>, dim: i32, minX: f64, minY: f64, invSize: f64): void {
    let a = start;
    do {
        let b = a.next.next;
        while (b !== a.prev) {
            if (a.i != b.i && isValidDiagonal(a, b)) {
                let c: Node? = splitPolygon(a, b);
                const fa = filterPoints(a, a.next);
                c = filterPoints(c, c!.next);
                earcutLinked(fa, triangles, dim, minX, minY, invSize, 0);
                earcutLinked(c, triangles, dim, minX, minY, invSize, 0);
                return;
            }
            b = b.next;
        }
        a = a.next;
    } while (a !== start);
}

function eliminateHoles(data: Array<f64>, holeIndices: Array<i32>, outerNodeIn: Node, dim: i32): Node {
    const queue: Array<Node> = [];
    const len = holeIndices.length;
    for (let i = 0; i < len; i++) {
        const start = holeIndices[i] * dim;
        const end = i < len - 1 ? holeIndices[i + 1] * dim : data.length;
        const list = linkedList(data, start, end, dim, false);
        if (list == null) continue;
        if (list === list.next) list.steiner = true;
        queue.push(getLeftmost(list));
    }
    queue.sort((a: Node, b: Node): i32 => (a.x < b.x ? -1 : a.x > b.x ? 1 : 0));
    let outerNode = outerNodeIn;
    for (let i = 0; i < queue.length; i++) outerNode = eliminateHole(queue[i], outerNode);
    return outerNode;
}

function eliminateHole(hole: Node, outerNode: Node): Node {
    const bridge = findHoleBridge(hole, outerNode);
    if (bridge == null) return outerNode;
    const bridgeReverse = splitPolygon(bridge, hole);
    filterPoints(bridgeReverse, bridgeReverse.next);
    const r = filterPoints(bridge, bridge.next);
    return r != null ? r : outerNode;
}

function findHoleBridge(hole: Node, outerNode: Node): Node? {
    let p = outerNode;
    let qx = -Infinity;
    let m: Node? = null;
    const hx = hole.x, hy = hole.y;
    do {
        if (hy <= p.y && hy >= p.next.y && p.next.y != p.y) {
            const x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y);
            if (x <= hx && x > qx) {
                qx = x;
                m = p.x < p.next.x ? p : p.next;
                if (x == hx) return m;
            }
        }
        p = p.next;
    } while (p !== outerNode);
    if (m == null) return null;
    let best: Node = m;
    const stop = best, mx = best.x, my = best.y;
    let tanMin = Infinity;
    p = best;
    do {
        if (hx >= p.x && p.x >= mx && hx != p.x
                && pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, p.x, p.y)) {
            const tan = Math.abs(hy - p.y) / (hx - p.x);
            if (locallyInside(p, hole) && (tan < tanMin || (tan == tanMin
                    && (p.x > best.x || (p.x == best.x && sectorContainsSector(best, p)))))) {
                best = p;
                tanMin = tan;
            }
        }
        p = p.next;
    } while (p !== stop);
    return best;
}

function sectorContainsSector(m: Node, p: Node): bool {
    return area(m.prev, m, p.prev) < 0 && area(p.next, m, m.next) < 0;
}

function indexCurve(start: Node, minX: f64, minY: f64, invSize: f64): void {
    let p = start;
    do {
        if (p.z == 0) p.z = zOrder(p.x, p.y, minX, minY, invSize);
        p.prevZ = p.prev;
        p.nextZ = p.next;
        p = p.next;
    } while (p !== start);
    const pz = p.prevZ!;
    pz.nextZ = null;
    p.prevZ = null;
    sortLinked(p);
}

function sortLinked(listIn: Node): Node? {
    let list: Node? = listIn;
    let inSize = 1;
    let numMerges: i32;
    do {
        let p = list;
        list = null;
        let tail: Node? = null;
        numMerges = 0;
        while (p != null) {
            numMerges++;
            let q: Node? = p;
            let pSize = 0;
            for (let i = 0; i < inSize; i++) {
                pSize++;
                q = q!.nextZ;
                if (q == null) break;
            }
            let qSize = inSize;
            while (pSize > 0 || (qSize > 0 && q != null)) {
                let e: Node;
                if (pSize != 0 && (qSize == 0 || q == null || p!.z <= q.z)) {
                    e = p!;
                    p = p!.nextZ;
                    pSize--;
                } else {
                    e = q!;
                    q = q!.nextZ;
                    qSize--;
                }
                if (tail != null) tail.nextZ = e;
                else list = e;
                e.prevZ = tail;
                tail = e;
            }
            p = q;
        }
        if (tail != null) tail.nextZ = null;
        inSize *= 2;
    } while (numMerges > 1);
    return list;
}

function zOrder(xIn: f64, yIn: f64, minX: f64, minY: f64, invSize: f64): i32 {
    let x = <i32>((xIn - minX) * invSize);
    let y = <i32>((yIn - minY) * invSize);
    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;
    y = (y | (y << 8)) & 0x00FF00FF;
    y = (y | (y << 4)) & 0x0F0F0F0F;
    y = (y | (y << 2)) & 0x33333333;
    y = (y | (y << 1)) & 0x55555555;
    return x | (y << 1);
}

function getLeftmost(start: Node): Node {
    let p = start, leftmost = start;
    do {
        if (p.x < leftmost.x || (p.x == leftmost.x && p.y < leftmost.y)) leftmost = p;
        p = p.next;
    } while (p !== start);
    return leftmost;
}

function pointInTriangle(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, px: f64, py: f64): bool {
    return (cx - px) * (ay - py) >= (ax - px) * (cy - py)
        && (ax - px) * (by - py) >= (bx - px) * (ay - py)
        && (bx - px) * (cy - py) >= (cx - px) * (by - py);
}

function isValidDiagonal(a: Node, b: Node): bool {
    return a.next.i != b.i && a.prev.i != b.i && !intersectsPolygon(a, b)
        && ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
            && (area(a.prev, a, b.prev) != 0 || area(a, b.prev, b) != 0))
            || (equals(a, b) && area(a.prev, a, a.next) > 0 && area(b.prev, b, b.next) > 0));
}

function area(p: Node, q: Node, r: Node): f64 {
    return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
}

function equals(p1: Node, p2: Node): bool {
    return p1.x == p2.x && p1.y == p2.y;
}

function intersects(p1: Node, q1: Node, p2: Node, q2: Node): bool {
    const o1 = sign(area(p1, q1, p2));
    const o2 = sign(area(p1, q1, q2));
    const o3 = sign(area(p2, q2, p1));
    const o4 = sign(area(p2, q2, q1));
    if (o1 != o2 && o3 != o4) return true;
    if (o1 == 0 && onSegment(p1, p2, q1)) return true;
    if (o2 == 0 && onSegment(p1, q2, q1)) return true;
    if (o3 == 0 && onSegment(p2, p1, q2)) return true;
    if (o4 == 0 && onSegment(p2, q1, q2)) return true;
    return false;
}

function onSegment(p: Node, q: Node, r: Node): bool {
    return q.x <= Math.max(p.x, r.x) && q.x >= Math.min(p.x, r.x) && q.y <= Math.max(p.y, r.y) && q.y >= Math.min(p.y, r.y);
}

function sign(num: f64): i32 {
    return num > 0 ? 1 : num < 0 ? -1 : 0;
}

function intersectsPolygon(a: Node, b: Node): bool {
    let p = a;
    do {
        if (p.i != a.i && p.next.i != a.i && p.i != b.i && p.next.i != b.i && intersects(p, p.next, a, b)) return true;
        p = p.next;
    } while (p !== a);
    return false;
}

function locallyInside(a: Node, b: Node): bool {
    return area(a.prev, a, a.next) < 0
        ? area(a, b, a.next) >= 0 && area(a, a.prev, b) >= 0
        : area(a, b, a.prev) < 0 || area(a, a.next, b) < 0;
}

function middleInside(a: Node, b: Node): bool {
    let p = a;
    let inside = false;
    const px = (a.x + b.x) / 2, py = (a.y + b.y) / 2;
    do {
        if (((p.y > py) != (p.next.y > py)) && p.next.y != p.y
                && (px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x)) inside = !inside;
        p = p.next;
    } while (p !== a);
    return inside;
}

function splitPolygon(a: Node, b: Node): Node {
    const a2 = new Node(a.i, a.x, a.y), b2 = new Node(b.i, b.x, b.y);
    const an = a.next, bp = b.prev;
    a.next = b; b.prev = a;
    a2.next = an; an.prev = a2;
    b2.next = a2; a2.prev = b2;
    bp.next = b2; b2.prev = bp;
    return b2;
}

function insertNode(i: i32, x: f64, y: f64, last: Node?): Node {
    const p = new Node(i, x, y);
    if (last != null) {
        p.next = last.next;
        p.prev = last;
        last.next.prev = p;
        last.next = p;
    }
    return p;
}

function removeNode(p: Node): void {
    p.next.prev = p.prev;
    p.prev.next = p.next;
    const pz = p.prevZ, nz = p.nextZ;
    if (pz != null) pz.nextZ = nz;
    if (nz != null) nz.prevZ = pz;
}

function signedArea(data: Array<f64>, start: i32, end: i32, dim: i32): f64 {
    let sum: f64 = 0;
    for (let i = start, j = end - dim; i < end; i += dim) {
        sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1]);
        j = i;
    }
    return sum;
}
