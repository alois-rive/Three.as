// three.js's SVGLoader addon (r170): SVG to ShapePaths, one per drawn
// element, each with its fill colour, style and source node; static
// helpers turn them into Shapes with holes (createShapes) and strokes into
// triangles (pointsToStroke).
//
//     const data = new SVGLoader(context).load("logo");     // a BlobAsset
//     for (let i = 0; i < data.paths.length; i++) {
//         const path = data.paths[i];
//         const shapes = SVGLoader.createShapes(path);
//         const geometry = new ExtrudeGeometry(shapes, options);
//         const style = path.userData.style;
//         if (style.stroke != "" && style.stroke != "none") {
//             const points = path.subPaths[0].getPoints();
//             const stroke = SVGLoader.pointsToStroke(points, style);
//         }
//     }
//
// Differences from three.js (see docs/DEVIATIONS.md, Loaders):
// - `paths` are SVGShapePaths: a ShapePath with a typed `userData`
//   (`node`, the XMLNode, and `style`, an SVGStyle). Style fields three.js
//   leaves undefined are "" (strings) or 1 (`opacity`).
// - The XML comes from three/addons/libs/dom_parser (AnimaScript has no
//   DOM); <style> sheets from its small CSS parser. CSS element selectors
//   ("rect { ... }") apply too, below class and id selectors (three.js
//   reads class and id selectors only); `display` is kept in the style.
// - `use` reads `href` as well as `xlink:href`; `applyViewBox` (Rive-only,
//   off by default as three.js ignores viewBox) maps <svg> viewBoxes.
// - Malformed number lists stop at the error instead of throwing.

import { Context } from "rive/host";
import { Promise } from "rive/promise";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { BufferGeometry } from "../../core/BufferGeometry";
import { Float32BufferAttribute } from "../../core/BufferAttribute";
import { ShapePath } from "../../extras/core/ShapePath";
import { Shape } from "../../extras/core/Shape";
import { Path } from "../../extras/core/Path";
import { Curve } from "../../extras/core/Curve";
import { LineCurve, CubicBezierCurve, QuadraticBezierCurve, EllipseCurve } from "../../extras/curves/Curves";
import { ShapeUtils } from "../../extras/ShapeUtils";
import { Box2 } from "../../math/Box2";
import { Matrix3 } from "../../math/Matrix3";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { SRGBColorSpace } from "../../constants";
import { DOMParser, XMLNode, CSSStyleDeclaration, CSSRule } from "../libs/dom_parser";

const COLOR_SPACE_SVG = SRGBColorSpace;
const EPSILON: f64 = 2.220446049250313e-16;

/// The presentation style of a path: three.js's `userData.style` object.
/// Strings three.js leaves undefined are "". `strokeColor` is what
/// getStrokeStyle sets (parse sets `stroke`).
export class SVGStyle {
    fill: string = "#000";
    fillOpacity: f64 = 1;
    fillRule: string = "";
    opacity: f64 = 1;
    stroke: string = "";
    strokeOpacity: f64 = 1;
    strokeWidth: f64 = 1;
    strokeLineJoin: string = "miter";
    strokeLineCap: string = "butt";
    strokeMiterLimit: f64 = 4;
    visibility: string = "";
    display: string = "";
    strokeColor: string = "";

    clone(): SVGStyle {
        const s = new SVGStyle();
        s.fill = this.fill;
        s.fillOpacity = this.fillOpacity;
        s.fillRule = this.fillRule;
        s.opacity = this.opacity;
        s.stroke = this.stroke;
        s.strokeOpacity = this.strokeOpacity;
        s.strokeWidth = this.strokeWidth;
        s.strokeLineJoin = this.strokeLineJoin;
        s.strokeLineCap = this.strokeLineCap;
        s.strokeMiterLimit = this.strokeMiterLimit;
        s.visibility = this.visibility;
        s.display = this.display;
        s.strokeColor = this.strokeColor;
        return s;
    }
}

/// three.js's `path.userData`: the element the path came from and its
/// style.
export class SVGShapePathUserData {
    node: XMLNode? = null;
    style: SVGStyle = new SVGStyle();
}

/// A ShapePath with SVGLoader's `userData` (three.js sets an untyped
/// `userData` on the ShapePath).
export class SVGShapePath extends ShapePath {
    userData: SVGShapePathUserData = new SVGShapePathUserData();
}

/// What parse returns: `{ paths, xml }`, `xml` being the root <svg>.
export class SVGResult {
    paths: Array<SVGShapePath>;
    xml: XMLNode?;

    constructor(paths: Array<SVGShapePath>, xml: XMLNode?) {
        this.paths = paths;
        this.xml = xml;
    }
}

export class SVGLoader extends Loader {
    /// Default dots per inch.
    defaultDPI: f64 = 90;
    /// Accepted units: "mm", "cm", "in", "pt", "pc", "px".
    defaultUnit: string = "px";
    /// Rive-only: map each <svg>'s viewBox to its width and height (and
    /// x, y), as a renderer would. three.js ignores viewBox, so this is
    /// off by default and coordinates are the file's user units.
    applyViewBox: bool = false;

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The SVG BlobAsset `name`; null when missing.
    load(name: string): SVGResult? {
        const context = this.context;
        const bytesAsset = context != null ? context.blob(this.path + name) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            if (context != null) context.log("three: SVGLoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        return this.parse(String.UTF8.decode(bytes!));
    }

    /// An https: url or a blob asset name.
    loadAsync(url: string): Promise<SVGResult> {
        return loadSVG(this, url);
    }

    parse(text: string): SVGResult {
        return new SVGParser(this).parse(text);
    }

    /// The shapes (with holes) a path fills, by three.js's scanline test:
    /// a sub-path is a hole when the paths around it say so under the
    /// path's `fill-rule` ("nonzero", the default, or "evenodd").
    static createShapes(shapePath: ShapePath): Array<Shape> {
        return createShapes(shapePath);
    }

    /// A stroke style for pointsToStroke. `lineJoin`: "round", "bevel",
    /// "miter" or "miter-clip"; `lineCap`: "round", "square" or "butt";
    /// `miterLimit` in multiples of the width.
    static getStrokeStyle(width: f64 = 1, color: string = "#000", lineJoin: string = "miter", lineCap: string = "butt",
                          miterLimit: f64 = 4): SVGStyle {
        const style = new SVGStyle();
        style.strokeColor = color;
        style.strokeWidth = width;
        style.strokeLineJoin = lineJoin;
        style.strokeLineCap = lineCap;
        style.strokeMiterLimit = miterLimit;
        return style;
    }

    /// The triangles of a stroke along `points` (open, or closed when the
    /// last point equals the first) in the plane z = 0, with normals and
    /// uvs (u along the path, v across it); null for fewer than 2 points.
    static pointsToStroke(points: Array<Vector2>, style: SVGStyle, arcDivisions: i32 = 12,
                          minDistance: f64 = 0.001): BufferGeometry? {
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        if (SVGLoader.pointsToStrokeWithBuffers(points, style, arcDivisions, minDistance, vertices, normals, uvs) == 0) {
            return null;
        }
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        geometry.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        geometry.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
        return geometry;
    }

    /// pointsToStroke into arrays, from vertex `vertexOffset` on (3 numbers a
    /// vertex in `vertices` and `normals`, 2 in `uvs`; they grow as needed).
    /// Returns three.js's count: 3 per vertex written. With `vertices` null
    /// nothing is written and the count is still right (to size buffers).
    static pointsToStrokeWithBuffers(points: Array<Vector2>, style: SVGStyle, arcDivisions: i32 = 12,
                                     minDistance: f64 = 0.001, vertices: Array<f64>? = null,
                                     normals: Array<f64>? = null, uvs: Array<f64>? = null,
                                     vertexOffset: i32 = 0): i32 {
        return new StrokeBuilder(style, arcDivisions, vertices, normals, uvs).build(points, minDistance, vertexOffset);
    }
}

async function loadSVG(loader: SVGLoader, url: string): Promise<SVGResult> {
    const bytes = await fetchBytes(loader, url);
    return loader.parse(String.UTF8.decode(bytes));
}

// parse(): three.js's nested functions, sharing the parse state.

class SVGParser {
    scope: SVGLoader;
    paths: Array<SVGShapePath> = [];
    stylesheets: Map<string, Map<string, string>> = new Map<string, Map<string, string>>();
    transformStack: Array<Matrix3> = [];
    activeUseIds: Array<string> = [];
    tempTransform0: Matrix3 = new Matrix3();
    tempTransform1: Matrix3 = new Matrix3();
    tempTransform2: Matrix3 = new Matrix3();
    tempTransform3: Matrix3 = new Matrix3();
    tempV2: Vector2 = new Vector2();
    tempV3: Vector3 = new Vector3();
    currentTransform: Matrix3 = new Matrix3();

    constructor(scope: SVGLoader) {
        this.scope = scope;
    }

    parse(text: string): SVGResult {
        const xml = new DOMParser().parseFromString(text, "image/svg+xml");
        const root = xml.documentElement;
        const style = new SVGStyle();
        if (root != null) this.parseNode(root, style);
        return new SVGResult(this.paths, root);
    }

    parseNode(node: XMLNode, inStyle: SVGStyle): void {
        if (node.nodeType != 1) return;
        let style = inStyle;
        const transform = this.getNodeTransform(node);
        let isDefsNode = false;
        let path: SVGShapePath? = null;
        const name = node.nodeName;
        if (name == "svg") {
            style = this.parseStyle(node, style);
        } else if (name == "style") {
            this.parseCSSStylesheet(node);
        } else if (name == "g") {
            style = this.parseStyle(node, style);
        } else if (name == "path") {
            style = this.parseStyle(node, style);
            if (node.hasAttribute("d")) path = this.parsePathNode(node);
        } else if (name == "rect") {
            style = this.parseStyle(node, style);
            path = this.parseRectNode(node);
        } else if (name == "polygon") {
            style = this.parseStyle(node, style);
            path = this.parsePolygonNode(node);
        } else if (name == "polyline") {
            style = this.parseStyle(node, style);
            path = this.parsePolylineNode(node);
        } else if (name == "circle") {
            style = this.parseStyle(node, style);
            path = this.parseCircleNode(node);
        } else if (name == "ellipse") {
            style = this.parseStyle(node, style);
            path = this.parseEllipseNode(node);
        } else if (name == "line") {
            style = this.parseStyle(node, style);
            path = this.parseLineNode(node);
        } else if (name == "defs") {
            isDefsNode = true;
        } else if (name == "use") {
            style = this.parseStyle(node, style);
            let href = node.getAttributeNS("http://www.w3.org/1999/xlink", "href");
            if (href == null) href = node.getAttribute("href");
            const hrefText = href != null ? href! : "";
            const usedNodeId = hrefText.length > 0 ? hrefText.substring(1) : "";
            const viewport = node.viewportElement;
            const usedNode = viewport != null ? viewport.getElementById(usedNodeId) : null;
            if (usedNode != null && !usedNode.contains(node)) {
                if (this.activeUseIds.indexOf(usedNodeId) < 0) {
                    this.activeUseIds.push(usedNodeId);
                    this.parseNode(usedNode, style);
                    this.activeUseIds.pop();
                } else {
                    console.warn("SVGLoader: cyclic 'use node' reference to id: " + usedNodeId);
                }
            } else {
                console.warn("SVGLoader: 'use node' references non-existent node id: " + usedNodeId);
            }
        }

        if (path != null) {
            if (style.fill != "" && style.fill != "none") {
                path.color.setStyle(style.fill, COLOR_SPACE_SVG);
            }
            transformPath(path, this.currentTransform, this);
            this.paths.push(path);
            path.userData.node = node;
            path.userData.style = style;
        }

        const childNodes = node.childNodes;
        for (let i = 0; i < childNodes.length; i++) {
            const child = childNodes[i];
            if (isDefsNode && child.nodeName != "style" && child.nodeName != "defs") {
                // Ignore everything in defs except CSS style definitions and
                // nested defs, because it is OK by the standard to have
                // <style/> there.
                continue;
            }
            this.parseNode(child, style);
        }

        if (transform != null) {
            this.transformStack.pop();
            if (this.transformStack.length > 0) {
                this.currentTransform.copy(this.transformStack[this.transformStack.length - 1]);
            } else {
                this.currentTransform.identity();
            }
        }
    }

