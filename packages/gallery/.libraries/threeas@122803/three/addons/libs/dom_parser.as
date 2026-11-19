// A small DOMParser: AnimaScript has no DOM, and three.js's text loaders
// (SVGLoader) read XML through one. `new DOMParser().parseFromString(text)`
// returns an XMLDocument of XMLNodes shaped like the DOM calls those loaders
// make: nodeType, nodeName, childNodes, parentNode, getAttribute /
// hasAttribute / getAttributeNS, textContent, getElementById,
// getElementsByTagName, viewportElement; and the CSSOM bits SVGLoader reads:
// `node.style` (a CSSStyleDeclaration from the style attribute) and
// `node.sheet` (a CSSStyleSheet from a <style> element's text).
//
// It reads elements, attributes (either quote), text, comments, CDATA, the
// XML declaration (into xmlVersion / xmlEncoding / xmlStandalone, not a node,
// as the DOM), processing instructions, a DOCTYPE (with its internal subset,
// whose <!ENTITY> declarations are expanded: Illustrator writes its
// namespaces that way), the predefined entities and character references.
// Line ends become "\n", and tabs and line ends in attribute values spaces.
//
// It is lenient where a browser's XML parser stops at the first error: a
// mismatched end tag closes up to its open element, a stray "<" or "&" is
// text, and every problem is listed in `document.errors` (browsers put a
// <parsererror> element in the document instead). No validation, external
// entities or namespace processing beyond lookupNamespaceURI / getAttributeNS.

export class XMLAttribute {
    name: string;
    value: string;

    constructor(name: string, value: string) {
        this.name = name;
        this.value = value;
    }

    get localName(): string {
        const colon = this.name.indexOf(":");
        return colon >= 0 ? this.name.substring(colon + 1) : this.name;
    }

    /// The prefix before ":", "" when there is none.
    get prefix(): string {
        const colon = this.name.indexOf(":");
        return colon >= 0 ? this.name.substring(0, colon) : "";
    }
}

/// The declarations of a style attribute or CSS rule, by property name
/// (lowercase, hyphenated: "stroke-width"). Missing properties read "".
export class CSSStyleDeclaration {
    private names: Array<string> = [];
    private values: Map<string, string> = new Map<string, string>();
    private priorities: Map<string, string> = new Map<string, string>();

    /// "fill: red; stroke-width: 2px" (comments, quotes and "!important"
    /// handled).
    static parse(text: string): CSSStyleDeclaration {
        const out = new CSSStyleDeclaration();
        const body = stripCSSComments(text);
        const decls = splitTopLevel(body, 59);
        for (let i = 0; i < decls.length; i++) {
            const d = decls[i];
            const colon = d.indexOf(":");
            if (colon <= 0) continue;
            const name = d.substring(0, colon).trim().toLowerCase();
            let value = d.substring(colon + 1).trim();
            let priority = "";
            const bang = value.lastIndexOf("!");
            if (bang >= 0 && value.substring(bang + 1).trim().toLowerCase() == "important") {
                value = value.substring(0, bang).trim();
                priority = "important";
            }
            if (name.length == 0 || value.length == 0) continue;
            out.setProperty(name, value, priority);
        }
        return out;
    }

    get length(): i32 { return this.names.length; }

    /// The name of the i-th property.
    item(index: i32): string { return index >= 0 && index < this.names.length ? this.names[index] : ""; }

    getPropertyValue(name: string): string {
        const key = name.toLowerCase();
        return this.values.has(key) ? this.values.get(key) : "";
    }

    getPropertyPriority(name: string): string {
        const key = name.toLowerCase();
        return this.priorities.has(key) ? this.priorities.get(key) : "";
    }

    setProperty(name: string, value: string, priority: string = ""): void {
        const key = name.toLowerCase();
        if (value.length == 0) {
            this.removeProperty(key);
            return;
        }
        if (!this.values.has(key)) this.names.push(key);
        this.values.set(key, value);
        this.priorities.set(key, priority);
    }

    removeProperty(name: string): string {
        const key = name.toLowerCase();
        if (!this.values.has(key)) return "";
        const old = this.values.get(key);
        this.values.delete(key);
        this.priorities.delete(key);
        const i = this.names.indexOf(key);
        if (i >= 0) this.names.splice(i, 1);
        return old;
    }

    get cssText(): string {
        let s = "";
        for (let i = 0; i < this.names.length; i++) {
            const n = this.names[i];
            if (s.length > 0) s += " ";
            s += n + ": " + this.values.get(n);
            if (this.priorities.get(n).length > 0) s += " !important";
            s += ";";
        }
        return s;
    }
}

/// A rule of a CSSStyleSheet: style rules (`type` 1) have `selectorText`
/// and `style`; at-rules keep their name in `atRule` and text in `cssText`.
export class CSSRule {
    static readonly STYLE_RULE: i32 = 1;
    static readonly IMPORT_RULE: i32 = 3;
    static readonly MEDIA_RULE: i32 = 4;
    static readonly FONT_FACE_RULE: i32 = 5;
    static readonly PAGE_RULE: i32 = 6;
    static readonly KEYFRAMES_RULE: i32 = 7;

