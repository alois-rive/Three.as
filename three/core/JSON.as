// JSON for three.js's toJSON methods and ObjectLoader.
//
// three.js's toJSON methods build plain JavaScript objects and leave the
// text to JSON.stringify. AnimaScript has a JSON parser (rive/json) but no
// writer and no untyped objects, so toJSON methods here build `Dynamic`
// tables (rive/dynamic) of the same shape, and `JSON.stringify` writes one
// as text:
//
//     const text = THREE.JSON.stringify(scene.toJSON());
//     const copy = new THREE.ObjectLoader(context).parse(text);
//
// A table with string keys is written as an object, any other table
// (including an empty one) as an array; three.js leaves empty objects out
// of its JSON, so this matches what it writes.

import { Dynamic, DynamicKind } from "rive/dynamic";
import { parseJson } from "rive/json";
import { Euler } from "../math/Euler";

export class JSON {
    /// `value` as JSON text, as JavaScript's JSON.stringify(value, null,
    /// space): `space` > 0 puts each member on its own line, indented by
    /// that many spaces. Numbers that are not finite are written `null`.
    static stringify(value: Dynamic?, space: i32 = 0): string {
        let indent = "";
        for (let i = 0; i < space; i++) indent += " ";
        const out: Array<string> = [];
        writeValue(out, value, indent, "\n");
        return out.join("");
    }

    /// The value of JSON `text`, or null when it is not JSON (or is
    /// `null`); `JSON.lastError` then says why.
    static parse(text: string): Dynamic? {
        const result = parseJson(text);
        const error = result.error;
        JSON.lastError = error != null ? error : "";
        return result.ok ? result.value : null;
    }

    /// Why the last `parse` failed ("" when it did not).
    static lastError: string = "";
}

/// The libraries three.js's toJSON(meta) fills while serializing a scene:
/// what has been written, by uuid, so shared geometries, materials and
/// textures are written once.
export class JSONMeta {
    geometries: Map<string, Dynamic> = new Map<string, Dynamic>();
    materials: Map<string, Dynamic> = new Map<string, Dynamic>();
    textures: Map<string, Dynamic> = new Map<string, Dynamic>();
    images: Map<string, Dynamic> = new Map<string, Dynamic>();
    shapes: Map<string, Dynamic> = new Map<string, Dynamic>();
    skeletons: Map<string, Dynamic> = new Map<string, Dynamic>();
    animations: Map<string, Dynamic> = new Map<string, Dynamic>();
    nodes: Map<string, Dynamic> = new Map<string, Dynamic>();

    /// A library as the array three.js writes (its entries without their
    /// `metadata`), or null when it is empty.
    static extract(cache: Map<string, Dynamic>): Dynamic? {
        if (cache.size == 0) return null;
        const values = cache.values();
        const out = Dynamic.newTable();
        for (let i = 0; i < values.length; i++) {
            const data = values[i];
            data.set("metadata", null);
            out.push(data);
        }
        return out;
    }
}

// ------------------------------------------------------------------ writing

/// three.js's `metadata` block: { version: 4.6, type, generator }.
export function jsonMetadata(type: string, generator: string): Dynamic {
    const m = Dynamic.newTable();
    m.set("version", Dynamic.fromNumber(4.6));
    m.set("type", Dynamic.fromString(type));
    m.set("generator", Dynamic.fromString(generator));
    return m;
}

export function setNumber(data: Dynamic, key: string, value: f64): void {
    data.set(key, Dynamic.fromNumber(value));
}

export function setString(data: Dynamic, key: string, value: string): void {
    data.set(key, Dynamic.fromString(value));
}

export function setBool(data: Dynamic, key: string, value: bool): void {
    data.set(key, Dynamic.fromBool(value));
}

export function setNumbers(data: Dynamic, key: string, value: Array<f64>): void {
    data.set(key, Dynamic.fromNumbers(value));
}

/// A table of the numbers of `array` (three.js's Array.from(typedArray)).
export function numbersOf(array: Float32Array): Dynamic {
    const a = new Array<f64>(array.length);
    for (let i = 0; i < array.length; i++) a[i] = <f64>array[i];
    return Dynamic.fromNumbers(a);
}

