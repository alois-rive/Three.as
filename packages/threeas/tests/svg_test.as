// SVGLoader and its XML parser: rive . --test
//
// Expected stroke vertex counts follow three.js's pointsToStrokeWithBuffers
// by hand (the count is 3 per vertex): a segment is 6 vertices; a miter join
// with the inner side moved folds into its segment (6); a bevel join adds 3
// (9 with its segment); a round join 6 + 3 (middle section) + 3 per arc
// division; a clipped miter 6 + 3 + 9; a round cap 3 per arc division;
// square caps move existing vertices.

import { Tests } from "rive/test";
import { Path as RivePath } from "rive/path";
import * as THREE from "../three/Three";
import { SVGLoader, SVGShapePath, SVGStyle, parseFloats, eigenDecomposition } from "../three/addons/loaders/SVGLoader";
import { DOMParser, XMLNode, CSSRule } from "../three/addons/libs/dom_parser";

const COMMANDS: string = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
  <!-- every command, absolute -->
  <path id="abs" d="M10 10 L20 10 30 20 H40 V30 C40 40 50 40 50 30 S60 20 60 30 Q70 40 80 30 T100 30 A10 10 0 0 1 120 30 Z"/>
  <!-- every command, relative -->
  <path id="rel" d="m10 50 l10 0 10 10 h10 v10 c0 10 10 10 10 0 s10-10 10 0 q10 10 20 0 t20 0 a10 5 30 1 0 20 0 z"/>
  <!-- implicit repeats after m / M, two sub-paths -->
  <path id="implicit" d="M0,0 10,0 10,10 z m5,5 5,0 5,5 z"/>
  <!-- compact numbers and arc flags -->
  <path id="compact" d="M1.5.5L-2e1-3e-1l.5.5a5 5 0 1010 0"/>
  <!-- several arcs in one command; an arc too small for its radii -->
  <path id="arcs" d="M0 100 a20 20 0 0 1 40 0 20 20 0 1 1 40 0 A1 1 0 0 0 120 100"/>
  <path id="empty" d=""/>
</svg>`;

const SHAPES: string = `<svg xmlns="http://www.w3.org/2000/svg">
  <rect id="r" x="10" y="20" width="30" height="40" fill="red"/>
  <rect id="rr" x="0" y="0" width="100" height="50" rx="10" fill="#0f0"/>
  <circle id="c" cx="50" cy="50" r="25" fill="rgb(0, 0, 255)"/>
  <ellipse id="e" cx="10" cy="20" rx="30" ry="15" fill="hsl(120, 100%, 25%)"/>
  <line id="l" x1="0" y1="0" x2="100" y2="50" stroke="black"/>
  <polyline id="pl" points="0,0 10,10 20,0 30,10" fill="none" stroke="black"/>
  <polygon id="pg" points="0 0, 50 0, 25 40" fill="cornflowerblue"/>
</svg>`;

const TRANSFORMS: string = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <defs>
    <rect id="unit" width="10" height="10"/>
  </defs>
  <g transform="translate(100, 50) scale(2)">
    <rect id="t1" x="1" y="1" width="2" height="3"/>
    <g transform="rotate(90 5 5)">
      <rect id="t2" x="0" y="0" width="4" height="2"/>
    </g>
  </g>
  <rect id="skx" width="10" height="10" transform="skewX(45)"/>
  <rect id="sky" width="10" height="10" transform="skewY(30)"/>
  <rect id="mat" width="10" height="10" transform="matrix(1 2 3 4 5 6)"/>
  <circle id="cs" cx="0" cy="0" r="10" transform="scale(2 1) rotate(30)"/>
  <path id="arcskew" d="M0 0 A20 10 0 0 1 40 0" transform="scale(1 3) rotate(45) translate(5, 7)"/>
  <ellipse id="flip" cx="0" cy="0" rx="10" ry="5" transform="scale(-1 1)"/>
  <use id="u" xlink:href="#unit" x="50" y="60" fill="orange"/>
  <use id="u2" href="#unit" transform="translate(5 5)"/>
</svg>`;

const CSS: string = `<svg xmlns="http://www.w3.org/2000/svg">
  <defs>
    <style type="text/css"><![CDATA[
      /* a comment */
      .a { fill: red; stroke-width: 3 }
      .b, .c { fill: #00ff00; }
      #special { fill: blue !important; }
      @media screen { .a { fill: yellow } }
      .thin { stroke: black; stroke-width: 0.5px; stroke-linejoin: round; stroke-linecap: square; stroke-miterlimit: 2 }
      ellipse { fill: teal; stroke: navy }
    ]]></style>
  </defs>
  <g fill="purple" stroke="gray" fill-opacity="0.5">
    <rect id="inherit" width="1" height="1"/>
    <rect id="cls" class="a" width="1" height="1"/>
    <rect id="cls2" class="c thin" width="1" height="1"/>
    <rect id="special" class="a" width="1" height="1"/>
    <rect id="inline" class="a" style="fill: #123456; opacity: 2" width="1" height="1"/>
    <rect id="attr" fill="#abcdef" fill-rule="evenodd" visibility="hidden" width="1" height="1"/>
  </g>
  <rect id="mm" x="1mm" y="1in" width="10pt" height="1pc" rx="2cm"/>
  <rect id="pct" x="50%" y="2em" width="10px" height="10"/>
  <rect id="hidden" display="none" stroke-opacity="-1" width="1" height="1"/>
  <ellipse id="el" class="a" rx="1" ry="1"/>
</svg>`;