    type: i32;
    selectorText: string = "";
    style: CSSStyleDeclaration = new CSSStyleDeclaration();
    atRule: string = "";
    cssText: string = "";

    constructor(type: i32) {
        this.type = type;
    }
}

/// A <style> element's rules, in order. @media and other at-rules are
/// rules of their own (not STYLE_RULE), their contents not parsed.
export class CSSStyleSheet {
    cssRules: Array<CSSRule> = [];

    static parse(text: string): CSSStyleSheet {
        const sheet = new CSSStyleSheet();
        // CDO / CDC markers ("<!--", "-->") are whitespace to CSS.
        const s = stripCSSComments(text).replaceAll("<!--", " ").replaceAll("-->", " ");
        const n = s.length;
        let i = 0;
        while (i < n) {
            while (i < n && isSpace(s.charCodeAt(i))) i++;
            if (i >= n) break;
            if (s.charCodeAt(i) == 64) {
                // An at-rule: up to ";" or through its block.
                let j = i + 1;
                while (j < n && isCSSNameChar(s.charCodeAt(j))) j++;
                const name = s.substring(i + 1, j).toLowerCase();
                const end = findAtRuleEnd(s, j);
                const rule = new CSSRule(atRuleType(name));
                rule.atRule = name;
                rule.cssText = s.substring(i, end).trim();
                sheet.cssRules.push(rule);
                i = end;
                continue;
            }
            const open = findOutsideQuotes(s, i, 123);
            if (open < 0) break;
            const close = findBlockEnd(s, open);
            const rule = new CSSRule(CSSRule.STYLE_RULE);
            rule.selectorText = s.substring(i, open).trim();
            rule.style = CSSStyleDeclaration.parse(s.substring(open + 1, close < n ? close : n));
            rule.cssText = s.substring(i, close < n ? close + 1 : n).trim();
            sheet.cssRules.push(rule);
            i = close + 1;
        }
        return sheet;
    }
}

export class XMLNode {
    static readonly ELEMENT_NODE: i32 = 1;
    static readonly ATTRIBUTE_NODE: i32 = 2;
    static readonly TEXT_NODE: i32 = 3;
    static readonly CDATA_SECTION_NODE: i32 = 4;
    static readonly PROCESSING_INSTRUCTION_NODE: i32 = 7;
    static readonly COMMENT_NODE: i32 = 8;
    static readonly DOCUMENT_NODE: i32 = 9;
    static readonly DOCUMENT_TYPE_NODE: i32 = 10;

    nodeType: i32;
    /// The tag name as written (with its prefix) for elements; "#text",
    /// "#cdata-section", "#comment", "#document"; a processing
    /// instruction's target; a doctype's name.
    nodeName: string;
    /// The text of text, CDATA, comment and processing instruction nodes
    /// ("" for others, where the DOM has null).
    nodeValue: string = "";
    parentNode: XMLNode? = null;
    childNodes: Array<XMLNode> = [];
    /// An element's attributes, in document order.
    attributes: Array<XMLAttribute> = [];
    /// A doctype's public and system identifiers and internal subset.
    publicId: string = "";
    systemId: string = "";
    internalSubset: string = "";

    private styleCache: CSSStyleDeclaration? = null;
    private styleSource: string = "";
    private sheetCache: CSSStyleSheet? = null;
    private sheetSource: string = "";

    constructor(nodeType: i32, nodeName: string) {
        this.nodeType = nodeType;
        this.nodeName = nodeName;
    }

    get tagName(): string { return this.nodeName; }

    get localName(): string {
        const colon = this.nodeName.indexOf(":");
        return colon >= 0 ? this.nodeName.substring(colon + 1) : this.nodeName;
    }

    /// The prefix before ":", "" when there is none.
    get prefix(): string {
        const colon = this.nodeName.indexOf(":");
        return colon >= 0 ? this.nodeName.substring(0, colon) : "";
    }

    /// The element's namespace, from the xmlns declarations in scope.
    get namespaceURI(): string? {
        if (this.nodeType != XMLNode.ELEMENT_NODE) return null;
        return this.lookupNamespaceURI(this.prefix);
    }

    get data(): string { return this.nodeValue; }

    get id(): string {
        const v = this.getAttribute("id");
        return v != null ? v! : "";
    }

    get ownerDocument(): XMLDocument? {
        let n: XMLNode? = this;
        while (n != null) {
            if (n instanceof XMLDocument) return n as XMLDocument;
            n = n.parentNode;
        }
        return null;
    }

    get parentElement(): XMLNode? {
        const p = this.parentNode;
        return p != null && p.nodeType == XMLNode.ELEMENT_NODE ? p : null;
    }