/// three.js's Euler.toArray(): [x, y, z, order].
export function eulerToJSON(e: Euler): Dynamic {
    const a = Dynamic.newTable();
    a.push(Dynamic.fromNumber(e.x));
    a.push(Dynamic.fromNumber(e.y));
    a.push(Dynamic.fromNumber(e.z));
    a.push(Dynamic.fromString(e.order));
    return a;
}

/// Euler.fromArray([x, y, z, order]); does nothing for a missing value.
export function eulerFromJSON(e: Euler, value: Dynamic?): void {
    if (value == null || value.kind != DynamicKind.table || Dynamic.length(value) < 3) return;
    const order = asStr(jat(value, 3));
    e.set(asNum(jat(value, 0), 0), asNum(jat(value, 1), 0), asNum(jat(value, 2), 0), order);
}

/// Whether `value` is null or a table with nothing in it.
export function isEmptyTable(value: Dynamic?): bool {
    if (value == null) return true;
    if (value.kind != DynamicKind.table) return false;
    return Dynamic.asMap(value).size == 0 && Dynamic.asArray(value).length == 0;
}

/// A deep copy of a JSON value (three.js's JSON.parse(JSON.stringify(v))
/// for userData).
export function cloneDynamic(value: Dynamic?): Dynamic? {
    if (value == null || value.kind != DynamicKind.table) return value;
    const out = Dynamic.newTable();
    const items = Dynamic.asArray(value);
    for (let i = 0; i < items.length; i++) out.push(cloneDynamic(items[i]));
    const map = Dynamic.asMap(value);
    const keys = map.keys();
    for (let i = 0; i < keys.length; i++) out.set(keys[i], cloneDynamic(map.get(keys[i])));
    return out;
}

// ------------------------------------------------------------------ reading
// Readers that tolerate missing members and null values (three.js's
// `if (data.x !== undefined)`), where Dynamic's own readers trap.

/// The member `key` of an object, or null.
export function jget(value: Dynamic?, key: string): Dynamic? {
    if (value == null || value.kind != DynamicKind.table) return null;
    return Dynamic.get(value, key);
}

/// Whether the object has a (non-null) member `key`.
export function jhas(value: Dynamic?, key: string): bool {
    return jget(value, key) != null;
}

/// Item `index` of an array, or null.
export function jat(value: Dynamic?, index: i32): Dynamic? {
    if (value == null || value.kind != DynamicKind.table) return null;
    if (index < 0 || <f64>index >= Dynamic.length(value)) return null;
    return Dynamic.at(value, index);
}

/// The items of an array (empty for anything else).
export function jitems(value: Dynamic?): Array<Dynamic?> {
    if (value == null || value.kind != DynamicKind.table) return [];
    return Dynamic.asArray(value);
}

/// The items of the array member `key` (empty when missing).
export function jarr(value: Dynamic?, key: string): Array<Dynamic?> {
    return jitems(jget(value, key));
}

/// A number member; booleans read as 0 / 1.
export function jnum(value: Dynamic?, key: string, fallback: f64): f64 {
    return asNum(jget(value, key), fallback);
}

export function jint(value: Dynamic?, key: string, fallback: i32): i32 {
    return <i32>asNum(jget(value, key), <f64>fallback);
}

export function jbool(value: Dynamic?, key: string, fallback: bool): bool {
    const v = jget(value, key);
    if (v == null) return fallback;
    if (v.kind == DynamicKind.boolean) return Dynamic.asBool(v);
    if (v.kind == DynamicKind.number) return Dynamic.asNumber(v) != 0;
    return fallback;
}

export function jstr(value: Dynamic?, key: string, fallback: string): string {
    const v = jget(value, key);
    if (v == null || v.kind != DynamicKind.string) return fallback;
    return Dynamic.asString(v);
}

/// A number, or `fallback` when `value` is not one (booleans read 0 / 1).
export function asNum(value: Dynamic?, fallback: f64): f64 {
    if (value == null) return fallback;
    if (value.kind == DynamicKind.number) return Dynamic.asNumber(value);
    if (value.kind == DynamicKind.boolean) return Dynamic.asBool(value) ? 1 : 0;
    return fallback;
}