const HOLES: string = `<svg xmlns="http://www.w3.org/2000/svg">
  <path id="opposite" d="M0 0 H100 V100 H0 Z M25 25 V75 H75 V25 Z"/>
  <path id="same" d="M0 0 H100 V100 H0 Z M25 25 H75 V75 H25 Z"/>
  <path id="sameEvenOdd" fill-rule="evenodd" d="M0 0 H100 V100 H0 Z M25 25 H75 V75 H25 Z"/>
  <path id="nested" fill-rule="evenodd" d="M0 0 H100 V100 H0 Z M10 10 H90 V90 H10 Z M20 20 H80 V80 H20 Z M200 0 H250 V50 H200 Z"/>
  <path id="nestedNonzero" d="M0 0 H100 V100 H0 Z M10 10 V90 H90 V10 Z M20 20 H80 V80 H20 Z"/>
  <path id="ring" d="M50 0 A50 50 0 1 1 50 100 A50 50 0 1 1 50 0 Z M50 25 A25 25 0 1 0 50 75 A25 25 0 1 0 50 25 Z"/>
</svg>`;

const XML: string = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!DOCTYPE svg [
  <!ENTITY ns_svg "http://www.w3.org/2000/svg">
  <!ENTITY % param "ignored">
  <!ENTITY ext SYSTEM "ext.xml">
  <!ENTITY both "&ns_svg;#">
]>
<!-- top comment -->
<svg xmlns="&ns_svg;" xmlns:xlink='http://www.w3.org/1999/xlink'
     data-both="&both;">
  <g id="g1" class='a b'><text>a &lt; b &#65;&#x42; &gt;&amp;&quot;&apos; <![CDATA[<raw>&amp;]]></text></g>
  <use xlink:href="#g1"/>
  <?pi some data?>
  <style>.x { fill: red; } @media print { .y { fill: blue } } .z{stroke:"a;b"}</style>
  <rect style="fill: url(data:a;b); stroke-width : 2px !important; /* c */ opacity:0.5" tab="a&#9;b