    get firstChild(): XMLNode? { return this.childNodes.length > 0 ? this.childNodes[0] : null; }
    get lastChild(): XMLNode? { return this.childNodes.length > 0 ? this.childNodes[this.childNodes.length - 1] : null; }

    get nextSibling(): XMLNode? {
        const p = this.parentNode;
        if (p == null) return null;
        const i = p.childNodes.indexOf(this);
        return i >= 0 && i + 1 < p.childNodes.length ? p.childNodes[i + 1] : null;
    }

    get previousSibling(): XMLNode? {
        const p = this.parentNode;
        if (p == null) return null;
        const i = p.childNodes.indexOf(this);
        return i > 0 ? p.childNodes[i - 1] : null;
    }

    /// The child elements (no text or comments).
    get children(): Array<XMLNode> {
        const out: Array<XMLNode> = [];
        for (let i = 0; i < this.childNodes.length; i++) {
            if (this.childNodes[i].nodeType == XMLNode.ELEMENT_NODE) out.push(this.childNodes[i]);
        }
        return out;
    }

    get firstElementChild(): XMLNode? {
        for (let i = 0; i < this.childNodes.length; i++) {
            if (this.childNodes[i].nodeType == XMLNode.ELEMENT_NODE) return this.childNodes[i];
        }
        return null;
    }

    /// The text of every text and CDATA node inside, in order (a text,
    /// comment or PI node's own value).
    get textContent(): string {
        const t = this.nodeType;
        if (t == XMLNode.TEXT_NODE || t == XMLNode.CDATA_SECTION_NODE || t == XMLNode.COMMENT_NODE
            || t == XMLNode.PROCESSING_INSTRUCTION_NODE) return this.nodeValue;
        if (t == XMLNode.DOCUMENT_NODE || t == XMLNode.DOCUMENT_TYPE_NODE) return "";
        let s = "";
        for (let i = 0; i < this.childNodes.length; i++) {
            const c = this.childNodes[i];
            if (c.nodeType == XMLNode.COMMENT_NODE || c.nodeType == XMLNode.PROCESSING_INSTRUCTION_NODE) continue;
            s += c.textContent;
        }
        return s;
    }

    set textContent(value: string) {
        const t = this.nodeType;
        if (t != XMLNode.ELEMENT_NODE) {
            this.nodeValue = value;
            return;
        }
        for (let i = 0; i < this.childNodes.length; i++) this.childNodes[i].parentNode = null;
        this.childNodes = [];
        if (value.length > 0) {
            const text = new XMLNode(XMLNode.TEXT_NODE, "#text");
            text.nodeValue = value;
            this.appendChild(text);
        }
    }

    hasAttributes(): bool { return this.attributes.length > 0; }