    parsePathNode(node: XMLNode): SVGShapePath? {
        const path = new SVGShapePath();
        const point = new Vector2();
        const control = new Vector2();
        const firstPoint = new Vector2();
        let isFirstPoint = true;
        let doSetFirstPoint = false;

        const dAttr = node.getAttribute("d");
        const d = dAttr != null ? dAttr! : "";
        if (d == "" || d == "none") return null;

        const commands = splitPathCommands(d);
        for (let i = 0, l = commands.length; i < l; i++) {
            const command = commands[i];
            const type = command.charAt(0);
            const data = command.slice(1).trim();
            if (isFirstPoint) {
                doSetFirstPoint = true;
                isFirstPoint = false;
            }
            let numbers: Array<f64>;
            if (type == "M") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 2) {
                    point.x = at(numbers, j + 0);
                    point.y = at(numbers, j + 1);
                    control.x = point.x;
                    control.y = point.y;
                    if (j == 0) path.moveTo(point.x, point.y);
                    else path.lineTo(point.x, point.y);
                    if (j == 0) firstPoint.copy(point);
                }
            } else if (type == "H") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j++) {
                    point.x = numbers[j];
                    control.x = point.x;
                    control.y = point.y;
                    path.lineTo(point.x, point.y);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "V") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j++) {
                    point.y = numbers[j];
                    control.x = point.x;
                    control.y = point.y;
                    path.lineTo(point.x, point.y);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "L") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 2) {
                    point.x = at(numbers, j + 0);
                    point.y = at(numbers, j + 1);
                    control.x = point.x;
                    control.y = point.y;
                    path.lineTo(point.x, point.y);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "C") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 6) {
                    path.bezierCurveTo(at(numbers, j + 0), at(numbers, j + 1), at(numbers, j + 2), at(numbers, j + 3),
                        at(numbers, j + 4), at(numbers, j + 5));
                    control.x = at(numbers, j + 2);
                    control.y = at(numbers, j + 3);
                    point.x = at(numbers, j + 4);
                    point.y = at(numbers, j + 5);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "S") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 4) {
                    path.bezierCurveTo(getReflection(point.x, control.x), getReflection(point.y, control.y),
                        at(numbers, j + 0), at(numbers, j + 1), at(numbers, j + 2), at(numbers, j + 3));
                    control.x = at(numbers, j + 0);
                    control.y = at(numbers, j + 1);
                    point.x = at(numbers, j + 2);
                    point.y = at(numbers, j + 3);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "Q") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 4) {
                    path.quadraticCurveTo(at(numbers, j + 0), at(numbers, j + 1), at(numbers, j + 2), at(numbers, j + 3));
                    control.x = at(numbers, j + 0);
                    control.y = at(numbers, j + 1);
                    point.x = at(numbers, j + 2);
                    point.y = at(numbers, j + 3);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "T") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 2) {
                    const rx = getReflection(point.x, control.x);
                    const ry = getReflection(point.y, control.y);
                    path.quadraticCurveTo(rx, ry, at(numbers, j + 0), at(numbers, j + 1));
                    control.x = rx;
                    control.y = ry;
                    point.x = at(numbers, j + 0);
                    point.y = at(numbers, j + 1);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "A") {
                numbers = parseFloats(data, [3, 4], 7);
                for (let j = 0, jl = numbers.length; j < jl; j += 7) {
                    // Skip the command if start point == end point.
                    if (at(numbers, j + 5) == point.x && at(numbers, j + 6) == point.y) continue;
                    const start = point.clone();
                    point.x = at(numbers, j + 5);
                    point.y = at(numbers, j + 6);
                    control.x = point.x;
                    control.y = point.y;
                    parseArcCommand(path, at(numbers, j), at(numbers, j + 1), at(numbers, j + 2), at(numbers, j + 3),
                        at(numbers, j + 4), start, point);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "m") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 2) {
                    point.x += at(numbers, j + 0);
                    point.y += at(numbers, j + 1);
                    control.x = point.x;
                    control.y = point.y;
                    if (j == 0) path.moveTo(point.x, point.y);
                    else path.lineTo(point.x, point.y);
                    if (j == 0) firstPoint.copy(point);
                }
            } else if (type == "h") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j++) {
                    point.x += numbers[j];
                    control.x = point.x;
                    control.y = point.y;
                    path.lineTo(point.x, point.y);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "v") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j++) {
                    point.y += numbers[j];
                    control.x = point.x;
                    control.y = point.y;
                    path.lineTo(point.x, point.y);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "l") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 2) {
                    point.x += at(numbers, j + 0);
                    point.y += at(numbers, j + 1);
                    control.x = point.x;
                    control.y = point.y;
                    path.lineTo(point.x, point.y);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "c") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 6) {
                    path.bezierCurveTo(point.x + at(numbers, j + 0), point.y + at(numbers, j + 1),
                        point.x + at(numbers, j + 2), point.y + at(numbers, j + 3),
                        point.x + at(numbers, j + 4), point.y + at(numbers, j + 5));
                    control.x = point.x + at(numbers, j + 2);
                    control.y = point.y + at(numbers, j + 3);
                    point.x += at(numbers, j + 4);
                    point.y += at(numbers, j + 5);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "s") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 4) {
                    path.bezierCurveTo(getReflection(point.x, control.x), getReflection(point.y, control.y),
                        point.x + at(numbers, j + 0), point.y + at(numbers, j + 1),
                        point.x + at(numbers, j + 2), point.y + at(numbers, j + 3));
                    control.x = point.x + at(numbers, j + 0);
                    control.y = point.y + at(numbers, j + 1);
                    point.x += at(numbers, j + 2);
                    point.y += at(numbers, j + 3);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "q") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 4) {
                    path.quadraticCurveTo(point.x + at(numbers, j + 0), point.y + at(numbers, j + 1),
                        point.x + at(numbers, j + 2), point.y + at(numbers, j + 3));
                    control.x = point.x + at(numbers, j + 0);
                    control.y = point.y + at(numbers, j + 1);
                    point.x += at(numbers, j + 2);
                    point.y += at(numbers, j + 3);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "t") {
                numbers = parseFloats(data);
                for (let j = 0, jl = numbers.length; j < jl; j += 2) {
                    const rx = getReflection(point.x, control.x);
                    const ry = getReflection(point.y, control.y);
                    path.quadraticCurveTo(rx, ry, point.x + at(numbers, j + 0), point.y + at(numbers, j + 1));
                    control.x = rx;
                    control.y = ry;
                    point.x = point.x + at(numbers, j + 0);
                    point.y = point.y + at(numbers, j + 1);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "a") {
                numbers = parseFloats(data, [3, 4], 7);
                for (let j = 0, jl = numbers.length; j < jl; j += 7) {
                    // Skip the command if there is no displacement.
                    if (at(numbers, j + 5) == 0 && at(numbers, j + 6) == 0) continue;
                    const start = point.clone();
                    point.x += at(numbers, j + 5);
                    point.y += at(numbers, j + 6);
                    control.x = point.x;
                    control.y = point.y;
                    parseArcCommand(path, at(numbers, j), at(numbers, j + 1), at(numbers, j + 2), at(numbers, j + 3),
                        at(numbers, j + 4), start, point);
                    if (j == 0 && doSetFirstPoint) firstPoint.copy(point);
                }
            } else if (type == "Z" || type == "z") {
                const current = path.currentPath;
                if (current != null) {
                    current.autoClose = true;
                    if (current.curves.length > 0) {
                        // Reset point to beginning of Path.
                        point.copy(firstPoint);
                        current.currentPoint.copy(point);
                        isFirstPoint = true;
                    }
                }
            } else {
                console.warn(command);
            }
            doSetFirstPoint = false;
        }
        return path;
    }

    /// The rules of a <style> element into `stylesheets`, by selector.
    parseCSSStylesheet(node: XMLNode): void {
        const sheet = node.sheet;
        if (sheet == null || sheet.cssRules.length == 0) return;
        for (let i = 0; i < sheet.cssRules.length; i++) {
            const stylesheet = sheet.cssRules[i];
            if (stylesheet.type != CSSRule.STYLE_RULE) continue;
            const parts = stylesheet.selectorText.split(",");
            const selectorList: Array<string> = [];
            for (let k = 0; k < parts.length; k++) {
                const sel = parts[k].trim();
                if (sel.length > 0) selectorList.push(sel);
            }
            for (let j = 0; j < selectorList.length; j++) {
                const key = selectorList[j];
                let definitions = this.stylesheets.has(key) ? this.stylesheets.get(key) : new Map<string, string>();
                const decl = stylesheet.style;
                for (let k = 0; k < decl.length; k++) {
                    const prop = decl.item(k);
                    const value = decl.getPropertyValue(prop);
                    if (value != "") definitions.set(prop, value);
                }
                this.stylesheets.set(key, definitions);
            }
        }
    }

    // https://www.w3.org/TR/SVG/shapes.html#RectElementRXAttribute: rounded
    // corners should be elliptical arcs, but Bézier curves do the job well
    // enough.
    parseRectNode(node: XMLNode): SVGShapePath {
        const x = this.parseFloatWithUnits(attrOr(node, "x", "0"));
        const y = this.parseFloatWithUnits(attrOr(node, "y", "0"));
        const rx = this.parseFloatWithUnits(attrOr(node, "rx", attrOr(node, "ry", "0")));
        const ry = this.parseFloatWithUnits(attrOr(node, "ry", attrOr(node, "rx", "0")));
        const w = this.parseFloatWithUnits(attrOr(node, "width", ""));
        const h = this.parseFloatWithUnits(attrOr(node, "height", ""));

        // Ellipse arc to Bézier approximation coefficient (inverted), see
        // https://spencermortensen.com/articles/bezier-circle/
        const bci = 1 - 0.551915024494;
        const path = new SVGShapePath();
        // Top left.
        path.moveTo(x + rx, y);
        // Top right.
        path.lineTo(x + w - rx, y);
        if (rx != 0 || ry != 0) path.bezierCurveTo(x + w - rx * bci, y, x + w, y + ry * bci, x + w, y + ry);
        // Bottom right.
        path.lineTo(x + w, y + h - ry);
        if (rx != 0 || ry != 0) path.bezierCurveTo(x + w, y + h - ry * bci, x + w - rx * bci, y + h, x + w - rx, y + h);
        // Bottom left.
        path.lineTo(x + rx, y + h);
        if (rx != 0 || ry != 0) path.bezierCurveTo(x + rx * bci, y + h, x, y + h - ry * bci, x, y + h - ry);
        // Back to top left.
        path.lineTo(x, y + ry);
        if (rx != 0 || ry != 0) path.bezierCurveTo(x, y + ry * bci, x + rx * bci, y, x + rx, y);
        return path;
    }

    parsePolygonNode(node: XMLNode): SVGShapePath {
        const path = this.parsePoints(node);
        const current = path.currentPath;
        if (current != null) current.autoClose = true;
        return path;
    }

    parsePolylineNode(node: XMLNode): SVGShapePath {
        const path = this.parsePoints(node);
        const current = path.currentPath;
        if (current != null) current.autoClose = false;
        return path;
    }

    /// A polygon's or polyline's `points`: number pairs, the first a moveTo.
    parsePoints(node: XMLNode): SVGShapePath {
        const path = new SVGShapePath();
        const numbers = pointNumbers(attrOr(node, "points", ""));
        let index = 0;
        for (let k = 0; k + 1 < numbers.length; k += 2) {
            const x = this.parseFloatWithUnits(numbers[k]);
            const y = this.parseFloatWithUnits(numbers[k + 1]);
            if (index == 0) path.moveTo(x, y);
            else path.lineTo(x, y);
            index++;
        }
        return path;
    }

    parseCircleNode(node: XMLNode): SVGShapePath {
        const x = this.parseFloatWithUnits(attrOr(node, "cx", "0"));
        const y = this.parseFloatWithUnits(attrOr(node, "cy", "0"));
        const r = this.parseFloatWithUnits(attrOr(node, "r", "0"));
        const subpath = new Path();
        subpath.absarc(x, y, r, 0, Math.PI * 2);
        const path = new SVGShapePath();
        path.subPaths.push(subpath);
        return path;
    }

    parseEllipseNode(node: XMLNode): SVGShapePath {
        const x = this.parseFloatWithUnits(attrOr(node, "cx", "0"));
        const y = this.parseFloatWithUnits(attrOr(node, "cy", "0"));
        const rx = this.parseFloatWithUnits(attrOr(node, "rx", "0"));
        const ry = this.parseFloatWithUnits(attrOr(node, "ry", "0"));
        const subpath = new Path();
        subpath.absellipse(x, y, rx, ry, 0, Math.PI * 2);
        const path = new SVGShapePath();
        path.subPaths.push(subpath);
        return path;
    }

    parseLineNode(node: XMLNode): SVGShapePath {
        const x1 = this.parseFloatWithUnits(attrOr(node, "x1", "0"));
        const y1 = this.parseFloatWithUnits(attrOr(node, "y1", "0"));
        const x2 = this.parseFloatWithUnits(attrOr(node, "x2", "0"));
        const y2 = this.parseFloatWithUnits(attrOr(node, "y2", "0"));
        const path = new SVGShapePath();
        path.moveTo(x1, y1);
        path.lineTo(x2, y2);
        const current = path.currentPath;
        if (current != null) current.autoClose = false;
        return path;
    }

    /// The node's style over the inherited one: presentation attributes,
    /// then stylesheet rules (element, class, then id selectors), then the
    /// style attribute.
    parseStyle(node: XMLNode, inStyle: SVGStyle): SVGStyle {
        const style = inStyle.clone();
        const stylesheetStyles = new Map<string, string>();
        // Element selectors (three.js reads class and id selectors only).
        this.assignStyles(stylesheetStyles, node.nodeName);
        const classAttr = node.getAttribute("class");
        if (classAttr != null) {
            const classSelectors = splitWhitespace(classAttr!);
            for (let i = 0; i < classSelectors.length; i++) this.assignStyles(stylesheetStyles, "." + classSelectors[i]);
        }
        const id = node.getAttribute("id");
        if (id != null) this.assignStyles(stylesheetStyles, "#" + id!);

        const inline = node.style;
        let v = styleValue(node, stylesheetStyles, inline, "fill");
        if (v != null) style.fill = copyValue(v!);
        v = styleValue(node, stylesheetStyles, inline, "fill-opacity");
        if (v != null) style.fillOpacity = this.clamp(v!);
        v = styleValue(node, stylesheetStyles, inline, "fill-rule");
        if (v != null) style.fillRule = copyValue(v!);
        v = styleValue(node, stylesheetStyles, inline, "opacity");
        if (v != null) style.opacity = this.clamp(v!);
        v = styleValue(node, stylesheetStyles, inline, "stroke");
        if (v != null) style.stroke = copyValue(v!);
        v = styleValue(node, stylesheetStyles, inline, "stroke-opacity");
        if (v != null) style.strokeOpacity = this.clamp(v!);
        v = styleValue(node, stylesheetStyles, inline, "stroke-width");
        if (v != null) style.strokeWidth = this.positive(v!);
        v = styleValue(node, stylesheetStyles, inline, "stroke-linejoin");
        if (v != null) style.strokeLineJoin = copyValue(v!);
        v = styleValue(node, stylesheetStyles, inline, "stroke-linecap");
        if (v != null) style.strokeLineCap = copyValue(v!);
        v = styleValue(node, stylesheetStyles, inline, "stroke-miterlimit");
        if (v != null) style.strokeMiterLimit = this.positive(v!);
        v = styleValue(node, stylesheetStyles, inline, "visibility");
        if (v != null) style.visibility = copyValue(v!);
        v = styleValue(node, stylesheetStyles, inline, "display");
        if (v != null) style.display = copyValue(v!);
        return style;
    }

    private assignStyles(target: Map<string, string>, selector: string): void {
        if (!this.stylesheets.has(selector)) return;
        const source = this.stylesheets.get(selector);
        const keys = source.keys();
        for (let i = 0; i < keys.length; i++) target.set(keys[i], source.get(keys[i]));
    }

    private clamp(v: string): f64 { return Math.max(0, Math.min(1, this.parseFloatWithUnits(v))); }
    private positive(v: string): f64 { return Math.max(0, this.parseFloatWithUnits(v)); }

    // Units.

    parseFloatWithUnits(input: string): f64 {
        let theUnit = "px";
        let s = input;
        for (let i = 0, n = UNITS.length; i < n; i++) {
            const u = UNITS[i];
            if (s.endsWith(u)) {
                theUnit = u;
                s = s.substring(0, s.length - u.length);
                break;
            }
        }
        let scale: f64;
        const defaultUnit = this.scope.defaultUnit;
        if (theUnit == "px" && defaultUnit != "px") {
            // Conversion scale from pixels to inches, then to default units.
            scale = unitConversion("in", defaultUnit) / this.scope.defaultDPI;
        } else {
            scale = unitConversion(theUnit, defaultUnit);
            if (scale < 0) {
                // Conversion scale to pixels.
                scale = unitConversion(theUnit, "in") * this.scope.defaultDPI;
            }
        }
        return scale * parseFloat(s);
    }

    // Transforms.

    getNodeTransform(node: XMLNode): Matrix3? {
        if (!(node.hasAttribute("transform") || (node.nodeName == "use" && (node.hasAttribute("x") || node.hasAttribute("y")))
            || this.hasViewBoxTransform(node))) {
            return null;
        }
        const transform = this.parseNodeTransform(node);
        if (this.transformStack.length > 0) {
            transform.premultiply(this.transformStack[this.transformStack.length - 1]);
        }
        this.currentTransform.copy(transform);
        this.transformStack.push(transform);
        return transform;
    }

    private hasViewBoxTransform(node: XMLNode): bool {
        return this.scope.applyViewBox && node.nodeName == "svg" && node.hasAttribute("viewBox");
    }

    parseNodeTransform(node: XMLNode): Matrix3 {
        const transform = new Matrix3();
        const currentTransform = this.tempTransform0;

        if (node.nodeName == "use" && (node.hasAttribute("x") || node.hasAttribute("y"))) {
            const tx = this.parseFloatWithUnits(attrOr(node, "x", "0"));
            const ty = this.parseFloatWithUnits(attrOr(node, "y", "0"));
            transform.translate(tx, ty);
        }

        if (this.hasViewBoxTransform(node)) this.viewBoxTransform(node, transform);

        if (node.hasAttribute("transform")) {
            const transformsTexts = node.getAttribute("transform")!.split(")");
            for (let tIndex = transformsTexts.length - 1; tIndex >= 0; tIndex--) {
                let transformText = transformsTexts[tIndex].trim();
                // SVG allows commas between transforms.
                while (transformText.startsWith(",")) transformText = transformText.substring(1).trim();
                if (transformText == "") continue;
                const openParPos = transformText.indexOf("(");
                const closeParPos = transformText.length;
                if (openParPos > 0 && openParPos < closeParPos) {
                    const transformType = transformText.slice(0, openParPos).trim();
                    const array = parseFloats(transformText.slice(openParPos + 1));
                    currentTransform.identity();
                    if (transformType == "translate") {
                        if (array.length >= 1) {
                            const tx = array[0];
                            let ty: f64 = 0;
                            if (array.length >= 2) ty = array[1];
                            currentTransform.translate(tx, ty);
                        }
                    } else if (transformType == "rotate") {
                        if (array.length >= 1) {
                            let cx: f64 = 0;
                            let cy: f64 = 0;
                            // Angle.
                            const angle = array[0] * Math.PI / 180;
                            if (array.length >= 3) {
                                // Center x, y.
                                cx = array[1];
                                cy = array[2];
                            }
                            // Rotate around center (cx, cy).
                            this.tempTransform1.makeTranslation(-cx, -cy);
                            this.tempTransform2.makeRotation(angle);
                            this.tempTransform3.multiplyMatrices(this.tempTransform2, this.tempTransform1);
                            this.tempTransform1.makeTranslation(cx, cy);
                            currentTransform.multiplyMatrices(this.tempTransform1, this.tempTransform3);
                        }
                    } else if (transformType == "scale") {
                        if (array.length >= 1) {
                            const scaleX = array[0];
                            let scaleY = scaleX;
                            if (array.length >= 2) scaleY = array[1];
                            currentTransform.scale(scaleX, scaleY);
                        }
                    } else if (transformType == "skewX") {
                        if (array.length == 1) {
                            currentTransform.set(1, Math.tan(array[0] * Math.PI / 180), 0, 0, 1, 0, 0, 0, 1);
                        }
                    } else if (transformType == "skewY") {
                        if (array.length == 1) {
                            currentTransform.set(1, 0, 0, Math.tan(array[0] * Math.PI / 180), 1, 0, 0, 0, 1);
                        }
                    } else if (transformType == "matrix") {
                        if (array.length == 6) {
                            currentTransform.set(array[0], array[2], array[4], array[1], array[3], array[5], 0, 0, 1);
                        }
                    }
                }
                transform.premultiply(currentTransform);
            }
        }
        return transform;
    }

    /// Rive-only (applyViewBox): an <svg>'s viewBox onto its x, y, width
    /// and height, with preserveAspectRatio (xMidYMid meet by default).
    private viewBoxTransform(node: XMLNode, transform: Matrix3): void {
        const vb = parseFloats(attrOr(node, "viewBox", ""));
        if (vb.length < 4 || vb[2] <= 0 || vb[3] <= 0) return;
        const widthAttr = attrOr(node, "width", "");
        const heightAttr = attrOr(node, "height", "");
        const width = widthAttr == "" || widthAttr.endsWith("%") ? vb[2] : this.parseFloatWithUnits(widthAttr);
        const height = heightAttr == "" || heightAttr.endsWith("%") ? vb[3] : this.parseFloatWithUnits(heightAttr);
        let sx = width / vb[2];
        let sy = height / vb[3];
        let tx: f64 = 0, ty: f64 = 0;
        const par = splitWhitespace(attrOr(node, "preserveAspectRatio", "xMidYMid meet"));
        const align = par.length > 0 ? par[0] : "xMidYMid";
        if (align != "none") {
            const slice = par.length > 1 && par[1] == "slice";
            const s = slice ? Math.max(sx, sy) : Math.min(sx, sy);
            sx = s;
            sy = s;
            const freeX = width - vb[2] * s, freeY = height - vb[3] * s;
            if (align.indexOf("xMid") >= 0) tx = freeX / 2;
            else if (align.indexOf("xMax") >= 0) tx = freeX;
            if (align.indexOf("YMid") >= 0) ty = freeY / 2;
            else if (align.indexOf("YMax") >= 0) ty = freeY;
        }
        // Nested <svg>s are placed at their x, y.
        if (node.parentNode != null && node.parentNode!.nodeType == XMLNode.ELEMENT_NODE) {
            tx += this.parseFloatWithUnits(attrOr(node, "x", "0"));
            ty += this.parseFloatWithUnits(attrOr(node, "y", "0"));
        }
        const m = this.tempTransform1;
        m.makeTranslation(-vb[0], -vb[1]);
        transform.premultiply(m);
        m.makeScale(sx, sy);
        transform.premultiply(m);
        m.makeTranslation(tx, ty);
        transform.premultiply(m);
    }
}

