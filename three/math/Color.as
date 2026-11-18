// three.js Color, with colour management on: `r`, `g`, `b` are linear
// sRGB (the working space); hex values, HSL and CSS strings are sRGB and
// converted, as three.js does.
//
// Rive interop: a Rive `Color` (0xAARRGGBB, from `rive/color` or a
// `Color` script input) passes to `setHex`/`set`, which ignore alpha. Its
// alpha is `Color.alphaOf(argb)`.

export class Color {
    r: f64 = 1;
    g: f64 = 1;
    b: f64 = 1;

    /// `new Color(0xff8800)` (sRGB hex; white when omitted), or linear
    /// components `new Color(1, 0.5, 0)`. For a CSS string or another
    /// Color, use `Color.fromStyle(s)` / `c.clone()` or `new Color().set(x)`.
    constructor(r: f64 = <f64>0xFFFFFF, g: f64 = -1, b: f64 = -1) {
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

    /// Hue, saturation and lightness in [0, 1], sRGB.
    setHSL(h: f64, s: f64, l: f64): Color {
        h = ((h % 1) + 1) % 1;
        s = Math.max(0, Math.min(1, s));
        l = Math.max(0, Math.min(1, l));
        if (s == 0) return this.setRGB(l, l, l, "srgb");
        const p = l <= 0.5 ? l * (1 + s) : l + s - l * s;
        const q = 2 * l - p;
        return this.setRGB(hue2rgb(q, p, h + 1 / 3), hue2rgb(q, p, h), hue2rgb(q, p, h - 1 / 3), "srgb");
    }

    /// "#rgb", "#rrggbb", "rgb(r, g, b)" (0 to 255) or a few named colours.
    setStyle(style: string): Color {
        let s = style.trim().toLowerCase();
        if (s.startsWith("#")) {
            const hex = s.substring(1);
            if (hex.length == 3) {
                const r = parseHexDigit(hex.charCodeAt(0)), g = parseHexDigit(hex.charCodeAt(1)), b = parseHexDigit(hex.charCodeAt(2));
                return this.setHex(<u32>((r * 17) << 16 | (g * 17) << 8 | (b * 17)));
            }
            if (hex.length >= 6) return this.setHex(<u32>I32.parseInt(hex.substring(0, 6), 16));
            return this;
        }
        if (s.startsWith("rgb")) {
            const open = s.indexOf("("), close = s.indexOf(")");
            if (open >= 0 && close > open) {
                const parts = s.substring(open + 1, close).split(",");
                if (parts.length >= 3) {
                    return this.setRGB(
                        F64.parseFloat(parts[0].trim()) / 255,
                        F64.parseFloat(parts[1].trim()) / 255,
                        F64.parseFloat(parts[2].trim()) / 255, "srgb");
                }
            }
            return this;
        }
        if (s == "white") return this.setHex(0xFFFFFF);
        if (s == "black") return this.setHex(0x000000);
        if (s == "red") return this.setHex(0xFF0000);
        if (s == "green") return this.setHex(0x008000);
        if (s == "blue") return this.setHex(0x0000FF);
        if (s == "yellow") return this.setHex(0xFFFF00);
        if (s == "orange") return this.setHex(0xFFA500);
        if (s == "skyblue") return this.setHex(0x87CEEB);
        if (s == "hotpink") return this.setHex(0xFF69B4);
        if (s == "gray" || s == "grey") return this.setHex(0x808080);
        return this;
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
    return 0;
}