    /// The attribute's value, or null when it is missing (as the DOM).
    getAttribute(name: string): string? {
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].name == name) return this.attributes[i].value;
        }
        return null;
    }

    hasAttribute(name: string): bool { return this.getAttribute(name) != null; }

    setAttribute(name: string, value: string): void {
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].name == name) {
                this.attributes[i].value = value;
                return;
            }
        }
        this.attributes.push(new XMLAttribute(name, value));
    }

    removeAttribute(name: string): void {
        for (let i = 0; i < this.attributes.length; i++) {
            if (this.attributes[i].name == name) {
                this.attributes.splice(i, 1);
                return;
            }
        }
    }

    /// The attribute `localName` in `namespace` (an unprefixed attribute
    /// has no namespace: pass null or ""), or null.
    getAttributeNS(namespace: string?, localName: string): string? {
        const ns = namespace != null ? namespace! : "";
        for (let i = 0; i < this.attributes.length; i++) {
            const a = this.attributes[i];
            if (a.localName != localName) continue;
            const prefix = a.prefix;
            if (prefix.length == 0) {
                if (ns.length == 0 && a.name != "xmlns") return a.value;
                continue;
            }
            const uri = this.lookupNamespaceURI(prefix);
            if (uri != null && uri! == ns) return a.value;
        }
        return null;
    }

    hasAttributeNS(namespace: string?, localName: string): bool {
        return this.getAttributeNS(namespace, localName) != null;
    }

    /// The namespace bound to `prefix` ("" or null: the default namespace)
    /// by the xmlns attributes on this element and its ancestors.
    lookupNamespaceURI(prefix: string?): string? {
        const p = prefix != null ? prefix! : "";
        if (p == "xml") return "http://www.w3.org/XML/1998/namespace";
        if (p == "xmlns") return "http://www.w3.org/2000/xmlns/";
        const attr = p.length > 0 ? "xmlns:" + p : "xmlns";
        let n: XMLNode? = this;
        while (n != null) {
            if (n.nodeType == XMLNode.ELEMENT_NODE) {
                const v = n.getAttribute(attr);
                if (v != null) return v!.length > 0 ? v : null;
            }
            n = n.parentNode;
        }
        return null;
    }

    appendChild(child: XMLNode): XMLNode {
        const old = child.parentNode;
        if (old != null) old.removeChild(child);
        child.parentNode = this;
        this.childNodes.push(child);
        return child;
    }

    removeChild(child: XMLNode): XMLNode {
        const i = this.childNodes.indexOf(child);
        if (i >= 0) {
            this.childNodes.splice(i, 1);
            child.parentNode = null;
        }
        return child;
    }

    /// Whether `other` is this node or inside it.
    contains(other: XMLNode?): bool {
        let n = other;
        while (n != null) {
            if (n === this) return true;
            n = n.parentNode;
        }
        return false;
    }

    /// The first element inside this one (depth first) whose id is `id`.
    getElementById(id: string): XMLNode? {
        for (let i = 0; i < this.childNodes.length; i++) {
            const c = this.childNodes[i];
            if (c.nodeType != XMLNode.ELEMENT_NODE) continue;
            const v = c.getAttribute("id");
            if (v != null && v! == id) return c;
            const found = c.getElementById(id);
            if (found != null) return found;
        }
        return null;
    }

    /// The elements inside this one named `name` ("*": all), in document
    /// order.
    getElementsByTagName(name: string): Array<XMLNode> {
        const out: Array<XMLNode> = [];
        collectByTagName(this, name, out);
        return out;
    }

    /// The nearest <svg> element around this one (null for the outermost),
    /// as SVGElement.viewportElement.
    get viewportElement(): XMLNode? {
        let n = this.parentNode;
        while (n != null) {
            if (n.nodeType == XMLNode.ELEMENT_NODE && n.localName == "svg") return n;
            n = n.parentNode;
        }
        return null;
    }

    /// The style attribute's declarations (empty without one).
    get style(): CSSStyleDeclaration {
        const attr = this.getAttribute("style");
        const text = attr != null ? attr! : "";
        const cached = this.styleCache;
        if (cached != null && this.styleSource == text) return cached;
        const parsed = CSSStyleDeclaration.parse(text);
        this.styleCache = parsed;
        this.styleSource = text;
        return parsed;
    }

    /// A <style> element's stylesheet (null for other nodes).
    get sheet(): CSSStyleSheet? {
        if (this.nodeType != XMLNode.ELEMENT_NODE || this.localName != "style") return null;
        const text = this.textContent;
        const cached = this.sheetCache;
        if (cached != null && this.sheetSource == text) return cached;
        const parsed = CSSStyleSheet.parse(text);
        this.sheetCache = parsed;
        this.sheetSource = text;
        return parsed;
    }
}

export class XMLDocument extends XMLNode {
    /// From the XML declaration ("" without one).
    xmlVersion: string = "";
    xmlEncoding: string = "";
    xmlStandalone: bool = false;
    /// The DOCTYPE node, or null.
    doctype: XMLNode? = null;
    /// The internal subset's general entities, by name.
    entities: Map<string, string> = new Map<string, string>();
    /// What the parser had to recover from; empty for a well-formed file.
    errors: Array<string> = [];

    constructor() {
        super(XMLNode.DOCUMENT_NODE, "#document");
    }

    /// The root element.
    get documentElement(): XMLNode? { return this.firstElementChild; }

    createElement(name: string): XMLNode { return new XMLNode(XMLNode.ELEMENT_NODE, name); }

    createTextNode(data: string): XMLNode {
        const n = new XMLNode(XMLNode.TEXT_NODE, "#text");
        n.nodeValue = data;
        return n;
    }
}

export class DOMParser {
    /// Parses `text` as XML (`mimeType` is accepted for three.js's call
    /// shape: "image/svg+xml", "application/xml", "text/xml").
    parseFromString(text: string, mimeType: string = "application/xml"): XMLDocument {
        return new XMLReader(text).read();
    }
}

// The parser.

class XMLReader {
    s: string;
    n: i32;
    i: i32 = 0;
    doc: XMLDocument = new XMLDocument();
    stack: Array<XMLNode> = [];

    constructor(text: string) {
        // Line ends are "\n" to an XML application.
        this.s = text.indexOf("\r") >= 0 ? text.replaceAll("\r\n", "\n").replaceAll("\r", "\n") : text;
        this.n = this.s.length;
    }

    read(): XMLDocument {
        const s = this.s;
        this.stack.push(this.doc);
        if (this.n > 0 && s.charCodeAt(0) == 0xFEFF) this.i = 1;
        while (this.i < this.n) {
            if (s.charCodeAt(this.i) != 60) {
                this.readText();
            } else if (this.startsWith("<!--")) {
                this.readComment();
            } else if (this.startsWith("<![CDATA[")) {
                this.readCDATA();
            } else if (this.startsWithIgnoreCase("<!DOCTYPE")) {
                this.readDoctype();
            } else if (this.startsWith("<?")) {
                this.readProcessingInstruction();
            } else if (this.startsWith("</")) {
                this.readEndTag();
            } else if (this.i + 1 < this.n && isNameStart(s.charCodeAt(this.i + 1))) {
                this.readStartTag();
            } else {
                this.error("a '<' that starts no markup");
                this.appendText("<");
                this.i++;
            }
        }
        for (let k = this.stack.length - 1; k > 0; k--) this.error("<" + this.stack[k].nodeName + "> is not closed");
        if (this.doc.documentElement == null) this.error("no root element");
        return this.doc;
    }

