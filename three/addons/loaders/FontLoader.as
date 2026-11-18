// three.js examples/jsm/loaders/FontLoader.js: typeface JSON fonts
// (facetype.js output) from a BlobAsset, with Font.generateShapes for
// TextGeometry. Rive-only: RiveFont takes any font in the Rive file
// (`context.font(name)`, a Font from rive/text), shaped by Rive's text
// engine (kerning, ligatures, any script), with the same generateShapes.
//
//     const font = new FontLoader(context).load("helvetiker_regular");   // BlobAsset
//     const font = new RiveFont(context.font("Inter")!);                  // FontAsset
//     const g = new TextGeometry("Hello", { font: font, size: 0.5, depth: 0.1 });

import { Context } from "rive/host";
import { parseJson } from "rive/json";
import { Dynamic } from "rive/dynamic";
import { Font as RiveTextFont, Text, TextRunStyle } from "rive/text";
import { ShapePath } from "../../extras/core/ShapePath";
import { Shape } from "../../extras/core/Shape";

class TypefaceGlyph {
    ha: f64 = 0;
    outline: Array<string> = [];
}

/// A font that turns text into shapes (three.js's Font).
export class Font {
    readonly isFont: bool = true;
    type: string = "Font";
    glyphs: Map<string, TypefaceGlyph> = new Map<string, TypefaceGlyph>();
    resolution: f64 = 1000;
    ascender: f64 = 0;
    lineHeight: f64 = 1000;

    /// The text as shapes, `size` units tall per em (three.js's
    /// generateShapes; "ltr" or "rtl").
    generateShapes(text: string, size: f64 = 100, direction: string = "ltr"): Array<Shape> {
        const scale = size / this.resolution;
        const lineHeight = this.lineHeight * scale;
        const shapes: Array<Shape> = [];
        let offsetX: f64 = 0, offsetY: f64 = 0;
        const n = text.length;
        for (let k = 0; k < n; k++) {
            const i = direction == "rtl" ? n - 1 - k : k;
            const char = text.charAt(i);
            if (char == "\n") {
                offsetX = 0;
                offsetY -= lineHeight;
                continue;
            }
            let glyph: TypefaceGlyph? = this.glyphs.has(char) ? this.glyphs.get(char) : null;
            if (glyph == null && this.glyphs.has("?")) glyph = this.glyphs.get("?");
            if (glyph == null) continue;
            const path = new ShapePath();
            const o = glyph.outline;
            let j = 0;
            while (j < o.length) {
                const action = o[j++];
                if (action == "m" || action == "l") {
                    const x = parseFloat(o[j++]) * scale + offsetX, y = parseFloat(o[j++]) * scale + offsetY;
                    if (action == "m") path.moveTo(x, y); else path.lineTo(x, y);
                } else if (action == "q") {
                    const x = parseFloat(o[j++]) * scale + offsetX, y = parseFloat(o[j++]) * scale + offsetY;
                    const cx = parseFloat(o[j++]) * scale + offsetX, cy = parseFloat(o[j++]) * scale + offsetY;
                    path.quadraticCurveTo(cx, cy, x, y);
                } else if (action == "b") {
                    const x = parseFloat(o[j++]) * scale + offsetX, y = parseFloat(o[j++]) * scale + offsetY;
                    const c1x = parseFloat(o[j++]) * scale + offsetX, c1y = parseFloat(o[j++]) * scale + offsetY;
                    const c2x = parseFloat(o[j++]) * scale + offsetX, c2y = parseFloat(o[j++]) * scale + offsetY;
                    path.bezierCurveTo(c1x, c1y, c2x, c2y, x, y);
                }
            }
            const s = path.toShapes(false);
            for (let m = 0; m < s.length; m++) shapes.push(s[m]);
            offsetX += glyph.ha * scale;
        }
        return shapes;
    }
}

export class FontLoader {
    context: Context?;
    error: string = "";

    constructor(context: Context? = null) {
        this.context = context;
    }

    /// The typeface JSON BlobAsset called `name`.
    load(name: string): Font? {
        const context = this.context;
        if (context == null) return null;
        const bytes = context.blob(name);
        if (bytes == null) {
            context.log("three: FontLoader: no blob asset named '" + name + "'");
            return null;
        }
        const font = this.parse(String.UTF8.decode(bytes));
        if (font == null) context.log("three: FontLoader: " + this.error);
        return font;
    }

