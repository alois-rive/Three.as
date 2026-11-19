// MarchingCubes (addons/objects): the field (balls, planes, cells, blur,
// reset), polygonization counts and attributes, the lookup tables.
// rive . --test

import { Expect, Tests } from "rive/test";
import { clock } from "rive/os";
import { MarchingCubes, edgeTable, triTable } from "../three/addons/objects/MarchingCubes";
import { MeshStandardMaterial } from "../three/materials/MeshStandardMaterial";
import { MeshPhongMaterial } from "../three/materials/MeshPhongMaterial";
import { Color } from "../three/math/Color";

@editTime
function near(expect: Expect, actual: f64, want: f64, eps: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(eps);
}

function make(resolution: i32, uvs: bool = false, colors: bool = false, maxPolyCount: i32 = 10000): MarchingCubes {
    return new MarchingCubes(resolution, new MeshStandardMaterial(), uvs, colors, maxPolyCount);
}

/// three.js's ball formula for one cell.
function ballValue(mc: MarchingCubes, x: i32, y: i32, z: i32, bx: f64, by: f64, bz: f64, strength: f64, subtract: f64): f64 {
    const s = <f64>mc.size;
    const fx = <f64>x / s - bx, fy = <f64>y / s - by, fz = <f64>z / s - bz;
    return strength / (0.000001 + fx * fx + fy * fy + fz * fz) - subtract;
}

function fieldSum(mc: MarchingCubes): f64 {
    let sum = 0.0;
    for (let i = 0; i < mc.field.length; i++) sum += <f64>mc.field[i];
    return sum;
}

function nonZero(a: Float32Array): i32 {
    let n = 0;
    for (let i = 0; i < a.length; i++) if (a[i] != 0) n++;
    return n;
}

/// Mirrors the field in x (cell x <-> size - 1 - x) into `target`.
function mirrorX(source: MarchingCubes, target: MarchingCubes): void {
    const s = source.size;
    for (let z = 0; z < s; z++) {
        for (let y = 0; y < s; y++) {
            for (let x = 0; x < s; x++) target.setCell(s - 1 - x, y, z, source.getCell(x, y, z));
        }
    }
}