    private top(): XMLNode { return this.stack[this.stack.length - 1]; }

    private error(message: string): void {
        this.doc.errors.push(message + " (at " + this.i.toString() + ")");
    }

    private startsWith(prefix: string): bool {
        const s = this.s;
        if (this.i + prefix.length > this.n) return false;
        for (let k = 0; k < prefix.length; k++) {
            if (s.charCodeAt(this.i + k) != prefix.charCodeAt(k)) return false;
        }
        return true;
    }

    private startsWithIgnoreCase(prefix: string): bool {
        if (this.i + prefix.length > this.n) return false;
        return this.s.substring(this.i, this.i + prefix.length).toUpperCase() == prefix.toUpperCase();
    }

    /// Text up to the next "<", entities decoded; whitespace outside the
    /// root element is dropped (the DOM keeps none there).
    private readText(): void {
        let end = this.s.indexOf("<", this.i);
        if (end < 0) end = this.n;
        const raw = this.s.substring(this.i, end);
        this.i = end;
        if (this.stack.length == 1) {
            if (raw.trim().length > 0) this.error("text outside the root element");
            return;
        }
        this.appendText(this.decode(raw, false, 0));
    }

    private appendText(text: string): void {
        if (text.length == 0 || this.stack.length == 1) return;
        const parent = this.top();
        const last = parent.lastChild;
        if (last != null && last.nodeType == XMLNode.TEXT_NODE) {
            last.nodeValue += text;
            return;
        }
        const node = new XMLNode(XMLNode.TEXT_NODE, "#text");
        node.nodeValue = text;
        parent.appendChild(node);
    }

    private readComment(): void {
        let end = this.s.indexOf("-->", this.i + 4);
        if (end < 0) {
            this.error("unterminated comment");
            end = this.n;
        }
        const node = new XMLNode(XMLNode.COMMENT_NODE, "#comment");
        node.nodeValue = this.s.substring(this.i + 4, end);
        this.top().appendChild(node);
        this.i = mini(this.n, end + 3);
    }

    private readCDATA(): void {
        let end = this.s.indexOf("]]>", this.i + 9);
        if (end < 0) {
            this.error("unterminated CDATA section");
            end = this.n;
        }
        const node = new XMLNode(XMLNode.CDATA_SECTION_NODE, "#cdata-section");
        node.nodeValue = this.s.substring(this.i + 9, end);
        if (this.stack.length == 1) this.error("CDATA outside the root element");
        else this.top().appendChild(node);
        this.i = mini(this.n, end + 3);
    }

    private readProcessingInstruction(): void {
        let end = this.s.indexOf("?>", this.i + 2);
        if (end < 0) {
            this.error("unterminated processing instruction");
            end = this.n;
        }
        const body = this.s.substring(this.i + 2, end);
        this.i = mini(this.n, end + 2);
        let k = 0;
        while (k < body.length && !isSpace(body.charCodeAt(k))) k++;
        const target = body.substring(0, k);
        const data = body.substring(k).trim();
        if (target == "xml") {
            const attrs = parsePseudoAttributes(data);
            for (let a = 0; a < attrs.length; a++) {
                const at = attrs[a];
                if (at.name == "version") this.doc.xmlVersion = at.value;
                else if (at.name == "encoding") this.doc.xmlEncoding = at.value;
                else if (at.name == "standalone") this.doc.xmlStandalone = at.value == "yes";
            }
            return;
        }
        const node = new XMLNode(XMLNode.PROCESSING_INSTRUCTION_NODE, target);
        node.nodeValue = data;
        this.top().appendChild(node);
    }