// Path parsing helpers.

/// d.match(/[a-df-z][^a-df-z]*/ig): each command letter with its numbers.
function splitPathCommands(d: string): Array<string> {
    const out: Array<string> = [];
    let start = -1;
    for (let i = 0; i < d.length; i++) {
        const c = d.charCodeAt(i) | 32;
        if (c >= 97 && c <= 122 && c != 101) {
            if (start >= 0) out.push(d.substring(start, i));
            start = i;
        }
    }
    if (start >= 0) out.push(d.substring(start));
    return out;
}

/// numbers[i], or NaN past the end (where JavaScript reads undefined).
function at(numbers: Array<f64>, i: i32): f64 {
    return i < numbers.length ? numbers[i] : NaN;
}

/// The attribute, or `fallback` when it is missing or empty (three.js's
/// `node.getAttribute(name) || fallback`).
function attrOr(node: XMLNode, name: string, fallback: string): string {
    const v = node.getAttribute(name);
    return v != null && v!.length > 0 ? v! : fallback;
}

/// Polygon / polyline points: the numbers of the list, as strings (three.js
/// matches "x,y" / "x y" pairs with a regular expression).
function pointNumbers(text: string): Array<string> {
    const out: Array<string> = [];
    let i = 0;
    const n = text.length;
    while (i < n) {
        const c = text.charCodeAt(i);
        const startsNumber = (c >= 48 && c <= 57) || c == 46 || c == 43 || c == 45;
        if (!startsNumber) {
            i++;
            continue;
        }
        const start = i;
        i++;
        let seenPoint = c == 46;
        let seenExp = false;
        while (i < n) {
            const d = text.charCodeAt(i);
            if (d >= 48 && d <= 57) {
                i++;
            } else if (d == 46 && !seenPoint && !seenExp) {
                seenPoint = true;
                i++;
            } else if ((d == 101 || d == 69) && !seenExp) {
                seenExp = true;
                i++;
                if (i < n && (text.charCodeAt(i) == 43 || text.charCodeAt(i) == 45)) i++;
            } else {
                break;
            }
        }
        out.push(text.substring(start, i));
    }
    return out;
}