/// The numbers of an array value (non-numbers read as 0), or null when it
/// is not an array.
export function asNumbers(value: Dynamic?): Array<f64>? {
    if (value == null || value.kind != DynamicKind.table) return null;
    const items = Dynamic.asArray(value);
    const out = new Array<f64>(items.length);
    for (let i = 0; i < items.length; i++) out[i] = asNum(items[i], 0);
    return out;
}

/// The numbers of the array member `key`, or null when missing.
export function jnumbers(value: Dynamic?, key: string): Array<f64>? {
    return asNumbers(jget(value, key));
}

/// A string value, or "" when it is not one.
export function asStr(value: Dynamic?): string {
    if (value == null || value.kind != DynamicKind.string) return "";
    return Dynamic.asString(value);
}

// ------------------------------------------------------------------ stringify

function writeValue(out: Array<string>, value: Dynamic?, indent: string, line: string): void {
    if (value == null) {
        out.push("null");
        return;
    }
    const kind = value.kind;
    if (kind == DynamicKind.boolean) {
        out.push(Dynamic.asBool(value) ? "true" : "false");
    } else if (kind == DynamicKind.number) {
        out.push(numberText(Dynamic.asNumber(value)));
    } else if (kind == DynamicKind.string) {
        out.push(quote(Dynamic.asString(value)));
    } else if (kind == DynamicKind.table) {
        const pretty = indent.length > 0;
        const inner = pretty ? line + indent : "";
        const map = Dynamic.asMap(value);
        if (map.size == 0) {
            const items = Dynamic.asArray(value);
            if (items.length == 0) {
                out.push("[]");
                return;
            }
            out.push("[");
            for (let i = 0; i < items.length; i++) {
                if (i > 0) out.push(",");
                if (pretty) out.push(inner);
                writeValue(out, items[i], indent, inner);
            }
            if (pretty) out.push(line);
            out.push("]");
        } else {
            out.push("{");
            const keys = map.keys();
            let first = true;
            for (let i = 0; i < keys.length; i++) {
                const v = map.get(keys[i]);
                if (v == null) continue;
                if (!first) out.push(",");
                first = false;
                if (pretty) out.push(inner);
                out.push(quote(keys[i]));
                out.push(pretty ? ": " : ":");
                writeValue(out, v, indent, inner);
            }
            if (pretty) out.push(line);
            out.push("}");
        }
    } else {
        out.push("null");   // class instances have no JSON form
    }
}

/// A number as JavaScript prints it in JSON: integers without ".0",
/// non-finite numbers as null.
export function numberText(v: f64): string {
    if (!isFinite(v)) return "null";
    if (v == Math.floor(v) && Math.abs(v) < 9007199254740992) return (<i64>v).toString();
    let s = v.toString();
    if (s.endsWith(".0")) s = s.substring(0, s.length - 2);
    return s;
}

const HEX = "0123456789abcdef";

function quote(s: string): string {
    let clean = true;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 0x20 || c == 0x22 || c == 0x5c) {
            clean = false;
            break;
        }
    }
    if (clean) return "\"" + s + "\"";
    const parts: Array<string> = ["\""];
    let start = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c >= 0x20 && c != 0x22 && c != 0x5c) continue;
        if (i > start) parts.push(s.substring(start, i));
        start = i + 1;
        if (c == 0x22) parts.push("\\\"");
        else if (c == 0x5c) parts.push("\\\\");
        else if (c == 0x0a) parts.push("\\n");
        else if (c == 0x0d) parts.push("\\r");
        else if (c == 0x09) parts.push("\\t");
        else if (c == 0x08) parts.push("\\b");
        else if (c == 0x0c) parts.push("\\f");
        else parts.push("\\u00" + HEX.charAt(c >> 4) + HEX.charAt(c & 15));
    }
    if (start < s.length) parts.push(s.substring(start));
    parts.push("\"");
    return parts.join("");
}