    /// <!DOCTYPE name PUBLIC "pub" "sys" [ internal subset ]>
    private readDoctype(): void {
        const s = this.s;
        let k = this.i + 9;
        while (k < this.n && isSpace(s.charCodeAt(k))) k++;
        const nameStart = k;
        while (k < this.n && !isSpace(s.charCodeAt(k)) && s.charCodeAt(k) != 62 && s.charCodeAt(k) != 91) k++;
        const node = new XMLNode(XMLNode.DOCUMENT_TYPE_NODE, s.substring(nameStart, k));
        // External id.
        const ids: Array<string> = [];
        let keyword = "";
        while (k < this.n) {
            const c = s.charCodeAt(k);
            if (c == 62 || c == 91) break;
            if (c == 34 || c == 39) {
                let e = s.indexOf(String.fromCharCode(c), k + 1);
                if (e < 0) e = this.n;
                ids.push(s.substring(k + 1, e));
                k = e + 1;
            } else if (isSpace(c)) {
                k++;
            } else {
                const w = k;
                while (k < this.n && !isSpace(s.charCodeAt(k)) && s.charCodeAt(k) != 62 && s.charCodeAt(k) != 91
                    && s.charCodeAt(k) != 34 && s.charCodeAt(k) != 39) k++;
                keyword = s.substring(w, k).toUpperCase();
            }
        }
        if (keyword == "PUBLIC") {
            if (ids.length > 0) node.publicId = ids[0];
            if (ids.length > 1) node.systemId = ids[1];
        } else if (keyword == "SYSTEM" && ids.length > 0) {
            node.systemId = ids[0];
        }
        if (k < this.n && s.charCodeAt(k) == 91) {
            const subsetStart = k + 1;
            const subsetEnd = this.findSubsetEnd(subsetStart);
            node.internalSubset = s.substring(subsetStart, subsetEnd);
            this.readEntityDeclarations(node.internalSubset);
            k = subsetEnd + 1;
        }
        let close = s.indexOf(">", k);
        if (close < 0) {
            this.error("unterminated DOCTYPE");
            close = this.n;
        }
        this.i = mini(this.n, close + 1);
        this.doc.doctype = node;
        this.doc.appendChild(node);
    }

    /// The "]" closing an internal subset that starts at `from` (quotes and
    /// comments skipped).
    private findSubsetEnd(from: i32): i32 {
        const s = this.s;
        let k = from;
        while (k < this.n) {
            const c = s.charCodeAt(k);
            if (c == 93) return k;
            if (c == 34 || c == 39) {
                const e = s.indexOf(String.fromCharCode(c), k + 1);
                k = e < 0 ? this.n : e + 1;
            } else if (c == 60 && s.startsWith("<!--", k)) {
                const e = s.indexOf("-->", k + 4);
                k = e < 0 ? this.n : e + 3;
            } else {
                k++;
            }
        }
        this.error("unterminated DOCTYPE internal subset");
        return this.n;
    }

    /// <!ENTITY name "value"> declarations (parameter and external entities
    /// are skipped).
    private readEntityDeclarations(subset: string): void {
        let k = 0;
        while (true) {
            const at = subset.indexOf("<!ENTITY", k);
            if (at < 0) break;
            k = at + 8;
            while (k < subset.length && isSpace(subset.charCodeAt(k))) k++;
            if (k < subset.length && subset.charCodeAt(k) == 37) continue;  // %: a parameter entity
            const nameStart = k;
            while (k < subset.length && !isSpace(subset.charCodeAt(k))) k++;
            const name = subset.substring(nameStart, k);
            while (k < subset.length && isSpace(subset.charCodeAt(k))) k++;
            if (k >= subset.length) break;
            const q = subset.charCodeAt(k);
            if (q != 34 && q != 39) continue;  // SYSTEM / PUBLIC: external
            const e = subset.indexOf(String.fromCharCode(q), k + 1);
            if (e < 0) break;
            if (!this.doc.entities.has(name)) this.doc.entities.set(name, subset.substring(k + 1, e));
            k = e + 1;
        }
    }

    private readStartTag(): void {
        const s = this.s;
        let k = this.i + 1;
        const nameStart = k;
        while (k < this.n && isNameChar(s.charCodeAt(k))) k++;
        const element = new XMLNode(XMLNode.ELEMENT_NODE, s.substring(nameStart, k));
        let selfClosing = false;
        let closed = false;
        while (k < this.n) {
            const c = s.charCodeAt(k);
            if (isSpace(c)) {
                k++;
                continue;
            }
            if (c == 62) {
                k++;
                closed = true;
                break;
            }
            if (c == 47) {
                if (k + 1 < this.n && s.charCodeAt(k + 1) == 62) {
                    selfClosing = true;
                    closed = true;
                    k += 2;
                    break;
                }
                k++;
                continue;
            }
            if (c == 60) break;  // a new tag: this one was not closed
            // An attribute.
            const an = k;
            while (k < this.n && isNameChar(s.charCodeAt(k))) k++;
            if (k == an) {
                this.error("unexpected '" + String.fromCharCode(c) + "' in a tag");
                k++;
                continue;
            }
            const name = s.substring(an, k);
            while (k < this.n && isSpace(s.charCodeAt(k))) k++;
            let value = "";
            if (k < this.n && s.charCodeAt(k) == 61) {
                k++;
                while (k < this.n && isSpace(s.charCodeAt(k))) k++;
                const q = k < this.n ? s.charCodeAt(k) : 0;
                if (q == 34 || q == 39) {
                    let e = s.indexOf(String.fromCharCode(q), k + 1);
                    if (e < 0) {
                        this.error("unterminated attribute value");
                        e = this.n;
                    }
                    value = s.substring(k + 1, e);
                    k = mini(this.n, e + 1);
                } else {
                    // Unquoted (not XML; accepted).
                    const v = k;
                    while (k < this.n && !isSpace(s.charCodeAt(k)) && s.charCodeAt(k) != 62) k++;
                    value = s.substring(v, k);
                    this.error("unquoted attribute value");
                }
            } else {
                this.error("attribute '" + name + "' has no value");
            }
            if (element.hasAttribute(name)) this.error("duplicate attribute '" + name + "'");
            else element.attributes.push(new XMLAttribute(name, this.decode(value, true, 0)));
        }
        if (!closed) this.error("unterminated tag <" + element.nodeName + ">");
        this.i = k;
        if (this.stack.length == 1 && this.doc.documentElement != null) this.error("a second root element");
        this.top().appendChild(element);
        if (!selfClosing) this.stack.push(element);
    }

