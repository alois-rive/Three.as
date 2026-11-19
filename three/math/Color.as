// three.js Color, with colour management on: `r`, `g`, `b` are linear
// sRGB (the working space); hex values, HSL and CSS strings are sRGB and
// converted, as three.js does.
//
// Rive interop: a Rive `Color` (0xAARRGGBB, from `rive/color` or a
// `Color` script input) passes to `setHex`/`set`, which ignore alpha. Its
// alpha is `Color.alphaOf(argb)`.

import { ColorOrTexture } from "../core/ColorOrTexture";

export class Color extends ColorOrTexture {
    r: f64 = 1;
    g: f64 = 1;
    b: f64 = 1;

    /// `new Color(0xff8800)` (sRGB hex; white when omitted), or linear
    /// components `new Color(1, 0.5, 0)`. For a CSS string or another
    /// Color, use `Color.fromStyle(s)` / `c.clone()` or `new Color().set(x)`.
    constructor(r: f64 = <f64>0xFFFFFF, g: f64 = -1, b: f64 = -1) {
        super();
        if (g < 0 && b < 0) this.setHex(<u32>r);
        else this.setRGB(r, g, b);
    }

    /// From an sRGB hex value (0xRRGGBB, or a Rive 0xAARRGGBB).
    static fromHex(hex: u32): Color { return new Color(0, 0, 0).setHex(hex); }

    /// From a CSS colour string.
    static fromStyle(style: string): Color { return new Color(0, 0, 0).setStyle(style); }

    /// From linear components.
    static fromRGB(r: f64, g: f64, b: f64): Color { return new Color(r, g, b); }

    /// The alpha of a Rive colour (0xAARRGGBB), 0 to 1.
    static alphaOf(argb: u32): f64 { return <f64>((argb >>> 24) & 0xFF) / 255; }

    /// Sets from a hex number, a CSS string or another Color.
    set<T>(value: T): Color {
        if (isString<T>()) return this.setStyle(value as string);
        else if (isReference<T>()) {
            if (value instanceof Color) return this.copy(value as Color);
            return this;
        } else if (isFloat<T>()) {
            return this.setHex(<u32>(<f64>value));
        } else {
            return this.setHex(<u32>value);
        }
    }

    setScalar(s: f64): Color { this.r = s; this.g = s; this.b = s; return this; }

    /// sRGB 0xRRGGBB; an alpha byte (Rive colours) is ignored.
    setHex(hex: u32): Color {
        this.r = SRGBToLinear(<f64>((hex >> 16) & 0xFF) / 255);
        this.g = SRGBToLinear(<f64>((hex >> 8) & 0xFF) / 255);
        this.b = SRGBToLinear(<f64>(hex & 0xFF) / 255);
        return this;
    }

    /// Linear components (three.js's default working colour space).
    setRGB(r: f64, g: f64, b: f64, colorSpace: string = "srgb-linear"): Color {
        if (colorSpace == "srgb") {
            this.r = SRGBToLinear(r); this.g = SRGBToLinear(g); this.b = SRGBToLinear(b);
        } else {
            this.r = r; this.g = g; this.b = b;
        }
        return this;
    }

    /// Hue, saturation and lightness in [0, 1], in `colorSpace` (sRGB).
    setHSL(h: f64, s: f64, l: f64, colorSpace: string = "srgb"): Color {
        h = ((h % 1) + 1) % 1;
        s = Math.max(0, Math.min(1, s));
        l = Math.max(0, Math.min(1, l));
        if (s == 0) return this.setRGB(l, l, l, colorSpace);
        const p = l <= 0.5 ? l * (1 + s) : l + s - l * s;
        const q = 2 * l - p;
        return this.setRGB(hue2rgb(q, p, h + 1 / 3), hue2rgb(q, p, h), hue2rgb(q, p, h - 1 / 3), colorSpace);
    }