c"/>
</svg>`;

function near(a: f64, b: f64, eps: f64 = 1e-6): bool { return Math.abs(a - b) <= eps; }

function pathById(paths: Array<SVGShapePath>, id: string): SVGShapePath? {
    for (let i = 0; i < paths.length; i++) {
        const node = paths[i].userData.node;
        if (node != null && node.getAttribute("id") == id) return paths[i];
    }
    return null;
}

function point(curve: THREE.Curve<THREE.Vector2>, t: f64): THREE.Vector2 {
    return curve.getPoint(t, new THREE.Vector2());
}

function strokeCount(points: Array<THREE.Vector2>, join: string, cap: string, miterLimit: f64 = 4): i32 {
    const style = SVGLoader.getStrokeStyle(2, "#000", join, cap, miterLimit);
    const vertices: Array<f64> = [];
    const n = SVGLoader.pointsToStrokeWithBuffers(points, style, 12, 0.001, vertices, [], []);
    // The returned count matches what was written.
    return n == vertices.length ? n : -1;
}

function V(x: f64, y: f64): THREE.Vector2 { return new THREE.Vector2(x, y); }

export class SVGTests extends Tests {
    override run(): void {
        group("dom_parser", () => {
            test("declaration, doctype, entities, comments, CDATA, PIs", (expect) => {
                const doc = new DOMParser().parseFromString(XML, "image/svg+xml");
                expect.that(doc.xmlVersion).is("1.0");
                expect.that(doc.xmlEncoding).is("UTF-8");
                expect.that(doc.xmlStandalone).is(true);
                expect.that(doc.doctype != null).is(true);
                expect.that(doc.doctype!.nodeName).is("svg");
                // The declaration is no node: doctype, comment, root.
                expect.that(doc.childNodes.length).is(3);
                expect.that(doc.childNodes[1].nodeType).is(XMLNode.COMMENT_NODE);
                expect.that(doc.childNodes[1].nodeValue).is(" top comment ");
                const svg = doc.documentElement!;
                expect.that(svg.nodeName).is("svg");
                expect.that(svg.getAttribute("xmlns")!).is("http://www.w3.org/2000/svg");
                expect.that(svg.namespaceURI!).is("http://www.w3.org/2000/svg");
                expect.that(svg.getAttribute("data-both")!).is("http://www.w3.org/2000/svg#");
                expect.that(doc.entities.has("param")).is(false);
                expect.that(doc.entities.has("ext")).is(false);
                const g = svg.getElementById("g1")!;
                expect.that(g.getAttribute("class")!).is("a b");
                expect.that(g.textContent).is("a < b AB >&\"' <raw>&amp;");
                expect.that(g.childNodes[0].childNodes[1].nodeType).is(XMLNode.CDATA_SECTION_NODE);
                const use = svg.getElementsByTagName("use")[0];
                expect.that(use.getAttributeNS("http://www.w3.org/1999/xlink", "href")!).is("#g1");
                expect.that(use.getAttribute("href") == null).is(true);
                expect.that(use.viewportElement === svg).is(true);
                expect.that(svg.viewportElement == null).is(true);
                // g, use, style, rect (the PI is no element).
                expect.that(svg.children.length).is(4);
                let pi: XMLNode? = null;
                for (let i = 0; i < svg.childNodes.length; i++) {
                    if (svg.childNodes[i].nodeType == XMLNode.PROCESSING_INSTRUCTION_NODE) pi = svg.childNodes[i];
                }
                expect.that(pi != null && pi.nodeName == "pi" && pi.nodeValue == "some data").is(true);
                expect.that(doc.errors.length).is(0);
            });
            test("style attribute and <style> sheets", (expect) => {
                const doc = new DOMParser().parseFromString(XML);
                const svg = doc.documentElement!;
                const sheet = svg.getElementsByTagName("style")[0].sheet!;
                expect.that(sheet.cssRules.length).is(3);
                expect.that(sheet.cssRules[0].type).is(CSSRule.STYLE_RULE);
                expect.that(sheet.cssRules[0].selectorText).is(".x");
                expect.that(sheet.cssRules[0].style.getPropertyValue("fill")).is("red");
                expect.that(sheet.cssRules[1].type).is(CSSRule.MEDIA_RULE);
                expect.that(sheet.cssRules[2].style.getPropertyValue("stroke")).is("\"a;b\"");
                const rect = svg.getElementsByTagName("rect")[0];
                const style = rect.style;
                expect.that(style.length).is(3);
                expect.that(style.getPropertyValue("fill")).is("url(data:a;b)");
                expect.that(style.getPropertyValue("stroke-width")).is("2px");
                expect.that(style.getPropertyPriority("stroke-width")).is("important");
                expect.that(style.getPropertyValue("opacity")).is("0.5");
                expect.that(style.getPropertyValue("stroke")).is("");
                // Attribute values: tabs and line ends become spaces, but a
                // character reference stays.
                expect.that(rect.getAttribute("tab")!).is("a\tb c");
            });
            test("recovers from malformed markup", (expect) => {
                const doc = new DOMParser().parseFromString("<a><b x=1 y></a><c/> & < &nope;");
                expect.that(doc.errors.length > 0).is(true);
                expect.that(doc.documentElement!.nodeName).is("a");
                const b = doc.documentElement!.childNodes[0];
                expect.that(b.nodeName).is("b");
                expect.that(b.getAttribute("x")!).is("1");
                expect.that(b.hasAttribute("y")).is(true);
                const empty = new DOMParser().parseFromString("");
                expect.that(empty.documentElement == null).is(true);
                expect.that(empty.errors.length).is(1);
            });
        });

        group("SVGLoader: path commands", () => {
            const data = new SVGLoader().parse(COMMANDS);
            const paths = data.paths;
            test("one path per drawn element, userData and xml", (expect) => {
                // The empty d makes no path.
                expect.that(paths.length).is(5);
                expect.that(data.xml!.nodeName).is("svg");
                expect.that(paths[0].userData.node!.getAttribute("id")!).is("abs");
                expect.that(paths[0].userData.style.fill).is("#000");
                expect.that(paths[0].color.getHex()).is(0x000000);
            });
            test("absolute commands", (expect) => {
                const p = pathById(paths, "abs")!;
                expect.that(p.subPaths.length).is(1);
                const sub = p.subPaths[0];
                expect.that(sub.autoClose).is(true);
                const c = sub.curves;
                expect.that(c.length).is(9);
                expect.that(c[0] instanceof THREE.LineCurve).is(true);
                expect.that(point(c[2], 1).equals(V(40, 20))).is(true);
                expect.that(point(c[3], 1).equals(V(40, 30))).is(true);
                expect.that(c[4] instanceof THREE.CubicBezierCurve).is(true);
                // S reflects the previous control point (50, 40) about (50, 30).
                const s = c[5] as THREE.CubicBezierCurve;
                expect.that(s.v1.equals(V(50, 20))).is(true);
                expect.that(s.v3.equals(V(60, 30))).is(true);
                // T reflects Q's control point (70, 40) about (80, 30).
                const t = c[7] as THREE.QuadraticBezierCurve;
                expect.that(t.v1.equals(V(90, 20))).is(true);
                const a = c[8] as THREE.EllipseCurve;
                expect.that(near(a.aX, 110) && near(a.aY, 30) && near(a.xRadius, 10)).is(true);
                expect.that(a.aClockwise).is(false);
                const mid = point(a, 0.5);
                expect.that(near(mid.x, 110) && near(mid.y, 20)).is(true);
                const end = point(a, 1);
                expect.that(near(end.x, 120) && near(end.y, 30)).is(true);
                // Z: the points close back to the start.
                const pts = sub.getPoints();
                expect.that(pts[pts.length - 1].equals(V(10, 10))).is(true);
            });
            test("relative commands", (expect) => {
                const c = pathById(paths, "rel")!.subPaths[0].curves;
                expect.that(c.length).is(9);
                expect.that(point(c[1], 1).equals(V(30, 60))).is(true);
                expect.that(point(c[3], 1).equals(V(40, 70))).is(true);
                const cc = c[4] as THREE.CubicBezierCurve;
                expect.that(cc.v1.equals(V(40, 80)) && cc.v2.equals(V(50, 80)) && cc.v3.equals(V(50, 70))).is(true);
                const s = c[5] as THREE.CubicBezierCurve;
                expect.that(s.v1.equals(V(50, 60)) && s.v2.equals(V(60, 60)) && s.v3.equals(V(60, 70))).is(true);
                const q = c[6] as THREE.QuadraticBezierCurve;
                expect.that(q.v1.equals(V(70, 80)) && q.v2.equals(V(80, 70))).is(true);
                const t = c[7] as THREE.QuadraticBezierCurve;
                expect.that(t.v1.equals(V(90, 60)) && t.v2.equals(V(100, 70))).is(true);
                // Radii too small for the chord are scaled up (sqrt 1.75).
                const a = c[8] as THREE.EllipseCurve;
                expect.that(near(a.xRadius, 10 * Math.sqrt(1.75)) && near(a.yRadius, 5 * Math.sqrt(1.75))).is(true);
                expect.that(near(a.aRotation, Math.PI / 6)).is(true);
                expect.that(a.aClockwise).is(true);
                const end = point(a, 1);
                expect.that(near(end.x, 120, 1e-6) && near(end.y, 70, 1e-6)).is(true);
            });
            test("implicit lineTo after moveTo; z returns to the sub-path start", (expect) => {
                const p = pathById(paths, "implicit")!;
                expect.that(p.subPaths.length).is(2);
                expect.that(p.subPaths[0].curves.length).is(2);
                expect.that(p.subPaths[1].curves.length).is(2);
                expect.that(point(p.subPaths[1].curves[0], 0).equals(V(5, 5))).is(true);
                expect.that(point(p.subPaths[1].curves[1], 1).equals(V(15, 10))).is(true);
                expect.that(p.subPaths[1].autoClose).is(true);
            });
            test("compact numbers and flags", (expect) => {
                const c = pathById(paths, "compact")!.subPaths[0].curves;
                // sin(PI) is 1.2e-16, not 0: the arc starts 6e-16 off the
                // current point (an ulp at y = 0.2), so absellipse joins it
                // with a line, as in three.js.
                expect.that(c.length).is(4);
                expect.that(c[3] instanceof THREE.EllipseCurve).is(true);
                expect.that(point(c[0], 0).equals(V(1.5, 0.5))).is(true);
                const l = point(c[0], 1);
                expect.that(near(l.x, -20) && near(l.y, -0.3)).is(true);
                const l2 = point(c[1], 1);
                expect.that(near(l2.x, -19.5) && near(l2.y, 0.2)).is(true);
                const a = c[c.length - 1] as THREE.EllipseCurve;
                expect.that(near(a.xRadius, 5) && near(a.aX, -14.5) && a.aClockwise).is(true);
                expect.that(parseFloats("a1 1 0 1010 0", [3, 4], 7).length).is(0);
                const f = parseFloats("5 5 0 1010 0", [3, 4], 7);
                expect.that(f.length).is(7);
                expect.that(f[3] == 1 && f[4] == 0 && f[5] == 10 && f[6] == 0).is(true);
                const g = parseFloats("1e2.5-.5E-1,+3");
                expect.that(g.length).is(4);
                expect.that(g[0] == 100 && g[1] == 0.5 && near(g[2], -0.05) && g[3] == 3).is(true);
                // A syntax error stops the list.
                expect.that(parseFloats("1, , 2").length).is(1);
            });
            test("arcs: implicit repeats, radii scaled up", (expect) => {
                const c = pathById(paths, "arcs")!.subPaths[0].curves;
                expect.that(c.length).is(3);
                for (let i = 0; i < 3; i++) {
                    const a = c[i] as THREE.EllipseCurve;
                    expect.that(near(a.xRadius, 20) && near(a.yRadius, 20)).is(true);
                    expect.that(near(a.aX, 20 + 40 * <f64>i)).is(true);
                }
                expect.that((c[2] as THREE.EllipseCurve).aClockwise).is(true);
                const end = point(c[2], 1);
                expect.that(near(end.x, 120) && near(end.y, 100)).is(true);
            });
        });

        group("SVGLoader: basic shapes", () => {
            const paths = new SVGLoader().parse(SHAPES).paths;
            test("rect, rounded rect", (expect) => {
                expect.that(paths.length).is(7);
                const r = pathById(paths, "r")!;
                expect.that(r.subPaths[0].curves.length).is(4);
                expect.that(point(r.subPaths[0].curves[0], 0).equals(V(10, 20))).is(true);
                expect.that(point(r.subPaths[0].curves[1], 1).equals(V(40, 60))).is(true);
                expect.that(r.color.getHex()).is(0xff0000);
                const rr = pathById(paths, "rr")!;
                expect.that(rr.subPaths[0].curves.length).is(8);
                expect.that(point(rr.subPaths[0].curves[0], 0).equals(V(10, 0))).is(true);
                expect.that(rr.subPaths[0].curves[1] instanceof THREE.CubicBezierCurve).is(true);
                expect.that(rr.color.getHex()).is(0x00ff00);
            });
            test("circle, ellipse, line, polyline, polygon", (expect) => {
                const c = pathById(paths, "c")!;
                const ec = c.subPaths[0].curves[0] as THREE.EllipseCurve;
                expect.that(ec.aX == 50 && ec.xRadius == 25).is(true);
                expect.that(c.color.getHex()).is(0x0000ff);
                const e = pathById(paths, "e")!;
                const ee = e.subPaths[0].curves[0] as THREE.EllipseCurve;
                expect.that(ee.xRadius == 30 && ee.yRadius == 15).is(true);
                expect.that(near(e.color.g, new THREE.Color().setRGB(0, 0.5, 0, THREE.SRGBColorSpace).g)).is(true);
                const l = pathById(paths, "l")!;
                expect.that(l.subPaths[0].curves.length).is(1);
                expect.that(l.subPaths[0].autoClose).is(false);
                expect.that(l.userData.style.stroke).is("black");
                const pl = pathById(paths, "pl")!;
                expect.that(pl.subPaths[0].curves.length).is(3);
                expect.that(pl.userData.style.fill).is("none");
                // fill="none" leaves the ShapePath's default colour.
                expect.that(pl.color.getHex()).is(0xffffff);
                const pg = pathById(paths, "pg")!;
                expect.that(pg.subPaths[0].curves.length).is(2);
                expect.that(pg.subPaths[0].autoClose).is(true);
                expect.that(point(pg.subPaths[0].curves[1], 1).equals(V(25, 40))).is(true);
                expect.that(pg.color.getHex()).is(0x6495ed);
            });
        });

        group("SVGLoader: transforms", () => {
            const paths = new SVGLoader().parse(TRANSFORMS).paths;
            test("nested groups: translate, scale, rotate about a point", (expect) => {
                // defs content is not drawn; both uses draw "unit".
                expect.that(paths.length).is(10);
                const t1 = pathById(paths, "t1")!.subPaths[0].curves;
                expect.that(point(t1[0], 0).equals(V(102, 52))).is(true);
                expect.that(point(t1[1], 1).equals(V(106, 58))).is(true);
                const t2 = pathById(paths, "t2")!.subPaths[0].curves;
                const a = point(t2[0], 0), b = point(t2[0], 1);
                expect.that(near(a.x, 120) && near(a.y, 50)).is(true);
                expect.that(near(b.x, 120) && near(b.y, 58)).is(true);
            });
            test("skewX, skewY, matrix", (expect) => {
                const skx = pathById(paths, "skx")!.subPaths[0].curves;
                const p = point(skx[1], 1);
                expect.that(near(p.x, 20) && near(p.y, 10)).is(true);
                const sky = pathById(paths, "sky")!.subPaths[0].curves;
                const q = point(sky[0], 1);
                expect.that(near(q.x, 10) && near(q.y, 10 * Math.tan(Math.PI / 6))).is(true);
                const mat = pathById(paths, "mat")!.subPaths[0].curves;
                expect.that(point(mat[0], 0).equals(V(5, 6))).is(true);
                expect.that(point(mat[1], 1).equals(V(45, 66))).is(true);
            });
            test("ellipses: skewed (eigen decomposition), flipped", (expect) => {
                const cs = pathById(paths, "cs")!.subPaths[0].curves[0] as THREE.EllipseCurve;
                const r0 = Math.min(cs.xRadius, cs.yRadius), r1 = Math.max(cs.xRadius, cs.yRadius);
                expect.that(near(r0, 10) && near(r1, 20)).is(true);
                expect.that(near(cs.aX, 0) && near(cs.aY, 0)).is(true);
                const flip = pathById(paths, "flip")!.subPaths[0].curves[0] as THREE.EllipseCurve;
                expect.that(near(flip.aRotation, Math.PI) && flip.aClockwise).is(true);
                const p = point(flip, 0.25);
                expect.that(near(p.x, 0) && near(p.y, 5)).is(true);
                const ed = eigenDecomposition(2, 1, 2);
                expect.that(near(ed.rt1, 3) && near(ed.rt2, 1)).is(true);
                expect.that(near(Math.abs(ed.cs), Math.SQRT1_2) && near(Math.abs(ed.sn), Math.SQRT1_2)).is(true);
            });
            test("an arc under a non-uniform scale and rotation", (expect) => {
                const arc = pathById(paths, "arcskew")!.subPaths[0].curves[0] as THREE.EllipseCurve;
                // M = scale(1 3) rotate(45) translate(5 7).
                const m = new THREE.Matrix3().scale(1, 3);
                const r = new THREE.Matrix3().makeRotation(Math.PI / 4);
                const t = new THREE.Matrix3().makeTranslation(5, 7);
                m.multiply(r).multiply(t);
                const map = (x: f64, y: f64): THREE.Vector2 => {
                    const v = new THREE.Vector3(x, y, 1).applyMatrix3(m);
                    return new THREE.Vector2(v.x, v.y);
                };
                const s = point(arc, 0), e = point(arc, 1);
                const s0 = map(0, 0), e0 = map(40, 0);
                expect.that(near(s.x, s0.x, 1e-6) && near(s.y, s0.y, 1e-6)).is(true);
                expect.that(near(e.x, e0.x, 1e-6) && near(e.y, e0.y, 1e-6)).is(true);
                // The middle maps back onto the source ellipse, on its y < 0
                // half (the sweep the arc took).
                const inv = m.clone().invert();
                const mid = new THREE.Vector3(point(arc, 0.5).x, point(arc, 0.5).y, 1).applyMatrix3(inv);
                const onEllipse = Math.pow((mid.x - 20) / 20, 2) + Math.pow(mid.y / 10, 2);
                expect.that(near(onEllipse, 1, 1e-6) && mid.y < 0).is(true);
            });
            test("use: xlink:href and href, x / y, the use's style", (expect) => {
                let uses: Array<SVGShapePath> = [];
                for (let i = 0; i < paths.length; i++) {
                    if (paths[i].userData.node!.getAttribute("id") == "unit") uses.push(paths[i]);
                }
                expect.that(uses.length).is(2);
                expect.that(point(uses[0].subPaths[0].curves[0], 0).equals(V(50, 60))).is(true);
                expect.that(uses[0].color.getHex()).is(0xffa500);
                expect.that(point(uses[1].subPaths[0].curves[0], 0).equals(V(5, 5))).is(true);
            });
        });

        group("SVGLoader: style and CSS", () => {
            const paths = new SVGLoader().parse(CSS).paths;
            test("inheritance, classes, ids, element selectors, inline style", (expect) => {
                expect.that(paths.length).is(10);
                const inherit = pathById(paths, "inherit")!;
                expect.that(inherit.color.getHex()).is(0x800080);
                expect.that(inherit.userData.style.fillOpacity).is(0.5);
                expect.that(inherit.userData.style.stroke).is("gray");
                const cls = pathById(paths, "cls")!;
                expect.that(cls.userData.style.fill).is("red");
                expect.that(cls.userData.style.strokeWidth).is(3);
                const cls2 = pathById(paths, "cls2")!.userData.style;
                expect.that(cls2.fill).is("#00ff00");
                expect.that(cls2.stroke).is("black");
                expect.that(cls2.strokeWidth).is(0.5);
                expect.that(cls2.strokeLineJoin).is("round");
                expect.that(cls2.strokeLineCap).is("square");
                expect.that(cls2.strokeMiterLimit).is(2);
                const special = pathById(paths, "special")!;
                expect.that(special.userData.style.fill).is("blue");
                expect.that(special.userData.style.strokeWidth).is(3);
                const inline = pathById(paths, "inline")!;
                expect.that(inline.color.getHex()).is(0x123456);
                expect.that(inline.userData.style.opacity).is(1);
                const attr = pathById(paths, "attr")!.userData.style;
                expect.that(attr.fill).is("#abcdef");
                expect.that(attr.fillRule).is("evenodd");
                expect.that(attr.visibility).is("hidden");
                // Element selectors, below class selectors.
                const el = pathById(paths, "el")!.userData.style;
                expect.that(el.fill).is("red");
                expect.that(el.stroke).is("navy");
            });
            test("units, display, clamping", (expect) => {
                const mm = pathById(paths, "mm")!.subPaths[0].curves;
                const first = point(mm[0], 0);
                // x = 1mm, rx = 2cm at 90 dpi; y = 1in.
                expect.that(near(first.x, 90 / 25.4 + 2 * 90 / 2.54) && near(first.y, 90)).is(true);
                // width 10pt (12.5), height 1pc (15).
                const right = point(mm[0], 1);
                expect.that(near(right.x, 90 / 25.4 + 12.5 - 2 * 90 / 2.54)).is(true);
                const pct = pathById(paths, "pct")!.subPaths[0].curves;
                expect.that(point(pct[0], 0).equals(V(50, 2))).is(true);
                const hidden = pathById(paths, "hidden")!.userData.style;
                expect.that(hidden.display).is("none");
                expect.that(hidden.strokeOpacity).is(0);
                const loader = new SVGLoader();
                loader.defaultUnit = "mm";
                const inMM = loader.parse(`<svg><rect width="90" height="1in"/></svg>`).paths[0].subPaths[0].curves;
                const corner = point(inMM[1], 1);
                expect.that(near(corner.x, 25.4) && near(corner.y, 25.4)).is(true);
            });
            test("applyViewBox (Rive-only)", (expect) => {
                const svg = `<svg viewBox="10 10 20 10" width="200" height="200"><rect x="10" y="10" width="20" height="10"/></svg>`;
                const plain = new SVGLoader().parse(svg).paths[0].subPaths[0].curves;
                expect.that(point(plain[0], 0).equals(V(10, 10))).is(true);
                const loader = new SVGLoader();
                loader.applyViewBox = true;
                const fitted = loader.parse(svg).paths[0].subPaths[0].curves;
                // Scale 10 (meet), centred vertically: y from 50 to 150.
                expect.that(point(fitted[0], 0).equals(V(0, 50))).is(true);
                expect.that(point(fitted[1], 1).equals(V(200, 150))).is(true);
            });
        });

        group("SVGLoader.createShapes", () => {
            const paths = new SVGLoader().parse(HOLES).paths;
            const holesOf = (id: string): string => {
                let s = "";
                const shapes = SVGLoader.createShapes(pathById(paths, id)!);
                for (let i = 0; i < shapes.length; i++) s += (i > 0 ? "," : "") + shapes[i].holes.length.toString();
                return s;
            };
            test("nonzero: an opposite winding is a hole, the same is not", (expect) => {
                expect.that(holesOf("opposite")).is("1");
                expect.that(holesOf("same")).is("0,0");
                expect.that(holesOf("ring")).is("1");
            });
            test("evenodd: every other nesting level is a hole", (expect) => {
                expect.that(holesOf("sameEvenOdd")).is("1");
                expect.that(holesOf("nested")).is("1,0,0");
                // Nonzero with alternating windings: the same nesting.
                expect.that(holesOf("nestedNonzero")).is("1,0");
            });
            test("a plain ShapePath (no style) is nonzero; shapes extrude", (expect) => {
                const sp = new THREE.ShapePath();
                // Closed by hand: the scanline test reads the points as they are.
                sp.moveTo(0, 0); sp.lineTo(10, 0); sp.lineTo(10, 10); sp.lineTo(0, 10); sp.lineTo(0, 0);
                sp.moveTo(2, 2); sp.lineTo(2, 8); sp.lineTo(8, 8); sp.lineTo(8, 2); sp.lineTo(2, 2);
                const shapes = SVGLoader.createShapes(sp);
                expect.that(shapes.length).is(1);
                expect.that(shapes[0].holes.length).is(1);
                const options = new THREE.ExtrudeGeometryOptions();
                options.depth = 2;
                options.bevelEnabled = false;
                const g = new THREE.ExtrudeGeometry(shapes, options);
                expect.that(g.getAttribute("position")!.count > 0).is(true);
                g.computeBoundingBox();
                expect.that(near(g.boundingBox!.max.z, 2)).is(true);
            });
        });

        group("SVGLoader strokes", () => {
            const straight = [V(0, 0), V(10, 0)];
            const ell = [V(0, 0), V(10, 0), V(10, 10)];
            const ellRight = [V(0, 0), V(10, 0), V(10, -10)];
            const collinear = [V(0, 0), V(5, 0), V(10, 0)];
            const sharp = [V(0, 0), V(10, 0), V(0, 1)];
            const zigzag = [V(0, 0), V(10, 0), V(10, 10), V(20, 10), V(20, 0)];
            const square = [V(0, 0), V(10, 0), V(10, 10), V(0, 10), V(0, 0)];
            const dup = [V(0, 0), V(0, 0), V(10, 0), V(10, 0.0001), V(10, 10)];
            test("joins on a right angle, both sides", (expect) => {
                expect.that(strokeCount(ell, "miter", "butt")).is(3 * 12);
                expect.that(strokeCount(ell, "bevel", "butt")).is(3 * 15);
                expect.that(strokeCount(ell, "round", "butt")).is(3 * (12 + 36 + 6));
                expect.that(strokeCount(ell, "miter-clip", "butt", 1)).is(3 * 27);
                // Over the miter limit, "miter" bevels.
                expect.that(strokeCount(ell, "miter", "butt", 1)).is(3 * 15);
                expect.that(strokeCount(ellRight, "miter", "butt")).is(3 * 12);
                expect.that(strokeCount(ellRight, "bevel", "butt")).is(3 * 15);
                expect.that(strokeCount(ellRight, "round", "butt")).is(3 * 54);
                expect.that(strokeCount(ellRight, "miter-clip", "butt", 1)).is(3 * 27);
            });
            test("caps", (expect) => {
                expect.that(strokeCount(straight, "miter", "butt")).is(3 * 6);
                expect.that(strokeCount(straight, "miter", "square")).is(3 * 6);
                expect.that(strokeCount(straight, "miter", "round")).is(3 * (6 + 72));
                expect.that(strokeCount(ell, "round", "round")).is(3 * (54 + 72));
                expect.that(strokeCount(ell, "bevel", "square")).is(3 * 15);
                // Square caps extend the ends by half the width.
                const vertices: Array<f64> = [];
                SVGLoader.pointsToStrokeWithBuffers(straight, SVGLoader.getStrokeStyle(2, "#000", "miter", "square"),
                    12, 0.001, vertices, [], []);
                let minX: f64 = 1e9, maxX: f64 = -1e9, minY: f64 = 1e9, maxY: f64 = -1e9;
                for (let i = 0; i < vertices.length; i += 3) {
                    minX = Math.min(minX, vertices[i]); maxX = Math.max(maxX, vertices[i]);
                    minY = Math.min(minY, vertices[i + 1]); maxY = Math.max(maxY, vertices[i + 1]);
                }
                expect.that(minX == -1 && maxX == 11 && minY == -1 && maxY == 1).is(true);
            });
            test("straight, sharp, zigzag, closed and duplicated points", (expect) => {
                expect.that(strokeCount(collinear, "round", "butt")).is(3 * 12);
                // A turn too sharp for the inner side: segment, then join.
                expect.that(strokeCount(sharp, "miter", "butt")).is(3 * 15);
                expect.that(strokeCount(sharp, "bevel", "butt")).is(3 * 15);
                expect.that(strokeCount(sharp, "round", "butt")).is(3 * 48);
                expect.that(strokeCount(sharp, "miter-clip", "butt", 1)).is(3 * 21);
                expect.that(strokeCount(zigzag, "miter", "butt")).is(3 * 24);
                expect.that(strokeCount(zigzag, "bevel", "butt")).is(3 * 33);
                expect.that(strokeCount(zigzag, "round", "butt")).is(3 * 150);
                expect.that(strokeCount(zigzag, "miter-clip", "butt", 1)).is(3 * 69);
                // Closed: a join at every corner, no caps.
                expect.that(strokeCount(square, "miter", "round")).is(3 * 24);
                expect.that(strokeCount(square, "bevel", "round")).is(3 * 36);
                expect.that(strokeCount(square, "round", "butt")).is(3 * 192);
                expect.that(strokeCount(square, "miter-clip", "butt", 1)).is(3 * 84);
                // Points closer than minDistance merge (not the first two).
                expect.that(strokeCount(dup, "miter", "butt")).is(3 * 18);
                expect.that(strokeCount(dup, "bevel", "round")).is(3 * (21 + 72));
                expect.that(SVGLoader.pointsToStrokeWithBuffers([V(1, 1)], new SVGStyle())).is(0);
            });
            test("counting without buffers; pointsToStroke geometry", (expect) => {
                const style = SVGLoader.getStrokeStyle(2, "#000", "round", "round");
                expect.that(SVGLoader.pointsToStrokeWithBuffers(ell, style, 5)).is(3 * (12 + 15 + 6 + 30));
                const square2 = SVGLoader.getStrokeStyle(2, "#000", "miter", "square");
                expect.that(SVGLoader.pointsToStrokeWithBuffers(ell, square2)).is(3 * 12);
                const g = SVGLoader.pointsToStroke(ell, SVGLoader.getStrokeStyle(2))!;
                expect.that(g.getAttribute("position")!.count).is(12);
                expect.that(g.getAttribute("normal")!.getZ(5)).is(1);
                expect.that(g.getAttribute("uv")!.count).is(12);
                expect.that(SVGLoader.pointsToStroke([V(0, 0)], SVGLoader.getStrokeStyle()) == null).is(true);
                const def = SVGLoader.getStrokeStyle();
                expect.that(def.strokeWidth == 1 && def.strokeColor == "#000" && def.strokeLineJoin == "miter"
                    && def.strokeLineCap == "butt" && def.strokeMiterLimit == 4).is(true);
                // Writing at an offset fills the arrays up to it.
                const v: Array<f64> = [];
                SVGLoader.pointsToStrokeWithBuffers(straight, def, 12, 0.001, v, null, null, 2);
                expect.that(v.length).is(3 * 8);
            });
        });

        group("Color.setStyle, Matrix3 2D, Box2 (used by SVGLoader)", () => {
            test("CSS colours as three.js parses them", (expect) => {
                const c = new THREE.Color();
                expect.that(c.setStyle("rgba(255, 0, 0, 0.5)").getHex()).is(0xff0000);
                expect.that(c.setStyle("rgb(0%, 100%, 0%)").getHex()).is(0x00ff00);
                expect.that(c.setStyle("RebeccaPurple").getHex()).is(0x663399);
                expect.that(c.setStyle("#FF8800").getHex()).is(0xff8800);
                expect.that(c.setStyle("#08f").getHex()).is(0x0088ff);
                expect.that(c.setStyle("hsla(240, 100%, 50%, 0.3)").getHex()).is(0x0000ff);
                // Unknown styles leave the colour as it was.
                expect.that(c.setStyle("url(#gradient)").getHex()).is(0x0000ff);
                expect.that(c.setStyle("notacolor").getHex()).is(0x0000ff);
                c.setStyle("#ffffff", THREE.LinearSRGBColorSpace);
                expect.that(c.r).is(1);
            });
            test("Matrix3 translate / rotate / scale and Box2", (expect) => {
                const m = new THREE.Matrix3().translate(1, 2).scale(2, 3).rotate(Math.PI / 2);
                const v = new THREE.Vector3(1, 0, 1).applyMatrix3(m);
                // (1, 0) -> (2, 2) -> (4, 6) -> rotate(theta) is three.js's
                // clockwise-in-y-up: (6, -4).
                expect.that(near(v.x, 6) && near(v.y, -4)).is(true);
                const t = new THREE.Matrix3().makeTranslation(new THREE.Vector2(3, 4));
                expect.that(t.elements[6] == 3 && t.elements[7] == 4).is(true);
                const b = new THREE.Box2().setFromPoints([V(1, 2), V(-1, 5)]);
                const center = b.getCenter(new THREE.Vector2());
                expect.that(center.x == 0 && center.y == 3.5).is(true);
                expect.that(b.containsPoint(V(0, 4)) && !b.containsPoint(V(2, 4))).is(true);
                expect.that(new THREE.Box2().isEmpty()).is(true);
            });
        });

        group("SVGLoader: assets and Rive paths", () => {
            test("the Models logo from its BlobAsset", (expect) => {
                const bytes = this.blob("threeas_logo");
                if (bytes == null) return;
                const data = new SVGLoader().parse(String.UTF8.decode(bytes!));
                // The mark, the dot (a use), the bar, the zigzag.
                expect.that(data.paths.length).is(4);
                const mark = data.paths[0];
                expect.that(mark.color.getHex()).is(0xffb547);
                const shapes = SVGLoader.createShapes(mark);
                expect.that(shapes.length).is(1);
                expect.that(shapes[0].holes.length).is(1);
                expect.that(data.paths[1].color.getHex()).is(0x4fc3f7);
                const line = data.paths[3];
                expect.that(line.userData.style.fill).is("none");
                expect.that(line.userData.style.strokeWidth).is(7);
                const stroke = SVGLoader.pointsToStroke(line.subPaths[0].getPoints(), line.userData.style);
                expect.that(stroke != null).is(true);
                // 4 segments, 3 round joins of 12 divisions, 2 round caps.
                expect.that(stroke!.getAttribute("position")!.count).is(4 * 6 + 3 * (6 + 36) + 2 * 36);
            });
            test("a ShapePath as a Rive path", (expect) => {
                const abs = pathById(new SVGLoader().parse(COMMANDS).paths, "abs")!;
                const rp: RivePath = THREE.rivePathFromShapePath(abs);
                // moveTo, 4 lines, 2 cubics, 2 quads, the half circle as 2
                // cubics, close.
                expect.that(rp.length).is(12);
                expect.that(rp[0].type).is("moveTo");
                expect.that(rp[9].type).is("cubicTo");
                expect.that(rp[11].type).is("close");
                const end = rp[10][2];
                expect.that(near(<f64>end.x, 120, 1e-4) && near(<f64>end.y, 30, 1e-4)).is(true);
                // The half circle's middle control points bulge to y = 20.
                const mid = rp[9][2];
                expect.that(near(<f64>mid.x, 110, 1e-4) && near(<f64>mid.y, 20, 1e-4)).is(true);
                const flipped = THREE.rivePathFromShapePath(abs, 2, true);
                expect.that(near(<f64>flipped[0][0].y, -20, 1e-4)).is(true);
            });
        });
    }
}