    private readEndTag(): void {
        const s = this.s;
        let close = s.indexOf(">", this.i + 2);
        if (close < 0) close = this.n;
        const name = s.substring(this.i + 2, close).trim();
        this.i = mini(this.n, close + 1);
        for (let k = this.stack.length - 1; k > 0; k--) {
            if (this.stack[k].nodeName == name) {
                if (k != this.stack.length - 1) this.error("</" + name + "> closes unclosed elements");
                this.stack.length = k;
                return;
            }
        }
        this.error("</" + name + "> closes no open element");
    }

    /// `raw` with entity and character references replaced; attribute
    /// values also turn tabs and line ends into spaces.
    private decode(raw: string, attribute: bool, depth: i32): string {
        let text = raw;
        if (attribute) {
            for (let k = 0; k < text.length; k++) {
                const c = text.charCodeAt(k);
                if (c == 9 || c == 10) {
                    text = text.replaceAll("\t", " ").replaceAll("\n", " ");
                    break;
                }
            }
        }
        if (text.indexOf("&") < 0) return text;
        let out = "";
        let k = 0;
        while (k < text.length) {
            const amp = text.indexOf("&", k);
            if (amp < 0) {
                out += text.substring(k);
                break;
            }
            out += text.substring(k, amp);
            const semi = text.indexOf(";", amp + 1);
            if (semi < 0 || semi - amp > 64) {
                if (depth == 0) this.error("a bare '&'");
                out += "&";
                k = amp + 1;
                continue;
            }
            const name = text.substring(amp + 1, semi);
            const replacement = this.entity(name, attribute, depth);
            if (replacement != null) {
                out += replacement!;
            } else {
                if (depth == 0) this.error("unknown entity &" + name + ";");
                out += text.substring(amp, semi + 1);
            }
            k = semi + 1;
        }
        return out;
    }

    private entity(name: string, attribute: bool, depth: i32): string? {
        if (name.length == 0) return null;
        if (name.charCodeAt(0) == 35) {
            let code: i32 = -1;
            if (name.length > 2 && (name.charCodeAt(1) == 120 || name.charCodeAt(1) == 88)) {
                code = parseHex(name.substring(2));
            } else if (name.length > 1) {
                code = parseDecimal(name.substring(1));
            }
            if (code < 0 || code > 0x10FFFF) return null;
            return String.fromCodePoint(code);
        }
        if (name == "lt") return "<";
        if (name == "gt") return ">";
        if (name == "amp") return "&";
        if (name == "quot") return "\"";
        if (name == "apos") return "'";
        const entities = this.doc.entities;
        if (!entities.has(name)) return null;
        // Declared entities may refer to others; stop runaway expansion.
        if (depth >= 8) return "";
        return this.decode(entities.get(name), attribute, depth + 1);
    }
}

function collectByTagName(node: XMLNode, name: string, out: Array<XMLNode>): void {
    for (let i = 0; i < node.childNodes.length; i++) {
        const c = node.childNodes[i];
        if (c.nodeType != XMLNode.ELEMENT_NODE) continue;
        if (name == "*" || c.nodeName == name) out.push(c);
        collectByTagName(c, name, out);
    }
}

/// version="1.0" encoding='utf-8' ...
function parsePseudoAttributes(text: string): Array<XMLAttribute> {
    const out: Array<XMLAttribute> = [];
    let k = 0;
    while (k < text.length) {
        while (k < text.length && isSpace(text.charCodeAt(k))) k++;
        const ns = k;
        while (k < text.length && text.charCodeAt(k) != 61 && !isSpace(text.charCodeAt(k))) k++;
        const name = text.substring(ns, k);
        while (k < text.length && (isSpace(text.charCodeAt(k)) || text.charCodeAt(k) == 61)) k++;
        if (k >= text.length) break;
        const q = text.charCodeAt(k);
        if (q != 34 && q != 39) break;
        let e = text.indexOf(String.fromCharCode(q), k + 1);
        if (e < 0) e = text.length;
        out.push(new XMLAttribute(name, text.substring(k + 1, e)));
        k = e + 1;
    }
    return out;
}

function isSpace(c: i32): bool { return c == 32 || c == 9 || c == 10 || c == 13; }