function splitWhitespace(text: string): Array<string> {
    const out: Array<string> = [];
    let start = -1;
    for (let i = 0; i <= text.length; i++) {
        const c = i < text.length ? text.charCodeAt(i) : 32;
        const space = c == 32 || c == 9 || c == 10 || c == 13 || c == 12;
        if (space) {
            if (start >= 0) out.push(text.substring(start, i));
            start = -1;
        } else if (start < 0) {
            start = i;
        }
    }
    return out;
}

/// The winning value of a style property: the presentation attribute,
/// overridden by a stylesheet rule, overridden by the style attribute.
function styleValue(node: XMLNode, stylesheetStyles: Map<string, string>, inline: CSSStyleDeclaration,
                    svgName: string): string? {
    let value: string? = null;
    const attr = node.getAttribute(svgName);
    if (attr != null) value = attr;
    if (stylesheetStyles.has(svgName) && stylesheetStyles.get(svgName) != "") value = stylesheetStyles.get(svgName);
    const fromStyle = inline.getPropertyValue(svgName);
    if (fromStyle != "") value = fromStyle;
    return value;
}

function copyValue(v: string): string {
    if (v.startsWith("url")) console.warn("SVGLoader: url access in attributes is not implemented.");
    return v;
}

/// http://www.w3.org/TR/SVG11/implnote.html#PathElementImplementationNotes
function getReflection(a: f64, b: f64): f64 {
    return a - (b - a);
}

// https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes
// https://mortoray.com/2017/02/16/rendering-an-svg-elliptical-arc-as-bezier-curves/
// Appendix: Endpoint to center arc conversion. From
//   rx ry x-axis-rotation large-arc-flag sweep-flag x y
// to
//   aX, aY, xRadius, yRadius, aStartAngle, aEndAngle, aClockwise, aRotation
function parseArcCommand(path: ShapePath, rxIn: f64, ryIn: f64, xAxisRotationIn: f64, largeArcFlag: f64,
                         sweepFlag: f64, start: Vector2, end: Vector2): void {
    if (rxIn == 0 || ryIn == 0) {
        // Draw a line if either of the radii == 0.
        path.lineTo(end.x, end.y);
        return;
    }
    const xAxisRotation = xAxisRotationIn * Math.PI / 180;
    // Ensure radii are positive.
    let rx = Math.abs(rxIn);
    let ry = Math.abs(ryIn);
    // Compute (x1', y1').
    const dx2 = (start.x - end.x) / 2.0;
    const dy2 = (start.y - end.y) / 2.0;
    const x1p = Math.cos(xAxisRotation) * dx2 + Math.sin(xAxisRotation) * dy2;
    const y1p = -Math.sin(xAxisRotation) * dx2 + Math.cos(xAxisRotation) * dy2;
    // Compute (cx', cy').
    let rxs = rx * rx;
    let rys = ry * ry;
    const x1ps = x1p * x1p;
    const y1ps = y1p * y1p;
    // Ensure radii are large enough.
    const cr = x1ps / rxs + y1ps / rys;
    if (cr > 1) {
        // Scale up rx, ry equally so cr == 1.
        const s = Math.sqrt(cr);
        rx = s * rx;
        ry = s * ry;
        rxs = rx * rx;
        rys = ry * ry;
    }
    const dq = rxs * y1ps + rys * x1ps;
    const pq = (rxs * rys - dq) / dq;
    let q = Math.sqrt(Math.max(0, pq));
    if (largeArcFlag == sweepFlag) q = -q;
    const cxp = q * rx * y1p / ry;
    const cyp = -q * ry * x1p / rx;
    // Step 3: Compute (cx, cy) from (cx', cy').
    const cx = Math.cos(xAxisRotation) * cxp - Math.sin(xAxisRotation) * cyp + (start.x + end.x) / 2;
    const cy = Math.sin(xAxisRotation) * cxp + Math.cos(xAxisRotation) * cyp + (start.y + end.y) / 2;
    // Step 4: Compute θ1 and Δθ.
    const theta = svgAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    const delta = svgAngle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry) % (Math.PI * 2);
    let current = path.currentPath;
    if (current == null) {
        // An arc with no current point (three.js throws).
        path.moveTo(start.x, start.y);
        current = path.currentPath;
    }
    current!.absellipse(cx, cy, rx, ry, theta, theta + delta, sweepFlag == 0, xAxisRotation);
}

function svgAngle(ux: f64, uy: f64, vx: f64, vy: f64): f64 {
    const dot = ux * vx + uy * vy;
    const len = Math.sqrt(ux * ux + uy * uy) * Math.sqrt(vx * vx + vy * vy);
    // Floating point precision: slightly over values appear.
    let ang = Math.acos(Math.max(-1, Math.min(1, dot / len)));
    if ((ux * vy - uy * vx) < 0) ang = -ang;
    return ang;
}

const SEP = 0;
const INT = 1;
const FLOAT = 2;
const EXP = 3;

function isWhitespace(c: i32): bool { return c == 32 || c == 9 || c == 13 || c == 10; }
function isDigit(c: i32): bool { return c >= 48 && c <= 57; }
function isSign(c: i32): bool { return c == 45 || c == 43; }

/// The numbers of an SVG number list, from https://github.com/ppvg/svg-numbers
/// (MIT License). `flags`: positions (modulo `stride`) holding one-digit arc
/// flags, which need no separator ("a1 1 0 01 5 5"). On a syntax error the
/// numbers so far are returned (three.js throws).
export function parseFloats(input: string, flags: Array<i32>? = null, stride: i32 = 0): Array<f64> {
    let state = SEP;
    let seenComma = true;
    let number = "";
    let exponent = "";
    const result: Array<f64> = [];
    const length = input.length;
    for (let i = 0; i < length; i++) {
        const current = input.charCodeAt(i);
        // Check for flags.
        if (flags != null && stride > 0 && flags.includes(result.length % stride) && (current == 48 || current == 49)) {
            state = INT;
            number = String.fromCharCode(current);
            newNumber(result, number, exponent);
            number = "";
            exponent = "";
            continue;
        }
        // Parse until next number.
        if (state == SEP) {
            // Eat whitespace.
            if (isWhitespace(current)) continue;
            // Start new number.
            if (isDigit(current) || isSign(current)) {
                state = INT;
                number = String.fromCharCode(current);
                continue;
            }
            if (current == 46) {
                state = FLOAT;
                number = String.fromCharCode(current);
                continue;
            }
            // Throw on double commas (e.g. "1, , 2").
            if (current == 44) {
                if (seenComma) return result;
                seenComma = true;
            }
        }
        // Parse integer part.
        if (state == INT) {
            if (isDigit(current)) {
                number += String.fromCharCode(current);
                continue;
            }
            if (current == 46) {
                number += String.fromCharCode(current);
                state = FLOAT;
                continue;
            }
            if (current == 101 || current == 69) {
                state = EXP;
                continue;
            }
            // Throw on double signs ("-+1"), but not on sign as separator ("-1-2").
            if (isSign(current) && number.length == 1 && isSign(number.charCodeAt(0))) return result;
        }
        // Parse decimal part.
        if (state == FLOAT) {
            if (isDigit(current)) {
                number += String.fromCharCode(current);
                continue;
            }
            if (current == 101 || current == 69) {
                state = EXP;
                continue;
            }
            // Throw on double decimal points (e.g. "1..2").
            if (current == 46 && number.length > 0 && number.charCodeAt(number.length - 1) == 46) return result;
        }
        // Parse exponent part.
        if (state == EXP) {
            if (isDigit(current)) {
                exponent += String.fromCharCode(current);
                continue;
            }
            if (isSign(current)) {
                if (exponent == "") {
                    exponent += String.fromCharCode(current);
                    continue;
                }
                if (exponent.length == 1 && isSign(exponent.charCodeAt(0))) return result;
            }
        }
        // End of number.
        if (isWhitespace(current)) {
            newNumber(result, number, exponent);
            number = "";
            exponent = "";
            state = SEP;
            seenComma = false;
        } else if (current == 44) {
            newNumber(result, number, exponent);
            number = "";
            exponent = "";
            state = SEP;
            seenComma = true;
        } else if (isSign(current)) {
            newNumber(result, number, exponent);
            exponent = "";
            state = INT;
            number = String.fromCharCode(current);
        } else if (current == 46) {
            newNumber(result, number, exponent);
            exponent = "";
            state = FLOAT;
            number = String.fromCharCode(current);
        } else {
            return result;
        }
    }
    // Add the last number found (if any).
    newNumber(result, number, exponent);
    return result;
}