    /// A CSS colour, as three.js: "#rgb", "#rrggbb", "rgb(r, g, b)" and
    /// "rgba(...)" (0 to 255 or percentages), "hsl(h, s%, l%)" and
    /// "hsla(...)", or a CSS colour keyword ("cornflowerblue"). Alpha is
    /// ignored; an unknown style leaves the colour unchanged. `colorSpace`
    /// is the string's space (sRGB, as CSS).
    setStyle(style: string, colorSpace: string = "srgb"): Color {
        const s = style.trim();
        const open = s.indexOf("(");
        if (open > 0 && s.endsWith(")")) {
            const name = s.substring(0, open).trim().toLowerCase();
            const args = splitColorArgs(s.substring(open + 1, s.length - 1));
            if ((name == "rgb" || name == "rgba") && args.length >= 3) {
                let r: f64 = 0, g: f64 = 0, b: f64 = 0;
                for (let i = 0; i < 3; i++) {
                    const a = args[i];
                    const v = a.endsWith("%")
                        ? Math.min(100, Math.max(0, parseFloat(a.substring(0, a.length - 1)))) / 100
                        : Math.min(255, Math.max(0, parseFloat(a))) / 255;
                    if (isNaN(v)) return this;
                    if (i == 0) r = v; else if (i == 1) g = v; else b = v;
                }
                return this.setRGB(r, g, b, colorSpace);
            }
            if ((name == "hsl" || name == "hsla") && args.length >= 3) {
                const h = parseFloat(args[0]) / 360;
                const sat = parseFloat(args[1]) / 100, l = parseFloat(args[2]) / 100;
                if (isNaN(h) || isNaN(sat) || isNaN(l)) return this;
                return this.setHSL(h, sat, l, colorSpace);
            }
            return this;
        }
        if (s.startsWith("#")) {
            const hex = s.substring(1);
            for (let i = 0; i < hex.length; i++) if (parseHexDigit(hex.charCodeAt(i)) < 0) return this;
            if (hex.length == 3 || hex.length == 4) {
                return this.setRGB(<f64>parseHexDigit(hex.charCodeAt(0)) / 15, <f64>parseHexDigit(hex.charCodeAt(1)) / 15,
                    <f64>parseHexDigit(hex.charCodeAt(2)) / 15, colorSpace);
            }
            if (hex.length == 6 || hex.length == 8) {
                const v = <u32>I32.parseInt(hex.substring(0, 6), 16);
                return this.setRGB(<f64>((v >> 16) & 0xFF) / 255, <f64>((v >> 8) & 0xFF) / 255, <f64>(v & 0xFF) / 255, colorSpace);
            }
            return this;
        }
        if (s.length > 0) return this.setColorName(s, colorSpace);
        return this;
    }

    /// A CSS colour keyword; an unknown name leaves the colour unchanged.
    setColorName(style: string, colorSpace: string = "srgb"): Color {
        const keywords = colorKeywords();
        const name = style.toLowerCase();
        if (!keywords.has(name)) return this;
        const v = keywords.get(name);
        return this.setRGB(<f64>((v >> 16) & 0xFF) / 255, <f64>((v >> 8) & 0xFF) / 255, <f64>(v & 0xFF) / 255, colorSpace);
    }

    clone(): Color { return new Color(this.r, this.g, this.b); }
    copy(c: Color): Color { this.r = c.r; this.g = c.g; this.b = c.b; return this; }

    copySRGBToLinear(c: Color): Color {
        this.r = SRGBToLinear(c.r); this.g = SRGBToLinear(c.g); this.b = SRGBToLinear(c.b);
        return this;
    }

    copyLinearToSRGB(c: Color): Color {
        this.r = LinearToSRGB(c.r); this.g = LinearToSRGB(c.g); this.b = LinearToSRGB(c.b);
        return this;
    }

    convertSRGBToLinear(): Color { return this.copySRGBToLinear(this); }
    convertLinearToSRGB(): Color { return this.copyLinearToSRGB(this); }

    /// The sRGB hex, 0xRRGGBB.
    getHex(): u32 {
        return (byte(LinearToSRGB(this.r)) << 16) | (byte(LinearToSRGB(this.g)) << 8) | byte(LinearToSRGB(this.b));
    }