function isNameStart(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 58 || c >= 0xC0;
}

function isNameChar(c: i32): bool {
    return isNameStart(c) || (c >= 48 && c <= 57) || c == 45 || c == 46 || c == 0xB7;
}

function hexDigit(c: i32): i32 {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 102) return c - 87;
    if (c >= 65 && c <= 70) return c - 55;
    return -1;
}

function parseHex(s: string): i32 {
    if (s.length == 0 || s.length > 6) return -1;
    let v = 0;
    for (let k = 0; k < s.length; k++) {
        const d = hexDigit(s.charCodeAt(k));
        if (d < 0) return -1;
        v = v * 16 + d;
    }
    return v;
}

function parseDecimal(s: string): i32 {
    if (s.length == 0 || s.length > 7) return -1;
    let v = 0;
    for (let k = 0; k < s.length; k++) {
        const c = s.charCodeAt(k);
        if (c < 48 || c > 57) return -1;
        v = v * 10 + (c - 48);
    }
    return v;
}

// CSS helpers.

function isCSSNameChar(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 95;
}

function atRuleType(name: string): i32 {
    if (name == "import") return CSSRule.IMPORT_RULE;
    if (name == "media") return CSSRule.MEDIA_RULE;
    if (name == "font-face") return CSSRule.FONT_FACE_RULE;
    if (name == "page") return CSSRule.PAGE_RULE;
    if (name == "keyframes" || name.endsWith("-keyframes")) return CSSRule.KEYFRAMES_RULE;
    return 0;
}

/// `text` without /* comments */ (outside quotes).
function stripCSSComments(text: string): string {
    if (text.indexOf("/*") < 0) return text;
    let out = "";
    let k = 0;
    let quote = 0;
    let start = 0;
    while (k < text.length) {
        const c = text.charCodeAt(k);
        if (quote != 0) {
            if (c == 92) k++;
            else if (c == quote) quote = 0;
            k++;
            continue;
        }
        if (c == 34 || c == 39) {
            quote = c;
            k++;
            continue;
        }
        if (c == 47 && k + 1 < text.length && text.charCodeAt(k + 1) == 42) {
            out += text.substring(start, k);
            const e = text.indexOf("*/", k + 2);
            k = e < 0 ? text.length : e + 2;
            start = k;
            out += " ";
            continue;
        }
        k++;
    }
    return out + text.substring(start);
}

/// `text` split at `separator` where it is outside quotes and brackets.
function splitTopLevel(text: string, separator: i32): Array<string> {
    const out: Array<string> = [];
    let depth = 0;
    let quote = 0;
    let start = 0;
    for (let k = 0; k < text.length; k++) {
        const c = text.charCodeAt(k);
        if (quote != 0) {
            if (c == 92) k++;
            else if (c == quote) quote = 0;
            continue;
        }
        if (c == 34 || c == 39) quote = c;
        else if (c == 40 || c == 91) depth++;
        else if ((c == 41 || c == 93) && depth > 0) depth--;
        else if (c == separator && depth == 0) {
            out.push(text.substring(start, k));
            start = k + 1;
        }
    }
    out.push(text.substring(start));
    return out;
}

/// The index of `char` at or after `from`, outside quotes; -1 if none.
function findOutsideQuotes(text: string, from: i32, char: i32): i32 {
    let quote = 0;
    for (let k = from; k < text.length; k++) {
        const c = text.charCodeAt(k);
        if (quote != 0) {
            if (c == 92) k++;
            else if (c == quote) quote = 0;
            continue;
        }
        if (c == 34 || c == 39) quote = c;
        else if (c == char) return k;
    }
    return -1;
}

/// The "}" matching the "{" at `open` (nested blocks and quotes skipped),
/// or the text's length.
function findBlockEnd(text: string, open: i32): i32 {
    let depth = 0;
    let quote = 0;
    for (let k = open; k < text.length; k++) {
        const c = text.charCodeAt(k);
        if (quote != 0) {
            if (c == 92) k++;
            else if (c == quote) quote = 0;
            continue;
        }
        if (c == 34 || c == 39) quote = c;
        else if (c == 123) depth++;
        else if (c == 125) {
            depth--;
            if (depth == 0) return k;
        }
    }
    return text.length;
}

/// Past the end of an at-rule whose prelude starts at `from`: after its
/// ";" or its block.
function findAtRuleEnd(text: string, from: i32): i32 {
    let quote = 0;
    for (let k = from; k < text.length; k++) {
        const c = text.charCodeAt(k);
        if (quote != 0) {
            if (c == 92) k++;
            else if (c == quote) quote = 0;
            continue;
        }
        if (c == 34 || c == 39) quote = c;
        else if (c == 59) return k + 1;
        else if (c == 123) return mini(text.length, findBlockEnd(text, k) + 1);
    }
    return text.length;
}

function mini(a: i32, b: i32): i32 { return a < b ? a : b; }