function newNumber(result: Array<f64>, number: string, exponent: string): void {
    if (number == "") return;
    if (exponent == "") result.push(jsNumber(number));
    else result.push(jsNumber(number) * Math.pow(10, jsNumber(exponent)));
}

/// JavaScript's Number(s) for the strings parseFloats builds: a sign or a
/// point alone is NaN.
function jsNumber(s: string): f64 {
    if (s == "+" || s == "-" || s == "." || s == "+." || s == "-.") return NaN;
    return parseFloat(s);
}

// Units: [fromUnit][toUnit] (-1 means dpi dependent).

const UNITS: Array<string> = ["mm", "cm", "in", "pt", "pc", "px"];

function unitConversion(from: string, to: string): f64 {
    const f = UNITS.indexOf(from), t = UNITS.indexOf(to);
    if (f < 0 || t < 0) return NaN;
    if (f == 5) return t == 5 ? 1 : NaN;
    if (t == 5) return -1;
    // Each unit in inches.
    const inches: Array<f64> = [1 / 25.4, 1 / 2.54, 1, 1 / 72, 1 / 6];
    return inches[f] / inches[t];
}

// transformPath and its helpers.

function transfVec2(v2: Vector2, m: Matrix3, parser: SVGParser): void {
    parser.tempV3.set(v2.x, v2.y, 1).applyMatrix3(m);
    v2.set(parser.tempV3.x, parser.tempV3.y);
}

function transformPath(path: ShapePath, m: Matrix3, parser: SVGParser): void {
    const subPaths = path.subPaths;
    for (let i = 0, n = subPaths.length; i < n; i++) {
        const subPath = subPaths[i];
        const curves = subPath.curves;
        for (let j = 0; j < curves.length; j++) {
            const curve = curves[j];
            if (curve instanceof LineCurve) {
                const c = curve as LineCurve;
                transfVec2(c.v1, m, parser);
                transfVec2(c.v2, m, parser);
            } else if (curve instanceof CubicBezierCurve) {
                const c = curve as CubicBezierCurve;
                transfVec2(c.v0, m, parser);
                transfVec2(c.v1, m, parser);
                transfVec2(c.v2, m, parser);
                transfVec2(c.v3, m, parser);
            } else if (curve instanceof QuadraticBezierCurve) {
                const c = curve as QuadraticBezierCurve;
                transfVec2(c.v0, m, parser);
                transfVec2(c.v1, m, parser);
                transfVec2(c.v2, m, parser);
            } else if (curve instanceof EllipseCurve) {
                const c = curve as EllipseCurve;
                // Transform the ellipse's center point.
                parser.tempV2.set(c.aX, c.aY);
                transfVec2(parser.tempV2, m, parser);
                c.aX = parser.tempV2.x;
                c.aY = parser.tempV2.y;
                // Transform the ellipse's shape parameters.
                if (isTransformSkewed(m)) transfEllipseGeneric(c, m, parser);
                else transfEllipseNoSkew(c, m);
            }
        }
    }
}

/// For the maths see https://math.stackexchange.com/questions/4544164
function transfEllipseGeneric(curve: EllipseCurve, m: Matrix3, parser: SVGParser): void {
    const a = curve.xRadius;
    const b = curve.yRadius;
    const cosTheta = Math.cos(curve.aRotation);
    const sinTheta = Math.sin(curve.aRotation);
    const v1 = new Vector3(a * cosTheta, a * sinTheta, 0);
    const v2 = new Vector3(-b * sinTheta, b * cosTheta, 0);
    const f1 = v1.applyMatrix3(m);
    const f2 = v2.applyMatrix3(m);
    const mF = parser.tempTransform0.set(f1.x, f2.x, 0, f1.y, f2.y, 0, 0, 0, 1);
    const mFInv = parser.tempTransform1.copy(mF).invert();
    const mFInvT = parser.tempTransform2.copy(mFInv).transpose();
    const mQ = mFInvT.multiply(mFInv);
    const mQe = mQ.elements;
    const ed = eigenDecomposition(mQe[0], mQe[1], mQe[4]);
    const rt1sqrt = Math.sqrt(ed.rt1);
    const rt2sqrt = Math.sqrt(ed.rt2);
    curve.xRadius = 1 / rt1sqrt;
    curve.yRadius = 1 / rt2sqrt;
    curve.aRotation = Math.atan2(ed.sn, ed.cs);
    const isFullEllipse = (curve.aEndAngle - curve.aStartAngle) % (2 * Math.PI) < EPSILON;
    // Do not touch the angles of a full ellipse: after the transformation
    // they would converge to a single value, removing the whole curve.
    if (!isFullEllipse) {
        const mDsqrt = parser.tempTransform1.set(rt1sqrt, 0, 0, 0, rt2sqrt, 0, 0, 0, 1);
        const mRT = parser.tempTransform2.set(ed.cs, ed.sn, 0, -ed.sn, ed.cs, 0, 0, 0, 1);
        const mDRF = mDsqrt.multiply(mRT).multiply(mF);
        curve.aStartAngle = transformAngle(curve.aStartAngle, mDRF);
        curve.aEndAngle = transformAngle(curve.aEndAngle, mDRF);
        if (isTransformFlipped(m)) curve.aClockwise = !curve.aClockwise;
    }
}

function transformAngle(phi: f64, mDRF: Matrix3): f64 {
    const v = new Vector3(Math.cos(phi), Math.sin(phi), 0).applyMatrix3(mDRF);
    return Math.atan2(v.y, v.x);
}

/// A faster shortcut when there is no skew (e.g. a euclidean transform of
/// a group holding the ellipse).
function transfEllipseNoSkew(curve: EllipseCurve, m: Matrix3): void {
    const sx = getTransformScaleX(m);
    const sy = getTransformScaleY(m);
    curve.xRadius *= sx;
    curve.yRadius *= sy;
    // Extract the rotation angle from the matrix of form
    //   | cosθ sx   -sinθ sy |
    //   | sinθ sx    cosθ sy |
    // remembering that tanθ = sinθ / cosθ, and that sx, sy or both might
    // be zero.
    const theta = sx > EPSILON ? Math.atan2(m.elements[1], m.elements[0]) : Math.atan2(-m.elements[3], m.elements[4]);
    curve.aRotation += theta;
    if (isTransformFlipped(m)) {
        curve.aStartAngle *= -1;
        curve.aEndAngle *= -1;
        curve.aClockwise = !curve.aClockwise;
    }
}

function isTransformFlipped(m: Matrix3): bool {
    const te = m.elements;
    return te[0] * te[4] - te[1] * te[3] < 0;
}

function isTransformSkewed(m: Matrix3): bool {
    const te = m.elements;
    const basisDot = te[0] * te[3] + te[1] * te[4];
    // Shortcut for trivial rotations and transformations.
    if (basisDot == 0) return false;
    const sx = getTransformScaleX(m);
    const sy = getTransformScaleY(m);
    return Math.abs(basisDot / (sx * sy)) > EPSILON;
}

function getTransformScaleX(m: Matrix3): f64 {
    const te = m.elements;
    return Math.sqrt(te[0] * te[0] + te[1] * te[1]);
}

function getTransformScaleY(m: Matrix3): f64 {
    const te = m.elements;
    return Math.sqrt(te[3] * te[3] + te[4] * te[4]);
}

export class EigenDecomposition {
    rt1: f64 = NaN;
    rt2: f64 = NaN;
    cs: f64 = 0;
    sn: f64 = 0;
}

/// The eigensystem of a real symmetric 2x2 matrix
///    [ A  B ]
///    [ B  C ]
/// in the form
///    [ A  B ]  =  [ cs  -sn ] [ rt1   0  ] [  cs  sn ]
///    [ B  C ]     [ sn   cs ] [  0   rt2 ] [ -sn  cs ]
/// where rt1 >= rt2. Adapted from
/// https://www.mpi-hd.mpg.de/personalhomes/globes/3x3/index.html
/// (Algorithms for real symmetric matrices, analytical 2x2).
export function eigenDecomposition(A: f64, B: f64, C: f64): EigenDecomposition {
    const out = new EigenDecomposition();
    let cs: f64, sn: f64, t: f64;
    const sm = A + C;
    const df = A - C;
    const rt = Math.sqrt(df * df + 4 * B * B);
    if (sm > 0) {
        out.rt1 = 0.5 * (sm + rt);
        t = 1 / out.rt1;
        out.rt2 = A * t * C - B * t * B;
    } else if (sm < 0) {
        out.rt2 = 0.5 * (sm - rt);
    } else {
        // This case needs to be treated separately to avoid div by 0.
        out.rt1 = 0.5 * rt;
        out.rt2 = -0.5 * rt;
    }
    // Calculate the eigenvectors.
    if (df > 0) cs = df + rt;
    else cs = df - rt;
    if (Math.abs(cs) > 2 * Math.abs(B)) {
        t = -2 * B / cs;
        sn = 1 / Math.sqrt(1 + t * t);
        cs = t * sn;
    } else if (Math.abs(B) == 0) {
        cs = 1;
        sn = 0;
    } else {
        t = -0.5 * cs / B;
        cs = 1 / Math.sqrt(1 + t * t);
        sn = t * cs;
    }
    if (df > 0) {
        t = cs;
        cs = -sn;
        sn = t;
    }
    out.cs = cs;
    out.sn = sn;
    return out;
}

// createShapes.

const BIGNUMBER: f64 = 999999999;

const ORIGIN = 0;
const DESTINATION = 1;
const BETWEEN = 2;
const LEFT = 3;
const RIGHT = 4;
const BEHIND = 5;
const BEYOND = 6;

class ClassifyResult {
    loc: i32 = ORIGIN;
    t: f64 = 0;
}

class EdgeIntersection {
    x: f64;
    y: f64;
    t: f64;

    constructor(x: f64, y: f64, t: f64) {
        this.x = x;
        this.y = y;
        this.t = t;
    }
}

class SimplePath {
    curves: Array<Curve<Vector2>>;
    points: Array<Vector2>;
    isCW: bool;
    identifier: i32 = -1;
    boundingBox: Box2;

    constructor(curves: Array<Curve<Vector2>>, points: Array<Vector2>, isCW: bool, boundingBox: Box2) {
        this.curves = curves;
        this.points = points;
        this.isCW = isCW;
        this.boundingBox = boundingBox;
    }
}

class ScanlineIntersection {
    identifier: i32;
    isCW: bool;
    point: Vector2;

    constructor(identifier: i32, isCW: bool, point: Vector2) {
        this.identifier = identifier;
        this.isCW = isCW;
        this.point = point;
    }
}

class HoleResult {
    identifier: i32;
    isHole: bool;
    /// three.js's `for`: the path this one is a hole of (-1: none).
    holeFor: i32;

    constructor(identifier: i32, isHole: bool, holeFor: i32) {
        this.identifier = identifier;
        this.isHole = isHole;
        this.holeFor = holeFor;
    }
}

/// Number.prototype.toPrecision(10), as a number.
function toPrecision10(v: f64): f64 {
    if (v == 0 || !isFinite(v)) return v;
    const e = Math.floor(Math.log10(Math.abs(v)));
    const scale = Math.pow(10, 9 - e);
    return Math.round(v * scale) / scale;
}