    /// Parses typeface JSON (three.js's FontLoader.parse takes the object).
    parse(json: string): Font? {
        const result = parseJson(json);
        if (!result.ok || result.value == null) {
            this.error = "not JSON";
            return null;
        }
        const root = result.value;
        const glyphs = Dynamic.asMapOrNull(dget(root, "glyphs"));
        if (glyphs == null) {
            this.error = "no glyphs";
            return null;
        }
        const font = new Font();
        font.resolution = num(root, "resolution", 1000);
        font.ascender = num(root, "ascender", 0);
        const bb = dget(root, "boundingBox");
        font.lineHeight = num(bb, "yMax", 800) - num(bb, "yMin", -200) + num(root, "underlineThickness", 0);
        const keys = glyphs.keys();
        for (let i = 0; i < keys.length; i++) {
            const g = glyphs.get(keys[i]);
            const glyph = new TypefaceGlyph();
            glyph.ha = num(g, "ha", 0);
            const o = Dynamic.asStringOrNull(dget(g, "o"));
            if (o != null) {
                const parts = o.split(" ");
                for (let k = 0; k < parts.length; k++) if (parts[k].length > 0) glyph.outline.push(parts[k]);
            }
            font.glyphs.set(keys[i], glyph);
        }
        return font;
    }
}

function dget(value: Dynamic?, key: string): Dynamic? {
    if (value == null || Dynamic.typeName(value) != "table") return null;
    return Dynamic.get(value, key);
}

function num(value: Dynamic?, key: string, fallback: f64): f64 {
    const n = Dynamic.asNumberOrNull(dget(value, key));
    return n != null ? n.value : fallback;
}

/// Rive-only: a font of the Rive file as a three.js Font. Rive's text
/// engine shapes the string (kerning, ligatures, bidi), then each glyph's
/// outline becomes shapes, `size` units per em, baseline at y 0.
export class RiveFont extends Font {
    font: RiveTextFont;

    constructor(font: RiveTextFont) {
        super();
        this.type = "RiveFont";
        this.font = font;
    }

    override generateShapes(text: string, size: f64 = 100, direction: string = "ltr"): Array<Shape> {
        const shaped = new Text();
        // Shaping at 1 point keeps the outline maths in em units.
        const style = new TextRunStyle(this.font);
        style.size = 1;
        shaped.append(text, style);
        const shapes: Array<Shape> = [];
        const lines = shaped.lines();
        for (let l = 0; l < lines.length; l++) {
            const glyphs = lines[l].glyphs();
            for (let g = 0; g < glyphs.length; g++) {
                const glyph = glyphs[g];
                const path = glyph.font.glyphPath(glyph.id);
                const out = new ShapePath();
                const gx = <f64>glyph.x, gy = <f64>glyph.y;
                for (let i = 0; i < path.length; i++) {
                    const c = path[i];
                    const type = c.type;
                    // Rive's y points down; three.js's up.
                    if (type == "moveTo") {
                        const p = c[0];
                        out.moveTo((gx + <f64>p.x) * size, -(gy + <f64>p.y) * size);
                    } else if (type == "lineTo") {
                        const p = c[0];
                        out.lineTo((gx + <f64>p.x) * size, -(gy + <f64>p.y) * size);
                    } else if (type == "quadTo") {
                        const a = c[0], b = c[1];
                        out.quadraticCurveTo((gx + <f64>a.x) * size, -(gy + <f64>a.y) * size,
                            (gx + <f64>b.x) * size, -(gy + <f64>b.y) * size);
                    } else if (type == "cubicTo") {
                        const a = c[0], b = c[1], d = c[2];
                        out.bezierCurveTo((gx + <f64>a.x) * size, -(gy + <f64>a.y) * size,
                            (gx + <f64>b.x) * size, -(gy + <f64>b.y) * size,
                            (gx + <f64>d.x) * size, -(gy + <f64>d.y) * size);
                    }
                }
                const s = out.toShapes(true);
                for (let m = 0; m < s.length; m++) shapes.push(s[m]);
            }
        }
        shaped.release();
        return shapes;
    }
}