    getHexString(): string {
        let s = this.getHex().toString(16);
        while (s.length < 6) s = "0" + s;
        return s;
    }

    getStyle(): string { return "#" + this.getHexString(); }

    /// This colour as a Rive `Color` (0xAARRGGBB), with `alpha` 0 to 1.
    getRiveColor(alpha: f64 = 1): u32 {
        return (byte(alpha) << 24) | this.getHex();
    }

    add(c: Color): Color { this.r += c.r; this.g += c.g; this.b += c.b; return this; }
    addColors(a: Color, b: Color): Color { this.r = a.r + b.r; this.g = a.g + b.g; this.b = a.b + b.b; return this; }
    addScalar(s: f64): Color { this.r += s; this.g += s; this.b += s; return this; }
    sub(c: Color): Color {
        this.r = Math.max(0, this.r - c.r); this.g = Math.max(0, this.g - c.g); this.b = Math.max(0, this.b - c.b);
        return this;
    }
    multiply(c: Color): Color { this.r *= c.r; this.g *= c.g; this.b *= c.b; return this; }
    multiplyScalar(s: f64): Color { this.r *= s; this.g *= s; this.b *= s; return this; }

    lerp(c: Color, alpha: f64): Color {
        this.r += (c.r - this.r) * alpha;
        this.g += (c.g - this.g) * alpha;
        this.b += (c.b - this.b) * alpha;
        return this;
    }

    lerpColors(a: Color, b: Color, alpha: f64): Color {
        this.r = a.r + (b.r - a.r) * alpha;
        this.g = a.g + (b.g - a.g) * alpha;
        this.b = a.b + (b.b - a.b) * alpha;
        return this;
    }

    equals(c: Color): bool { return this.r == c.r && this.g == c.g && this.b == c.b; }
}

export function SRGBToLinear(c: f64): f64 {
    return c < 0.04045 ? c * 0.0773993808 : Math.pow(c * 0.9478672986 + 0.0521327014, 2.4);
}

export function LinearToSRGB(c: f64): f64 {
    return c < 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 0.41666) - 0.055;
}

function byte(v: f64): u32 {
    return <u32>Math.round(Math.max(0, Math.min(1, v)) * 255);
}

function hue2rgb(p: f64, q: f64, t: f64): f64 {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * 6 * (2 / 3 - t);
    return p;
}

function parseHexDigit(c: i32): i32 {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 102) return c - 87;
    if (c >= 65 && c <= 70) return c - 55;
    return -1;
}

/// The arguments of "rgb(...)" / "hsl(...)", separated by commas, spaces
/// or "/" (CSS 4's alpha).
function splitColorArgs(s: string): Array<string> {
    const out: Array<string> = [];
    let start = -1;
    for (let i = 0; i <= s.length; i++) {
        const c = i < s.length ? s.charCodeAt(i) : 32;
        if (c == 44 || c == 47 || c == 32 || c == 9 || c == 10 || c == 13) {
            if (start >= 0) out.push(s.substring(start, i));
            start = -1;
        } else if (start < 0) {
            start = i;
        }
    }
    return out;
}