function findEdgeIntersection(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2, cr: ClassifyResult): EdgeIntersection? {
    const x1 = a0.x, x2 = a1.x, x3 = b0.x, x4 = b1.x;
    const y1 = a0.y, y2 = a1.y, y3 = b0.y, y4 = b1.y;
    const nom1 = (x4 - x3) * (y1 - y3) - (y4 - y3) * (x1 - x3);
    const nom2 = (x2 - x1) * (y1 - y3) - (y2 - y1) * (x1 - x3);
    const denom = (y4 - y3) * (x2 - x1) - (x4 - x3) * (y2 - y1);
    const t1 = nom1 / denom;
    const t2 = nom2 / denom;
    if (((denom == 0) && (nom1 != 0)) || (t1 <= 0) || (t1 >= 1) || (t2 < 0) || (t2 > 1)) {
        // 1. Lines are parallel or edges don't intersect.
        return null;
    } else if ((nom1 == 0) && (denom == 0)) {
        // 2. Lines are colinear: check if the endpoints of edge 2 (b0-b1)
        // lie on edge 1 (a0-a1).
        for (let i = 0; i < 2; i++) {
            classifyPoint(i == 0 ? b0 : b1, a0, a1, cr);
            // Find the position of this endpoint relative to edge 1.
            if (cr.loc == ORIGIN) {
                const point = i == 0 ? b0 : b1;
                return new EdgeIntersection(point.x, point.y, cr.t);
            } else if (cr.loc == BETWEEN) {
                const x = toPrecision10(x1 + cr.t * (x2 - x1));
                const y = toPrecision10(y1 + cr.t * (y2 - y1));
                return new EdgeIntersection(x, y, cr.t);
            }
        }
        return null;
    } else {
        // 3. Edges intersect.
        for (let i = 0; i < 2; i++) {
            classifyPoint(i == 0 ? b0 : b1, a0, a1, cr);
            if (cr.loc == ORIGIN) {
                const point = i == 0 ? b0 : b1;
                return new EdgeIntersection(point.x, point.y, cr.t);
            }
        }
        const x = toPrecision10(x1 + t1 * (x2 - x1));
        const y = toPrecision10(y1 + t1 * (y2 - y1));
        return new EdgeIntersection(x, y, t1);
    }
}

function classifyPoint(p: Vector2, edgeStart: Vector2, edgeEnd: Vector2, cr: ClassifyResult): void {
    const ax = edgeEnd.x - edgeStart.x;
    const ay = edgeEnd.y - edgeStart.y;
    const bx = p.x - edgeStart.x;
    const by = p.y - edgeStart.y;
    const sa = ax * by - bx * ay;
    if ((p.x == edgeStart.x) && (p.y == edgeStart.y)) {
        cr.loc = ORIGIN;
        cr.t = 0;
        return;
    }
    if ((p.x == edgeEnd.x) && (p.y == edgeEnd.y)) {
        cr.loc = DESTINATION;
        cr.t = 1;
        return;
    }
    if (sa < -EPSILON) {
        cr.loc = LEFT;
        return;
    }
    if (sa > EPSILON) {
        cr.loc = RIGHT;
        return;
    }
    if (((ax * bx) < 0) || ((ay * by) < 0)) {
        cr.loc = BEHIND;
        return;
    }
    if ((Math.sqrt(ax * ax + ay * ay)) < (Math.sqrt(bx * bx + by * by))) {
        cr.loc = BEYOND;
        return;
    }
    let t: f64;
    if (ax != 0) t = bx / ax;
    else t = by / ay;
    cr.loc = BETWEEN;
    cr.t = t;
}

function getIntersections(path1: Array<Vector2>, path2: Array<Vector2>, cr: ClassifyResult): Array<Vector2> {
    const intersectionsRaw: Array<EdgeIntersection> = [];
    const intersections: Array<Vector2> = [];
    for (let index = 1; index < path1.length; index++) {
        const path1EdgeStart = path1[index - 1];
        const path1EdgeEnd = path1[index];
        for (let index2 = 1; index2 < path2.length; index2++) {
            const path2EdgeStart = path2[index2 - 1];
            const path2EdgeEnd = path2[index2];
            const intersection = findEdgeIntersection(path1EdgeStart, path1EdgeEnd, path2EdgeStart, path2EdgeEnd, cr);
            if (intersection == null) continue;
            let found = false;
            for (let k = 0; k < intersectionsRaw.length; k++) {
                const r = intersectionsRaw[k];
                if (r.t <= intersection.t + EPSILON && r.t >= intersection.t - EPSILON) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                intersectionsRaw.push(intersection);
                intersections.push(new Vector2(intersection.x, intersection.y));
            }
        }
    }
    return intersections;
}

/// Sorts by x, stably (as JavaScript's sort).
function sortByX(list: Array<ScanlineIntersection>): void {
    for (let i = 1; i < list.length; i++) {
        const item = list[i];
        let j = i - 1;
        while (j >= 0 && list[j].point.x > item.point.x) {
            list[j + 1] = list[j];
            j--;
        }
        list[j + 1] = item;
    }
}

function getScanlineIntersections(scanline: Array<Vector2>, boundingBox: Box2, paths: Array<SimplePath>,
                                  cr: ClassifyResult): Array<ScanlineIntersection> {
    const center = new Vector2();
    boundingBox.getCenter(center);
    const allIntersections: Array<ScanlineIntersection> = [];
    for (let k = 0; k < paths.length; k++) {
        const path = paths[k];
        // Check if the center of the bounding box is in the bounding box of
        // the paths: a pruning method to limit the search of intersections
        // to paths that can envelop the current path (the center of a path
        // enveloped by another has to be inside the other's bounding box).
        if (path.boundingBox.containsPoint(center)) {
            const intersections = getIntersections(scanline, path.points, cr);
            for (let i = 0; i < intersections.length; i++) {
                allIntersections.push(new ScanlineIntersection(path.identifier, path.isCW, intersections[i]));
            }
        }
    }
    sortByX(allIntersections);
    return allIntersections;
}

function isHoleTo(simplePath: SimplePath, allPaths: Array<SimplePath>, scanlineMinX: f64, scanlineMaxX: f64,
                  fillRuleIn: string, cr: ClassifyResult): HoleResult {
    const fillRule = fillRuleIn == "" ? "nonzero" : fillRuleIn;
    const centerBoundingBox = new Vector2();
    simplePath.boundingBox.getCenter(centerBoundingBox);
    const scanline = [new Vector2(scanlineMinX, centerBoundingBox.y), new Vector2(scanlineMaxX, centerBoundingBox.y)];
    const scanlineIntersections = getScanlineIntersections(scanline, simplePath.boundingBox, allPaths, cr);
    sortByX(scanlineIntersections);
    const baseIntersections: Array<ScanlineIntersection> = [];
    const otherIntersections: Array<ScanlineIntersection> = [];
    for (let k = 0; k < scanlineIntersections.length; k++) {
        const i = scanlineIntersections[k];
        if (i.identifier == simplePath.identifier) baseIntersections.push(i);
        else otherIntersections.push(i);
    }
    // three.js throws when the scanline misses the path; call it solid.
    if (baseIntersections.length == 0) return new HoleResult(simplePath.identifier, false, -1);
    const firstXOfPath = baseIntersections[0].point.x;

    // Build up the path hierarchy.
    const stack: Array<i32> = [];
    let i = 0;
    while (i < otherIntersections.length && otherIntersections[i].point.x < firstXOfPath) {
        if (stack.length > 0 && stack[stack.length - 1] == otherIntersections[i].identifier) {
            stack.pop();
        } else {
            stack.push(otherIntersections[i].identifier);
        }
        i++;
    }
    stack.push(simplePath.identifier);

    if (fillRule == "evenodd") {
        const isHole = stack.length % 2 == 0;
        const isHoleFor = stack.length >= 2 ? stack[stack.length - 2] : -1;
        return new HoleResult(simplePath.identifier, isHole, isHoleFor);
    } else if (fillRule == "nonzero") {
        // Check if the path is a hole by counting the paths with alternating
        // rotations it has to cross.
        let isHole = true;
        let isHoleFor = -1;
        let lastCWValue = false;
        for (let k = 0; k < stack.length; k++) {
            const identifier = stack[k];
            if (isHole) {
                lastCWValue = allPaths[identifier].isCW;
                isHole = false;
                isHoleFor = identifier;
            } else if (lastCWValue != allPaths[identifier].isCW) {
                lastCWValue = allPaths[identifier].isCW;
                isHole = true;
            }
        }
        return new HoleResult(simplePath.identifier, isHole, isHoleFor);
    }
    console.warn("fill-rule: \"" + fillRule + "\" is currently not implemented.");
    return new HoleResult(simplePath.identifier, false, -1);
}

function createShapes(shapePath: ShapePath): Array<Shape> {
    const cr = new ClassifyResult();
    // Check for self intersecting paths: TODO. Check intersecting paths: TODO
    // (as three.js).

    // Prepare paths for hole detection.
    let scanlineMinX = BIGNUMBER;
    let scanlineMaxX = -BIGNUMBER;
    const simplePaths: Array<SimplePath> = [];
    for (let s = 0; s < shapePath.subPaths.length; s++) {
        const p = shapePath.subPaths[s];
        const points = p.getPoints();
        let maxY = -BIGNUMBER;
        let minY = BIGNUMBER;
        let maxX = -BIGNUMBER;
        let minX = BIGNUMBER;
        for (let i = 0; i < points.length; i++) {
            const pt = points[i];
            if (pt.y > maxY) maxY = pt.y;
            if (pt.y < minY) minY = pt.y;
            if (pt.x > maxX) maxX = pt.x;
            if (pt.x < minX) minX = pt.x;
        }
        if (scanlineMaxX <= maxX) scanlineMaxX = maxX + 1;
        if (scanlineMinX >= minX) scanlineMinX = minX - 1;
        // Filter out paths of fewer than two points.
        if (points.length <= 1) continue;
        simplePaths.push(new SimplePath(p.curves, points, ShapeUtils.isClockWise(points),
            new Box2(new Vector2(minX, minY), new Vector2(maxX, maxY))));
    }
    for (let identifier = 0; identifier < simplePaths.length; identifier++) {
        simplePaths[identifier].identifier = identifier;
    }

    // Check if each path is solid or a hole.
    const fillRule = shapePath instanceof SVGShapePath ? (shapePath as SVGShapePath).userData.style.fillRule : "";
    const isAHole: Array<HoleResult> = [];
    for (let k = 0; k < simplePaths.length; k++) {
        isAHole.push(isHoleTo(simplePaths[k], simplePaths, scanlineMinX, scanlineMaxX, fillRule, cr));
    }

    const shapesToReturn: Array<Shape> = [];
    for (let k = 0; k < simplePaths.length; k++) {
        const p = simplePaths[k];
        const amIAHole = isAHole[p.identifier];
        if (amIAHole.isHole) continue;
        const shape = new Shape();
        shape.curves = p.curves;
        for (let h = 0; h < isAHole.length; h++) {
            const hole = isAHole[h];
            if (!hole.isHole || hole.holeFor != p.identifier) continue;
            const path = new Path();
            path.curves = simplePaths[hole.identifier].curves;
            shape.holes.push(path);
        }
        shapesToReturn.push(shape);
    }
    return shapesToReturn;
}

// pointsToStrokeWithBuffers: three.js's nested functions, sharing the
// stroke state.

class StrokeBuilder {
    style: SVGStyle;
    arcDivisions: i32;
    vertices: Array<f64>?;
    normals: Array<f64>?;
    uvs: Array<f64>?;

