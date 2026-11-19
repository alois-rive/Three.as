// three.js examples/jsm/helpers/PositionalAudioHelper.js: a PositionalAudio's
// sound cone in its XZ plane, `range` long: the inner cone in green, the
// rest of the outer cone in yellow. Add it to the audio
// (`sound.add(helper)`) and call `update()` after changing the cone.
//
// Lines take one material here (no geometry groups on lines), so the helper
// is a Line drawing the inner cone with `material` (three.js's
// `material[1]`) and holds a child Line, `outer`, drawing the outer cone's
// two sides with `materialOuterAngle` (three.js's `material[0]`).

import { Line } from "../../objects/Line";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute } from "../../core/BufferAttribute";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { MathUtils } from "../../math/MathUtils";
import { PositionalAudio } from "../../audio/PositionalAudio";

export class PositionalAudioHelper extends Line {
    audio: PositionalAudio;
    range: f64;
    divisionsInnerAngle: i32;
    divisionsOuterAngle: i32;
    materialInnerAngle: LineBasicMaterial;
    materialOuterAngle: LineBasicMaterial;
    /// The outer cone's sides.
    outer: Line;

    constructor(audio: PositionalAudio, range: f64 = 1, divisionsInnerAngle: i32 = 16, divisionsOuterAngle: i32 = 2) {
        const inner = new BufferGeometry();
        inner.setAttribute("position", new BufferAttribute(new Float32Array((divisionsInnerAngle * 3 + 1) * 3), 3));
        const materialInnerAngle = new LineBasicMaterial({ color: 0x00ff00 });
        super(inner, materialInnerAngle);
        const outerGeometry = new BufferGeometry();
        outerGeometry.setAttribute("position", new BufferAttribute(new Float32Array((divisionsOuterAngle * 6 + 2) * 3), 3));
        this.materialInnerAngle = materialInnerAngle;
        this.materialOuterAngle = new LineBasicMaterial({ color: 0xffff00 });
        this.outer = new Line(outerGeometry, this.materialOuterAngle);
        this.outer.name = "PositionalAudioHelperOuter";
        this.add(this.outer);
        this.audio = audio;
        this.range = range;
        this.divisionsInnerAngle = divisionsInnerAngle;
        this.divisionsOuterAngle = divisionsOuterAngle;
        this.type = "PositionalAudioHelper";
        this.update();
    }

    update(): void {
        const coneInnerAngle = MathUtils.degToRad(this.audio.panner.coneInnerAngle);
        const coneOuterAngle = MathUtils.degToRad(this.audio.panner.coneOuterAngle);
        const halfConeInnerAngle = coneInnerAngle / 2;
        const halfConeOuterAngle = coneOuterAngle / 2;
        const innerPositions = this.geometry.getAttribute("position")!;
        const outerPositions = this.outer.geometry.getAttribute("position")!;
        let n = generateSegment(innerPositions, 0, -halfConeInnerAngle, halfConeInnerAngle, this.divisionsInnerAngle, this.range);
        this.geometry.setDrawRange(0, n);
        let m = generateSegment(outerPositions, 0, -halfConeOuterAngle, -halfConeInnerAngle, this.divisionsOuterAngle, this.range);
        m = generateSegment(outerPositions, m, halfConeInnerAngle, halfConeOuterAngle, this.divisionsOuterAngle, this.range);
        this.outer.geometry.setDrawRange(0, m);
        innerPositions.needsUpdate = true;
        outerPositions.needsUpdate = true;
        this.outer.visible = coneInnerAngle != coneOuterAngle;
    }

    dispose(): void {
        this.geometry.dispose();
        this.outer.geometry.dispose();
        this.materialInnerAngle.dispose();
        this.materialOuterAngle.dispose();
    }
}

/// A fan from the origin over [from, to] as a line strip (origin, arc
/// points, back to the origin per step), from vertex `start`; returns the
/// next free vertex.
function generateSegment(positions: BufferAttribute, start: i32, from: f64, to: f64, divisions: i32, range: f64): i32 {
    if (divisions <= 0) return start;
    const step = (to - from) / <f64>divisions;
    let count = start;
    positions.setXYZ(count++, 0, 0, 0);
    for (let k = 0; k < divisions; k++) {
        const i = from + step * <f64>k;
        const j = Math.min(i + step, to);
        if (count + 3 > positions.count) break;
        positions.setXYZ(count++, Math.sin(i) * range, 0, Math.cos(i) * range);
        positions.setXYZ(count++, Math.sin(j) * range, 0, Math.cos(j) * range);
        positions.setXYZ(count++, 0, 0, 0);
    }
    return count;
}