// three.js's _colorKeywords (the CSS colour keywords), as "name=RRGGBB".
const COLOR_KEYWORDS = "aliceblue=F0F8FF antiquewhite=FAEBD7 aqua=00FFFF aquamarine=7FFFD4 azure=F0FFFF "
    + "beige=F5F5DC bisque=FFE4C4 black=000000 blanchedalmond=FFEBCD blue=0000FF blueviolet=8A2BE2 "
    + "brown=A52A2A burlywood=DEB887 cadetblue=5F9EA0 chartreuse=7FFF00 chocolate=D2691E coral=FF7F50 "
    + "cornflowerblue=6495ED cornsilk=FFF8DC crimson=DC143C cyan=00FFFF darkblue=00008B darkcyan=008B8B "
    + "darkgoldenrod=B8860B darkgray=A9A9A9 darkgreen=006400 darkgrey=A9A9A9 darkkhaki=BDB76B "
    + "darkmagenta=8B008B darkolivegreen=556B2F darkorange=FF8C00 darkorchid=9932CC darkred=8B0000 "
    + "darksalmon=E9967A darkseagreen=8FBC8F darkslateblue=483D8B darkslategray=2F4F4F "
    + "darkslategrey=2F4F4F darkturquoise=00CED1 darkviolet=9400D3 deeppink=FF1493 deepskyblue=00BFFF "
    + "dimgray=696969 dimgrey=696969 dodgerblue=1E90FF firebrick=B22222 floralwhite=FFFAF0 "
    + "forestgreen=228B22 fuchsia=FF00FF gainsboro=DCDCDC ghostwhite=F8F8FF gold=FFD700 goldenrod=DAA520 "
    + "gray=808080 green=008000 greenyellow=ADFF2F grey=808080 honeydew=F0FFF0 hotpink=FF69B4 "
    + "indianred=CD5C5C indigo=4B0082 ivory=FFFFF0 khaki=F0E68C lavender=E6E6FA lavenderblush=FFF0F5 "
    + "lawngreen=7CFC00 lemonchiffon=FFFACD lightblue=ADD8E6 lightcoral=F08080 lightcyan=E0FFFF "
    + "lightgoldenrodyellow=FAFAD2 lightgray=D3D3D3 lightgreen=90EE90 lightgrey=D3D3D3 lightpink=FFB6C1 "
    + "lightsalmon=FFA07A lightseagreen=20B2AA lightskyblue=87CEFA lightslategray=778899 "
    + "lightslategrey=778899 lightsteelblue=B0C4DE lightyellow=FFFFE0 lime=00FF00 limegreen=32CD32 "
    + "linen=FAF0E6 magenta=FF00FF maroon=800000 mediumaquamarine=66CDAA mediumblue=0000CD "
    + "mediumorchid=BA55D3 mediumpurple=9370DB mediumseagreen=3CB371 mediumslateblue=7B68EE "
    + "mediumspringgreen=00FA9A mediumturquoise=48D1CC mediumvioletred=C71585 midnightblue=191970 "
    + "mintcream=F5FFFA mistyrose=FFE4E1 moccasin=FFE4B5 navajowhite=FFDEAD navy=000080 oldlace=FDF5E6 "
    + "olive=808000 olivedrab=6B8E23 orange=FFA500 orangered=FF4500 orchid=DA70D6 palegoldenrod=EEE8AA "
    + "palegreen=98FB98 paleturquoise=AFEEEE palevioletred=DB7093 papayawhip=FFEFD5 peachpuff=FFDAB9 "
    + "peru=CD853F pink=FFC0CB plum=DDA0DD powderblue=B0E0E6 purple=800080 rebeccapurple=663399 "
    + "red=FF0000 rosybrown=BC8F8F royalblue=4169E1 saddlebrown=8B4513 salmon=FA8072 sandybrown=F4A460 "
    + "seagreen=2E8B57 seashell=FFF5EE sienna=A0522D silver=C0C0C0 skyblue=87CEEB slateblue=6A5ACD "
    + "slategray=708090 slategrey=708090 snow=FFFAFA springgreen=00FF7F steelblue=4682B4 tan=D2B48C "
    + "teal=008080 thistle=D8BFD8 tomato=FF6347 turquoise=40E0D0 violet=EE82EE wheat=F5DEB3 "
    + "white=FFFFFF whitesmoke=F5F5F5 yellow=FFFF00 yellowgreen=9ACD32";

let _colorKeywords: Map<string, u32>? = null;

function colorKeywords(): Map<string, u32> {
    const cached = _colorKeywords;
    if (cached != null) return cached;
    const k = new Map<string, u32>();
    const entries = COLOR_KEYWORDS.split(" ");
    for (let i = 0; i < entries.length; i++) {
        const e = entries[i];
        const eq = e.indexOf("=");
        if (eq > 0) k.set(e.substring(0, eq), <u32>I32.parseInt(e.substring(eq + 1), 16));
    }
    _colorKeywords = k;
    return k;
}