    tempV2_1: Vector2 = new Vector2();
    tempV2_2: Vector2 = new Vector2();
    tempV2_3: Vector2 = new Vector2();
    tempV2_4: Vector2 = new Vector2();
    tempV2_5: Vector2 = new Vector2();
    tempV2_6: Vector2 = new Vector2();
    tempV2_7: Vector2 = new Vector2();
    lastPointL: Vector2 = new Vector2();
    lastPointR: Vector2 = new Vector2();
    point0L: Vector2 = new Vector2();
    point0R: Vector2 = new Vector2();
    currentPointL: Vector2 = new Vector2();
    currentPointR: Vector2 = new Vector2();
    nextPointL: Vector2 = new Vector2();
    nextPointR: Vector2 = new Vector2();
    innerPoint: Vector2 = new Vector2();
    outerPoint: Vector2 = new Vector2();

    /// The loop's current point, which three.js's nested helpers read.
    currentPoint: Vector2 = new Vector2();
    u0: f64 = 0;
    u1: f64 = 0;
    numVertices: i32 = 0;
    startCoordinate: i32 = 0;
    startCoordinateUV: i32 = 0;
    currentCoordinate: i32 = 0;
    currentCoordinateUV: i32 = 0;

    constructor(style: SVGStyle, arcDivisions: i32, vertices: Array<f64>?, normals: Array<f64>?, uvs: Array<f64>?) {
        this.style = style;
        this.arcDivisions = arcDivisions;
        this.vertices = vertices;
        this.normals = normals;
        this.uvs = uvs;
    }

    build(pointsIn: Array<Vector2>, minDistance: f64, vertexOffset: i32): i32 {
        const style = this.style;
        const tempV2_1 = this.tempV2_1, tempV2_2 = this.tempV2_2, tempV2_3 = this.tempV2_3, tempV2_4 = this.tempV2_4;
        const tempV2_5 = this.tempV2_5, tempV2_6 = this.tempV2_6, tempV2_7 = this.tempV2_7;
        const lastPointL = this.lastPointL, lastPointR = this.lastPointR;
        const point0L = this.point0L, point0R = this.point0R;
        const currentPointL = this.currentPointL, currentPointR = this.currentPointR;
        const nextPointL = this.nextPointL, nextPointR = this.nextPointR;
        const innerPoint = this.innerPoint, outerPoint = this.outerPoint;

        // First ensure there are no duplicated points.
        const points = removeDuplicatedPoints(pointsIn, minDistance);
        const numPoints = points.length;
        if (numPoints < 2) return 0;
        const isClosed = points[0].equals(points[numPoints - 1]);
        let currentPoint = points[0];
        let previousPoint = points[0];
        let nextPoint: Vector2? = null;
        const strokeWidth2 = style.strokeWidth / 2;
        const deltaU = 1 / <f64>(numPoints - 1);
        this.u0 = 0;
        let innerSideModified = false;
        let joinIsOnLeftSide = false;
        let isMiter = false;
        let initialJoinIsOnLeftSide = false;
        this.numVertices = 0;
        this.startCoordinate = vertexOffset * 3;
        this.startCoordinateUV = vertexOffset * 2;
        this.currentCoordinate = this.startCoordinate;
        this.currentCoordinateUV = this.startCoordinateUV;

        // Get the initial left and right stroke points.
        getNormal(points[0], points[1], tempV2_1).multiplyScalar(strokeWidth2);
        lastPointL.copy(points[0]).sub(tempV2_1);
        lastPointR.copy(points[0]).add(tempV2_1);
        point0L.copy(lastPointL);
        point0R.copy(lastPointR);

        for (let iPoint = 1; iPoint < numPoints; iPoint++) {
            currentPoint = points[iPoint];
            this.currentPoint = currentPoint;
            // Get the next point.
            if (iPoint == numPoints - 1) {
                // Closed: skip the duplicated initial point.
                nextPoint = isClosed ? points[1] : null;
            } else {
                nextPoint = points[iPoint + 1];
            }
            // Normal of the previous segment in tempV2_1.
            const normal1 = tempV2_1;
            getNormal(previousPoint, currentPoint, normal1);
            tempV2_3.copy(normal1).multiplyScalar(strokeWidth2);
            currentPointL.copy(currentPoint).sub(tempV2_3);
            currentPointR.copy(currentPoint).add(tempV2_3);
            this.u1 = this.u0 + deltaU;
            innerSideModified = false;

            if (nextPoint != null) {
                const next = nextPoint!;
                // Normal of the next segment in tempV2_2.
                getNormal(currentPoint, next, tempV2_2);
                tempV2_3.copy(tempV2_2).multiplyScalar(strokeWidth2);
                nextPointL.copy(currentPoint).sub(tempV2_3);
                nextPointR.copy(currentPoint).add(tempV2_3);
                joinIsOnLeftSide = true;
                tempV2_3.subVectors(next, previousPoint);
                if (normal1.dot(tempV2_3) < 0) joinIsOnLeftSide = false;
                if (iPoint == 1) initialJoinIsOnLeftSide = joinIsOnLeftSide;
                tempV2_3.subVectors(next, currentPoint);
                tempV2_3.normalize();
                const dot = Math.abs(normal1.dot(tempV2_3));
                // If the path is straight, don't create a join.
                if (dot > EPSILON) {
                    // Compute the inner and outer segment intersections.
                    const miterSide = strokeWidth2 / dot;
                    tempV2_3.multiplyScalar(-miterSide);
                    tempV2_4.subVectors(currentPoint, previousPoint);
                    tempV2_5.copy(tempV2_4).setLength(miterSide).add(tempV2_3);
                    innerPoint.copy(tempV2_5).negate();
                    const miterLength2 = tempV2_5.length();
                    const segmentLengthPrev = tempV2_4.length();
                    tempV2_4.divideScalar(segmentLengthPrev);
                    tempV2_6.subVectors(next, currentPoint);
                    const segmentLengthNext = tempV2_6.length();
                    tempV2_6.divideScalar(segmentLengthNext);
                    // Check that the previous and next segments don't
                    // overlap with the inner point of intersection.
                    if (tempV2_4.dot(innerPoint) < segmentLengthPrev && tempV2_6.dot(innerPoint) < segmentLengthNext) {
                        innerSideModified = true;
                    }
                    outerPoint.copy(tempV2_5).add(currentPoint);
                    innerPoint.add(currentPoint);
                    isMiter = false;
                    if (innerSideModified) {
                        if (joinIsOnLeftSide) {
                            nextPointR.copy(innerPoint);
                            currentPointR.copy(innerPoint);
                        } else {
                            nextPointL.copy(innerPoint);
                            currentPointL.copy(innerPoint);
                        }
                    } else {
                        // The segment triangles are generated here if there
                        // was overlapping.
                        this.makeSegmentTriangles();
                    }
                    const join = style.strokeLineJoin;
                    if (join == "bevel") {
                        this.makeSegmentWithBevelJoin(joinIsOnLeftSide, innerSideModified, this.u1);
                    } else if (join == "round") {
                        // Segment triangles.
                        this.createSegmentTrianglesWithMiddleSection(joinIsOnLeftSide, innerSideModified);
                        // Join triangles.
                        if (joinIsOnLeftSide) {
                            this.makeCircularSector(currentPoint, currentPointL, nextPointL, this.u1, 0);
                        } else {
                            this.makeCircularSector(currentPoint, nextPointR, currentPointR, this.u1, 1);
                        }
                    } else {
                        // "miter", "miter-clip" and anything else.
                        const u1 = this.u1;
                        const miterFraction = (strokeWidth2 * style.strokeMiterLimit) / miterLength2;
                        if (miterFraction < 1) {
                            // The join miter length exceeds the miter limit.
                            if (join != "miter-clip") {
                                this.makeSegmentWithBevelJoin(joinIsOnLeftSide, innerSideModified, u1);
                            } else {
                                // Segment triangles.
                                this.createSegmentTrianglesWithMiddleSection(joinIsOnLeftSide, innerSideModified);
                                // Miter-clip join triangles.
                                if (joinIsOnLeftSide) {
                                    tempV2_6.subVectors(outerPoint, currentPointL).multiplyScalar(miterFraction).add(currentPointL);
                                    tempV2_7.subVectors(outerPoint, nextPointL).multiplyScalar(miterFraction).add(nextPointL);
                                    this.addVertex(currentPointL, u1, 0);
                                    this.addVertex(tempV2_6, u1, 0);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(tempV2_6, u1, 0);
                                    this.addVertex(tempV2_7, u1, 0);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(tempV2_7, u1, 0);
                                    this.addVertex(nextPointL, u1, 0);
                                } else {
                                    tempV2_6.subVectors(outerPoint, currentPointR).multiplyScalar(miterFraction).add(currentPointR);
                                    tempV2_7.subVectors(outerPoint, nextPointR).multiplyScalar(miterFraction).add(nextPointR);
                                    this.addVertex(currentPointR, u1, 1);
                                    this.addVertex(tempV2_6, u1, 1);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(tempV2_6, u1, 1);
                                    this.addVertex(tempV2_7, u1, 1);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(tempV2_7, u1, 1);
                                    this.addVertex(nextPointR, u1, 1);
                                }
                            }
                        } else {
                            // Miter join segment triangles.
                            const u0 = this.u0;
                            if (innerSideModified) {
                                // Optimized segment + join triangles.
                                if (joinIsOnLeftSide) {
                                    this.addVertex(lastPointR, u0, 1);
                                    this.addVertex(lastPointL, u0, 0);
                                    this.addVertex(outerPoint, u1, 0);
                                    this.addVertex(lastPointR, u0, 1);
                                    this.addVertex(outerPoint, u1, 0);
                                    this.addVertex(innerPoint, u1, 1);
                                } else {
                                    this.addVertex(lastPointR, u0, 1);
                                    this.addVertex(lastPointL, u0, 0);
                                    this.addVertex(outerPoint, u1, 1);
                                    this.addVertex(lastPointL, u0, 0);
                                    this.addVertex(innerPoint, u1, 0);
                                    this.addVertex(outerPoint, u1, 1);
                                }
                                if (joinIsOnLeftSide) nextPointL.copy(outerPoint);
                                else nextPointR.copy(outerPoint);
                            } else {
                                // Add extra miter join triangles.
                                if (joinIsOnLeftSide) {
                                    this.addVertex(currentPointL, u1, 0);
                                    this.addVertex(outerPoint, u1, 0);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(outerPoint, u1, 0);
                                    this.addVertex(nextPointL, u1, 0);
                                } else {
                                    this.addVertex(currentPointR, u1, 1);
                                    this.addVertex(outerPoint, u1, 1);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(currentPoint, u1, 0.5);
                                    this.addVertex(outerPoint, u1, 1);
                                    this.addVertex(nextPointR, u1, 1);
                                }
                            }
                            isMiter = true;
                        }
                    }
                } else {
                    // The segment triangles are generated here when two
                    // consecutive points are collinear.
                    this.makeSegmentTriangles();
                }
            } else {
                // The segment triangles are generated here if it is the
                // ending segment.
                this.makeSegmentTriangles();
            }

            if (!isClosed && iPoint == numPoints - 1) {
                // Start line endcap.
                this.addCapGeometry(points[0], point0L, point0R, joinIsOnLeftSide, true, this.u0);
            }
            // Increment loop variables.
            this.u0 = this.u1;
            previousPoint = currentPoint;
            lastPointL.copy(nextPointL);
            lastPointR.copy(nextPointR);
        }

        const vertices = this.vertices;
        if (!isClosed) {
            // Ending line endcap.
            this.addCapGeometry(currentPoint, currentPointL, currentPointR, joinIsOnLeftSide, false, this.u1);
        } else if (innerSideModified && vertices != null) {
            // Modify the path's first segment vertices to adjust to the
            // segments' inner and outer intersections.
            let lastOuter = outerPoint;
            let lastInner = innerPoint;
            if (initialJoinIsOnLeftSide != joinIsOnLeftSide) {
                lastOuter = innerPoint;
                lastInner = outerPoint;
            }
            const base = this.startCoordinate;
            if (joinIsOnLeftSide) {
                if (isMiter || initialJoinIsOnLeftSide) {
                    writeVec2(lastInner, vertices, base + 0 * 3);
                    writeVec2(lastInner, vertices, base + 3 * 3);
                    if (isMiter) writeVec2(lastOuter, vertices, base + 1 * 3);
                }
            } else {
                if (isMiter || !initialJoinIsOnLeftSide) {
                    writeVec2(lastInner, vertices, base + 1 * 3);
                    writeVec2(lastInner, vertices, base + 3 * 3);
                    if (isMiter) writeVec2(lastOuter, vertices, base + 0 * 3);
                }
            }
        }
        return this.numVertices;
    }