export class MarchingCubesTests extends Tests {
    override run(): void {
        group("MarchingCubes init", () => {
            test("sizes and constants", (expect) => {
                const mc = make(10, true, true, 100);
                expect.that(mc.isMarchingCubes).is(true);
                expect.that(mc.isMesh).is(true);
                expect.that(mc.resolution).is(10);
                expect.that(mc.size).is(10);
                expect.that(mc.size2).is(100);
                expect.that(mc.size3).is(1000);
                expect.that(mc.halfsize).is(5.0);
                expect.that(mc.delta).is(0.2);
                expect.that(mc.yd).is(10);
                expect.that(mc.zd).is(100);
                expect.that(mc.isolation).is(80.0);
                expect.that(mc.field.length).is(1000);
                expect.that(mc.normal_cache.length).is(3000);
                expect.that(mc.palette.length).is(3000);
                expect.that(mc.positionArray.length).is(900);
                expect.that(mc.normalArray.length).is(900);
                expect.that(mc.uvArray.length).is(600);
                expect.that(mc.colorArray.length).is(900);
                expect.that(mc.geometry.getAttribute("position")!.array === mc.positionArray).is(true);
                expect.that(mc.geometry.getAttribute("uv")!.itemSize).is(2);
                expect.that(mc.geometry.getAttribute("color") != null).is(true);
                const bs = mc.geometry.boundingSphere!;
                expect.that(bs.radius).is(1.0);
                expect.that(bs.center.length()).is(0.0);
            });
            test("no uv or colour attributes unless enabled", (expect) => {
                const mc = make(8);
                expect.that(mc.geometry.getAttribute("uv") == null).is(true);
                expect.that(mc.geometry.getAttribute("color") == null).is(true);
                expect.that(mc.uvArray.length).is(0);
            });
            test("odd resolution: halfsize is a float", (expect) => {
                const mc = make(7);
                expect.that(mc.halfsize).is(3.5);
                near(expect, mc.delta, 2.0 / 7.0, 1e-15);
            });
            test("init re-sizes", (expect) => {
                const mc = make(8);
                mc.isolation = 20;
                mc.init(12);
                expect.that(mc.size3).is(1728);
                expect.that(mc.field.length).is(1728);
                expect.that(mc.isolation).is(80.0);
            });
        });

        group("MarchingCubes field", () => {
            test("addBall matches the formula", (expect) => {
                const mc = make(20);
                mc.addBall(0.5, 0.4, 0.6, 0.5, 12);
                // cells inside the ball's radius (sqrt(0.5 / 12) * 20 = 4.08)
                near(expect, mc.getCell(10, 8, 12), ballValue(mc, 10, 8, 12, 0.5, 0.4, 0.6, 0.5, 12), 1e-3);
                near(expect, mc.getCell(11, 9, 11), ballValue(mc, 11, 9, 11, 0.5, 0.4, 0.6, 0.5, 12), 1e-4);
                near(expect, mc.getCell(8, 7, 13), ballValue(mc, 8, 7, 13, 0.5, 0.4, 0.6, 0.5, 12), 1e-4);
                // the centre is huge (1 / 0.000001)
                expect.that(mc.getCell(10, 8, 12)).greaterThan(1e5);
                // outside the radius: untouched
                expect.that(mc.getCell(2, 2, 2)).is(0.0);
                expect.that(mc.getCell(10, 8, 18)).is(0.0);
            });
            test("addBall accumulates and a negative strength subtracts", (expect) => {
                const mc = make(20);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12);
                const one = mc.getCell(11, 10, 10);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12);
                near(expect, mc.getCell(11, 10, 10), 2 * one, 1e-3);
                mc.addBall(0.5, 0.5, 0.5, -0.5, 12);
                near(expect, mc.getCell(11, 10, 10), one, 1e-3);
            });
            test("addBall stays off the outer layer", (expect) => {
                const mc = make(10);
                mc.addBall(0.0, 0.0, 0.0, 1.0, 1.0);
                expect.that(mc.getCell(0, 0, 0)).is(0.0);
                expect.that(mc.getCell(0, 1, 1)).is(0.0);
                expect.that(mc.getCell(1, 1, 1)).greaterThan(0.0);
                expect.that(mc.getCell(9, 1, 1)).is(0.0);
            });
            test("addBall colours the palette", (expect) => {
                const mc = make(20, false, true);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12, new Color(1, 0, 0));
                const i = (10 * 400 + 10 * 20 + 10) * 3;
                // at the centre the contribution is 1
                near(expect, mc.palette[i], 1.0, 1e-6);
                expect.that(mc.palette[i + 1]).is(0.0);
                expect.that(mc.palette[i + 2]).is(0.0);
                // default colour: (ballx, bally, ballz)
                const mc2 = make(20, false, true);
                mc2.addBall(0.5, 0.25, 0.75, 0.5, 12);
                const j = (15 * 400 + 5 * 20 + 10) * 3;
                near(expect, mc2.palette[j], 0.5, 1e-6);
                near(expect, mc2.palette[j + 1], 0.25, 1e-6);
                near(expect, mc2.palette[j + 2], 0.75, 1e-6);
                // smoothstep falloff
                const k = (15 * 400 + 5 * 20 + 12) * 3;
                const ratio = 2.0 / (20 * Math.sqrt(0.5 / 12));
                const contrib = 1 - ratio * ratio * ratio * (ratio * (ratio * 6 - 15) + 10);
                near(expect, mc2.palette[k], 0.5 * contrib, 1e-6);
            });
            test("addPlaneX/Y/Z", (expect) => {
                const val0 = 2.0 / 0.0001 - 12;
                const val1 = 2.0 / (0.0001 + 0.01) - 12;
                const mcx = make(10);
                mcx.addPlaneX(2, 12);
                near(expect, mcx.getCell(0, 3, 7), val0, 1e-2);
                near(expect, mcx.getCell(1, 9, 0), val1, 1e-3);
                // dist = 10 * sqrt(2 / 12) = 4.08: x = 4 gives 2 / 0.1601 - 12 > 0
                near(expect, mcx.getCell(4, 5, 5), 2.0 / (0.0001 + 0.16) - 12, 1e-4);
                expect.that(mcx.getCell(5, 5, 5)).is(0.0);
                const mcy = make(10);
                mcy.addPlaneY(2, 12);
                near(expect, mcy.getCell(3, 1, 7), val1, 1e-3);
                expect.that(mcy.getCell(3, 5, 7)).is(0.0);
                const mcz = make(10);
                mcz.addPlaneZ(2, 12);
                near(expect, mcz.getCell(3, 7, 1), val1, 1e-3);
                near(expect, mcz.getCell(9, 9, 0), val0, 1e-2);
                expect.that(mcz.getCell(3, 7, 6)).is(0.0);
                // each plane covers a full slab: the same total
                near(expect, fieldSum(mcx), fieldSum(mcy), 1.0);
                near(expect, fieldSum(mcy), fieldSum(mcz), 1.0);
            });
            test("setCell / getCell", (expect) => {
                const mc = make(8);
                mc.setCell(1, 2, 3, 42.5);
                expect.that(mc.getCell(1, 2, 3)).is(42.5);
                expect.that(mc.field[3 * 64 + 2 * 8 + 1]).is(<f32>42.5);
                expect.that(mc.getCell(3, 2, 1)).is(0.0);
            });
            test("reset clears the field, palette and normal cache", (expect) => {
                const mc = make(12, false, true);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12);
                mc.addPlaneY(2, 12);
                mc.update();
                expect.that(nonZero(mc.field)).greaterThan(0);
                expect.that(nonZero(mc.palette)).greaterThan(0);
                expect.that(nonZero(mc.normal_cache)).greaterThan(0);
                mc.reset();
                expect.that(nonZero(mc.field)).is(0);
                expect.that(nonZero(mc.palette)).is(0);
                // three.js wipes the cache's x components (the "computed" flag)
                let flags = 0;
                for (let i = 0; i < mc.size3; i++) if (mc.normal_cache[i * 3] != 0) flags++;
                expect.that(flags).is(0);
                mc.update();
                expect.that(mc.count).is(0);
            });
            test("blur keeps a uniform field", (expect) => {
                const mc = make(8);
                for (let i = 0; i < mc.size3; i++) mc.field[i] = 5;
                mc.blur();
                let off = 0;
                for (let i = 0; i < mc.size3; i++) if (Math.abs(<f64>mc.field[i] - 5) > 1e-5) off++;
                expect.that(off).is(0);
            });
            test("blur smooths a spike", (expect) => {
                const mc = make(8);
                mc.setCell(4, 4, 4, 90);
                mc.blur();
                // the spike (index 1 of 9 samples, intensity 1) becomes the
                // running mean: 90 / 9
                near(expect, mc.getCell(4, 4, 4), 10.0, 1e-4);
                // diagonal neighbours pick it up, face neighbours do not
                expect.that(mc.getCell(5, 5, 5)).greaterThan(0.0);
                expect.that(mc.getCell(3, 3, 3)).greaterThan(0.0);
                expect.that(mc.getCell(5, 4, 4)).is(0.0);
                // the mean is kept
                near(expect, fieldSum(mc), 90.0, 1e-3);
                // intensity 0: no change
                const mc2 = make(8);
                mc2.setCell(4, 4, 4, 90);
                mc2.blur(0);
                expect.that(mc2.getCell(4, 4, 4)).is(90.0);
            });
        });

        group("MarchingCubes polygonize", () => {
            test("an empty field gives no triangles", (expect) => {
                const mc = make(16);
                mc.update();
                expect.that(mc.count).is(0);
                expect.that(mc.geometry.drawRange.count).is(0);
            });
            test("one ball: a closed blob", (expect) => {
                const mc = make(28);
                const version = mc.geometry.getAttribute("position")!.version;
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12);
                mc.update();
                expect.that(mc.count).greaterThan(0);
                expect.that(mc.count % 3).is(0);
                expect.that(mc.geometry.drawRange.count).is(mc.count);
                expect.that(mc.geometry.drawRange.start).is(0);
                expect.that(mc.geometry.getAttribute("position")!.version).greaterThan(version);
                // positions in [-1, 1], unit-ish outward normals
                let outside = 0, inward = 0;
                for (let v = 0; v < mc.count; v++) {
                    const x: f64 = mc.positionArray[v * 3], y: f64 = mc.positionArray[v * 3 + 1],
                        z: f64 = mc.positionArray[v * 3 + 2];
                    if (Math.abs(x) > 1 || Math.abs(y) > 1 || Math.abs(z) > 1) outside++;
                    const d = x * <f64>mc.normalArray[v * 3] + y * <f64>mc.normalArray[v * 3 + 1]
                        + z * <f64>mc.normalArray[v * 3 + 2];
                    if (d <= 0) inward++;
                }
                expect.that(outside).is(0);
                expect.that(inward).is(0);
                // the same count again (the normal cache does not change it)
                const first = mc.count;
                mc.update();
                expect.that(mc.count).is(first);
            });
            test("a mirrored field gives the same count", (expect) => {
                const a = make(20);
                a.addBall(0.3, 0.45, 0.5, 0.4, 12);
                a.addBall(0.6, 0.55, 0.4, 0.3, 12);
                a.update();
                const b = make(20);
                mirrorX(a, b);
                b.update();
                // update()'s cubes span cells 1 .. size - 2, which x -> size - 1 - x
                // maps onto itself
                expect.that(a.count).greaterThan(0);
                expect.that(b.count).is(a.count);
            });
            test("uvs are position.xz", (expect) => {
                const mc = make(16, true, false);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12);
                mc.update();
                expect.that(mc.count).greaterThan(0);
                let bad = 0;
                for (let v = 0; v < mc.count; v++) {
                    if (mc.uvArray[v * 2] != mc.positionArray[v * 3]) bad++;
                    if (mc.uvArray[v * 2 + 1] != mc.positionArray[v * 3 + 2]) bad++;
                }
                expect.that(bad).is(0);
            });
            test("colours are filled", (expect) => {
                const mc = make(16, false, true);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12, new Color(0, 1, 0));
                mc.update();
                expect.that(mc.count).greaterThan(0);
                let red = 0, green = 0;
                for (let v = 0; v < mc.count; v++) {
                    if (mc.colorArray[v * 3] != 0) red++;
                    if (mc.colorArray[v * 3 + 1] > 0) green++;
                }
                expect.that(red).is(0);
                expect.that(green).is(mc.count);
            });
            test("flat shading: one normal a triangle", (expect) => {
                const material = new MeshPhongMaterial();
                material.flatShading = true;
                const mc = new MarchingCubes(16, material);
                mc.addBall(0.5, 0.5, 0.5, 0.5, 12);
                mc.update();
                let bad = 0;
                for (let t = 0; t < mc.count; t += 3) {
                    for (let k = 0; k < 3; k++) {
                        if (mc.normalArray[t * 3 + k] != mc.normalArray[t * 3 + 3 + k]) bad++;
                        if (mc.normalArray[t * 3 + k] != mc.normalArray[t * 3 + 6 + k]) bad++;
                    }
                }
                expect.that(mc.count).greaterThan(0);
                expect.that(bad).is(0);
            });
            test("overflow past maxPolyCount is counted, not written", (expect) => {
                const big = make(20);
                big.addBall(0.5, 0.5, 0.5, 0.5, 12);
                big.update();
                const small = make(20, false, false, 10);
                small.addBall(0.5, 0.5, 0.5, 0.5, 12);
                small.update();
                expect.that(small.count).is(big.count);
                expect.that(small.positionArray.length).is(90);
                expect.that(small.positionArray[89]).is(big.positionArray[89]);
            });
            test("timing: resolution 28, 10 balls", (expect) => {
                const mc = make(28, true, true, 100000);
                const frames = 20;
                let ballTime = 0.0, updateTime = 0.0;
                for (let f = 0; f < frames; f++) {
                    const time = <f64>f * 0.1;
                    const t0 = clock();
                    mc.reset();
                    for (let i = 0; i < 10; i++) {
                        const fi = <f64>i;
                        const bx = Math.sin(fi + 1.26 * time * (1.03 + 0.5 * Math.cos(0.21 * fi))) * 0.27 + 0.5;
                        const by = Math.abs(Math.cos(fi + 1.12 * time * Math.cos(1.22 + 0.1424 * fi))) * 0.77;
                        const bz = Math.cos(fi + 1.32 * time * 0.1 * Math.sin(0.92 + 0.53 * fi)) * 0.27 + 0.5;
                        mc.addBall(bx, by, bz, 1.2 / (0.5 + 10 * 0.12), 12);
                    }
                    mc.addPlaneY(2, 12);
                    const t1 = clock();
                    mc.update();
                    const t2 = clock();
                    ballTime += t1 - t0;
                    updateTime += t2 - t1;
                }
                console.log("MarchingCubes res 28, 10 balls + floor: field " + (ballTime / <f64>frames * 1000).toString()
                    + " ms, update " + (updateTime / <f64>frames * 1000).toString() + " ms, "
                    + (mc.count / 3).toString() + " triangles");
                expect.that(mc.count).greaterThan(0);
            });
        });

        group("MarchingCubes tables", () => {
            test("sizes", (expect) => {
                expect.that(edgeTable.length).is(256);
                expect.that(triTable.length).is(4096);
            });
            test("known entries", (expect) => {
                expect.that(edgeTable[0]).is(0);
                expect.that(edgeTable[1]).is(0x109);
                expect.that(edgeTable[2]).is(0x203);
                expect.that(edgeTable[255]).is(0);
                expect.that(edgeTable[128]).is(0x8c0);
                expect.that(triTable[0]).is(-1);
                expect.that(triTable[16]).is(0);
                expect.that(triTable[17]).is(8);
                expect.that(triTable[18]).is(3);
                expect.that(triTable[19]).is(-1);
                expect.that(triTable[4095]).is(-1);
                expect.that(triTable[254 * 16]).is(0);
                expect.that(triTable[254 * 16 + 1]).is(3);
                expect.that(triTable[254 * 16 + 2]).is(8);
            });
            test("every edge a triangle uses is in the edge mask", (expect) => {
                let bad = 0;
                for (let c = 0; c < 256; c++) {
                    for (let i = 0; i < 16 && triTable[c * 16 + i] != -1; i++) {
                        if ((edgeTable[c] & (1 << triTable[c * 16 + i])) == 0) bad++;
                    }
                }
                expect.that(bad).is(0);
            });
        });
    }
}