    addVertex(position: Vector2, u: f64, v: f64): void {
        const vertices = this.vertices;
        if (vertices != null) {
            const c = this.currentCoordinate;
            setAt(vertices, c, position.x);
            setAt(vertices, c + 1, position.y);
            setAt(vertices, c + 2, 0);
            const normals = this.normals;
            if (normals != null) {
                setAt(normals, c, 0);
                setAt(normals, c + 1, 0);
                setAt(normals, c + 2, 1);
            }
            this.currentCoordinate += 3;
            const uvs = this.uvs;
            if (uvs != null) {
                setAt(uvs, this.currentCoordinateUV, u);
                setAt(uvs, this.currentCoordinateUV + 1, v);
                this.currentCoordinateUV += 2;
            }
        }
        this.numVertices += 3;
    }

    /// `p1` and `p2` are points of the circle arc, clockwise.
    makeCircularSector(center: Vector2, p1: Vector2, p2: Vector2, u: f64, v: f64): void {
        const tempV2_1 = this.tempV2_1, tempV2_2 = this.tempV2_2, tempV2_3 = this.tempV2_3, tempV2_4 = this.tempV2_4;
        tempV2_1.copy(p1).sub(center).normalize();
        tempV2_2.copy(p2).sub(center).normalize();
        let angle = Math.PI;
        const dot = tempV2_1.dot(tempV2_2);
        if (Math.abs(dot) < 1) angle = Math.abs(Math.acos(dot));
        angle /= <f64>this.arcDivisions;
        tempV2_3.copy(p1);
        for (let i = 0, il = this.arcDivisions - 1; i < il; i++) {
            tempV2_4.copy(tempV2_3).rotateAround(center, angle);
            this.addVertex(tempV2_3, u, v);
            this.addVertex(tempV2_4, u, v);
            this.addVertex(center, u, 0.5);
            tempV2_3.copy(tempV2_4);
        }
        this.addVertex(tempV2_4, u, v);
        this.addVertex(p2, u, v);
        this.addVertex(center, u, 0.5);
    }

    makeSegmentTriangles(): void {
        const u0 = this.u0, u1 = this.u1;
        this.addVertex(this.lastPointR, u0, 1);
        this.addVertex(this.lastPointL, u0, 0);
        this.addVertex(this.currentPointL, u1, 0);
        this.addVertex(this.lastPointR, u0, 1);
        this.addVertex(this.currentPointL, u1, 0);
        this.addVertex(this.currentPointR, u1, 1);
    }

    makeSegmentWithBevelJoin(joinIsOnLeftSide: bool, innerSideModified: bool, u: f64): void {
        const u0 = this.u0, u1 = this.u1;
        if (innerSideModified) {
            // Optimized segment + bevel triangles.
            if (joinIsOnLeftSide) {
                // Path segments triangles.
                this.addVertex(this.lastPointR, u0, 1);
                this.addVertex(this.lastPointL, u0, 0);
                this.addVertex(this.currentPointL, u1, 0);
                this.addVertex(this.lastPointR, u0, 1);
                this.addVertex(this.currentPointL, u1, 0);
                this.addVertex(this.innerPoint, u1, 1);
                // Bevel join triangle.
                this.addVertex(this.currentPointL, u, 0);
                this.addVertex(this.nextPointL, u, 0);
                this.addVertex(this.innerPoint, u, 0.5);
            } else {
                // Path segments triangles.
                this.addVertex(this.lastPointR, u0, 1);
                this.addVertex(this.lastPointL, u0, 0);
                this.addVertex(this.currentPointR, u1, 1);
                this.addVertex(this.lastPointL, u0, 0);
                this.addVertex(this.innerPoint, u1, 0);
                this.addVertex(this.currentPointR, u1, 1);
                // Bevel join triangle.
                this.addVertex(this.currentPointR, u, 1);
                this.addVertex(this.innerPoint, u, 0);
                this.addVertex(this.nextPointR, u, 1);
            }
        } else {
            // Bevel join triangle. The segment triangles are done in the
            // main loop.
            if (joinIsOnLeftSide) {
                this.addVertex(this.currentPointL, u, 0);
                this.addVertex(this.nextPointL, u, 0);
                this.addVertex(this.currentPoint, u, 0.5);
            } else {
                this.addVertex(this.currentPointR, u, 1);
                this.addVertex(this.nextPointR, u, 0);
                this.addVertex(this.currentPoint, u, 0.5);
            }
        }
    }

    createSegmentTrianglesWithMiddleSection(joinIsOnLeftSide: bool, innerSideModified: bool): void {
        if (!innerSideModified) return;
        const u0 = this.u0, u1 = this.u1;
        if (joinIsOnLeftSide) {
            this.addVertex(this.lastPointR, u0, 1);
            this.addVertex(this.lastPointL, u0, 0);
            this.addVertex(this.currentPointL, u1, 0);
            this.addVertex(this.lastPointR, u0, 1);
            this.addVertex(this.currentPointL, u1, 0);
            this.addVertex(this.innerPoint, u1, 1);
            this.addVertex(this.currentPointL, u0, 0);
            this.addVertex(this.currentPoint, u1, 0.5);
            this.addVertex(this.innerPoint, u1, 1);
            this.addVertex(this.currentPoint, u1, 0.5);
            this.addVertex(this.nextPointL, u0, 0);
            this.addVertex(this.innerPoint, u1, 1);
        } else {
            this.addVertex(this.lastPointR, u0, 1);
            this.addVertex(this.lastPointL, u0, 0);
            this.addVertex(this.currentPointR, u1, 1);
            this.addVertex(this.lastPointL, u0, 0);
            this.addVertex(this.innerPoint, u1, 0);
            this.addVertex(this.currentPointR, u1, 1);
            this.addVertex(this.currentPointR, u0, 1);
            this.addVertex(this.innerPoint, u1, 0);
            this.addVertex(this.currentPoint, u1, 0.5);
            this.addVertex(this.currentPoint, u1, 0.5);
            this.addVertex(this.innerPoint, u1, 0);
            this.addVertex(this.nextPointR, u0, 1);
        }
    }

    /// `center`: the end point of the path; `p1`, `p2`: the left and right
    /// cap points.
    addCapGeometry(center: Vector2, p1: Vector2, p2: Vector2, joinIsOnLeftSide: bool, start: bool, u: f64): void {
        const tempV2_1 = this.tempV2_1, tempV2_2 = this.tempV2_2, tempV2_3 = this.tempV2_3, tempV2_4 = this.tempV2_4;
        const cap = this.style.strokeLineCap;
        if (cap == "round") {
            if (start) this.makeCircularSector(center, p2, p1, u, 0.5);
            else this.makeCircularSector(center, p1, p2, u, 0.5);
        } else if (cap == "square") {
            const vertices = this.vertices;
            if (start) {
                tempV2_1.subVectors(p1, center);
                tempV2_2.set(tempV2_1.y, -tempV2_1.x);
                tempV2_3.addVectors(tempV2_1, tempV2_2).add(center);
                tempV2_4.subVectors(tempV2_2, tempV2_1).add(center);
                if (vertices == null) return;
                const base = this.startCoordinate;
                const baseUV = this.startCoordinateUV;
                // Modify already existing vertices.
                if (joinIsOnLeftSide) {
                    writeVec2(tempV2_3, vertices, base + 1 * 3);
                    writeVec2(tempV2_4, vertices, base + 0 * 3);
                    writeVec2(tempV2_4, vertices, base + 3 * 3);
                } else {
                    writeVec2(tempV2_3, vertices, base + 1 * 3);
                    // Using tempV2_4 to update the 3rd vertex if the uv.y of
                    // the 3rd vertex is 1.
                    const uvs = this.uvs;
                    if (uvs != null && uvs.length > baseUV + 3 * 2 + 1 && uvs[baseUV + 3 * 2 + 1] == 1) {
                        writeVec2(tempV2_4, vertices, base + 3 * 3);
                    } else {
                        writeVec2(tempV2_3, vertices, base + 3 * 3);
                    }
                    writeVec2(tempV2_4, vertices, base + 0 * 3);
                }
            } else {
                tempV2_1.subVectors(p2, center);
                tempV2_2.set(tempV2_1.y, -tempV2_1.x);
                tempV2_3.addVectors(tempV2_1, tempV2_2).add(center);
                tempV2_4.subVectors(tempV2_2, tempV2_1).add(center);
                if (vertices == null) return;
                const vl = this.currentCoordinate;
                // Modify already existing vertices.
                if (joinIsOnLeftSide) {
                    writeVec2(tempV2_3, vertices, vl - 1 * 3);
                    writeVec2(tempV2_4, vertices, vl - 2 * 3);
                    writeVec2(tempV2_4, vertices, vl - 4 * 3);
                } else {
                    writeVec2(tempV2_4, vertices, vl - 2 * 3);
                    writeVec2(tempV2_3, vertices, vl - 1 * 3);
                    writeVec2(tempV2_4, vertices, vl - 4 * 3);
                }
            }
        }
        // "butt" and anything else: nothing to do.
    }
}

function getNormal(p1: Vector2, p2: Vector2, result: Vector2): Vector2 {
    result.subVectors(p2, p1);
    return result.set(-result.y, result.x).normalize();
}

/// Creates a new array if necessary with duplicated points removed. This
/// does not remove the duplicated initial and ending points of a closed
/// path.
function removeDuplicatedPoints(points: Array<Vector2>, minDistance: f64): Array<Vector2> {
    let dupPoints = false;
    for (let i = 1, n = points.length - 1; i < n; i++) {
        if (points[i].distanceTo(points[i + 1]) < minDistance) {
            dupPoints = true;
            break;
        }
    }
    if (!dupPoints) return points;
    const newPoints: Array<Vector2> = [];
    newPoints.push(points[0]);
    for (let i = 1, n = points.length - 1; i < n; i++) {
        if (points[i].distanceTo(points[i + 1]) >= minDistance) newPoints.push(points[i]);
    }
    newPoints.push(points[points.length - 1]);
    return newPoints;
}

/// array[i] = value, growing the array (JavaScript arrays grow on write).
function setAt(array: Array<f64>, i: i32, value: f64): void {
    while (array.length <= i) array.push(0);
    array[i] = value;
}

/// Vector2.toArray for x, y (the z of a stroke vertex stays).
function writeVec2(v: Vector2, array: Array<f64>, offset: i32): void {
    if (offset < 0) return;
    setAt(array, offset, v.x);
    setAt(array, offset + 1, v.y);
}
