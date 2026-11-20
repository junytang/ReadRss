/**
 * Minimal pull-style XML parser for ArkTS.
 *
 * Android uses ROME + Jsoup for feed parsing; neither is available on
 * HarmonyOS, so this tokeniser handles the subset RSS 2.0 / Atom feeds need:
 * tags, attributes, CDATA, comments, processing instructions and entities.
 */

export interface XmlNode {
  name: string;
  attributes: Map<string, string>;
  children: XmlNode[];
  text: string;
}

export class XmlParser {
  private src: string = '';
  private pos: number = 0;
  private root: XmlNode = XmlParser.node('#document');
  private stack: XmlNode[] = [];

  static node(name: string, attributes?: Map<string, string>): XmlNode {
    return {
      name: name,
      attributes: attributes ?? new Map<string, string>(),
      children: [],
      text: '',
    };
  }

  parse(source: string): XmlNode {
    this.src = source;
    this.pos = 0;
    this.root = XmlParser.node('#document');
    this.stack = [this.root];

    while (this.pos < this.src.length) {
      const lt: number = this.src.indexOf('<', this.pos);
      if (lt < 0) {
        this.appendText(this.src.substring(this.pos));
        this.pos = this.src.length;
        break;
      }
      if (lt > this.pos) {
        this.appendText(this.src.substring(this.pos, lt));
      }
      this.pos = lt;

      if (this.src.startsWith('<!--', this.pos)) {
        this.skipTo('-->');
        continue;
      }
      if (this.src.startsWith('<?', this.pos)) {
        this.skipTo('?>');
        continue;
      }
      if (this.src.startsWith('<![CDATA[', this.pos)) {
        const start: number = this.pos + 9;
        const end: number = this.src.indexOf(']]>', start);
        const content: string =
          end < 0 ? this.src.substring(start) : this.src.substring(start, end);
        this.current().text += content;
        this.pos = end < 0 ? this.src.length : end + 3;
        continue;
      }
      if (this.src.startsWith('<!', this.pos)) {
        this.skipTo('>');
        continue;
      }

      const gt: number = this.findTagEnd(this.pos);
      if (gt < 0) {
        this.pos = this.src.length;
        break;
      }
      const raw: string = this.src.substring(this.pos + 1, gt).trim();
      this.pos = gt + 1;

      if (raw.startsWith('/')) {
        if (this.stack.length > 1) {
          this.stack.pop();
        }
        continue;
      }

      const selfClosing: boolean = raw.endsWith('/');
      const body: string = selfClosing ? raw.substring(0, raw.length - 1).trim() : raw;
      const spaceIdx: number = this.firstSpace(body);
      const name: string = spaceIdx < 0 ? body : body.substring(0, spaceIdx);
      const attributes: Map<string, string> =
        spaceIdx < 0 ? new Map<string, string>() : this.parseAttributes(body.substring(spaceIdx));
      const node: XmlNode = XmlParser.node(name, attributes);
      this.current().children.push(node);
      if (!selfClosing) {
        this.stack.push(node);
      }
    }
    return this.root;
  }

  private current(): XmlNode {
    return this.stack[this.stack.length - 1];
  }

  private firstSpace(value: string): number {
    for (let i = 0; i < value.length; i++) {
      const c: string = value.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        return i;
      }
    }
    return -1;
  }

  private skipTo(marker: string): void {
    const index: number = this.src.indexOf(marker, this.pos);
    this.pos = index < 0 ? this.src.length : index + marker.length;
  }

  private findTagEnd(start: number): number {
    let quote: string = '';
    for (let i = start + 1; i < this.src.length; i++) {
      const c: string = this.src.charAt(i);
      if (quote.length > 0) {
        if (c === quote) {
          quote = '';
        }
      } else if (c === '"' || c === "'") {
        quote = c;
      } else if (c === '>') {
        return i;
      }
    }
    return -1;
  }

  private parseAttributes(raw: string): Map<string, string> {
    const attrs: Map<string, string> = new Map<string, string>();
    let i: number = 0;
    while (i < raw.length) {
      while (i < raw.length && this.isSpace(raw.charAt(i))) {
        i++;
      }
      const nameStart: number = i;
      while (i < raw.length && !this.isSpace(raw.charAt(i)) && raw.charAt(i) !== '=') {
        i++;
      }
      if (i === nameStart) {
        i++;
        continue;
      }
      const name: string = raw.substring(nameStart, i);
      while (i < raw.length && this.isSpace(raw.charAt(i))) {
        i++;
      }
      if (raw.charAt(i) !== '=') {
        continue;
      }
      i++;
      while (i < raw.length && this.isSpace(raw.charAt(i))) {
        i++;
      }
      if (i >= raw.length) {
        break;
      }
      const quote: string = raw.charAt(i);
      if (quote !== '"' && quote !== "'") {
        break;
      }
      i++;
      const valueStart: number = i;
      while (i < raw.length && raw.charAt(i) !== quote) {
        i++;
      }
      attrs.set(name, XmlParser.decode(raw.substring(valueStart, i)));
      i++;
    }
    return attrs;
  }

  private isSpace(c: string): boolean {
    return c === ' ' || c === '\t' || c === '\n' || c === '\r';
  }

  private appendText(text: string): void {
    if (text.length === 0) {
      return;
    }
    this.current().text += XmlParser.decode(text);
  }

  static decode(value: string | undefined): string {
    if (!value) {
      return '';
    }
    let out: string = value;
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&quot;/g, '"');
    out = out.replace(/&apos;/g, "'");
    out = out.replace(/&nbsp;/g, ' ');
    out = out.replace(/&mdash;/g, '—');
    out = out.replace(/&ndash;/g, '–');
    out = out.replace(/&hellip;/g, '…');
    out = out.replace(/&copy;/g, '©');
    out = out.replace(/&reg;/g, '®');
    out = out.replace(/&trade;/g, '™');
    out = out.replace(/&rsquo;/g, '’');
    out = out.replace(/&lsquo;/g, '‘');
    out = out.replace(/&ldquo;/g, '“');
    out = out.replace(/&rdquo;/g, '”');
    out = out.replace(/&#x([0-9a-fA-F]+);/g,
      (match: string, hex: string) => String.fromCharCode(parseInt(hex, 16)));
    out = out.replace(/&#(\d+);/g,
      (match: string, dec: string) => String.fromCharCode(parseInt(dec, 10)));
    out = out.replace(/&amp;/g, '&');
    return out;
  }

  // --------------------------- traversal helpers ---------------------------

  static localName(name: string): string {
    const idx: number = name.lastIndexOf(':');
    return idx < 0 ? name : name.substring(idx + 1);
  }

  static child(node: XmlNode, name: string): XmlNode | undefined {
    for (const item of node.children) {
      if (XmlParser.localName(item.name) === name) {
        return item;
      }
    }
    return undefined;
  }

  static descendants(node: XmlNode, name: string): XmlNode[] {
    const found: XmlNode[] = [];
    for (const item of node.children) {
      if (XmlParser.localName(item.name) === name) {
        found.push(item);
      }
      found.push(...XmlParser.descendants(item, name));
    }
    return found;
  }

  static firstDescendant(node: XmlNode, name: string): XmlNode | undefined {
    for (const item of node.children) {
      if (XmlParser.localName(item.name) === name) {
        return item;
      }
      const nested: XmlNode | undefined = XmlParser.firstDescendant(item, name);
      if (nested) {
        return nested;
      }
    }
    return undefined;
  }

  static text(node: XmlNode | undefined): string {
    return node ? node.text.trim() : '';
  }

  static attr(node: XmlNode | undefined, name: string): string {
    if (!node) {
      return '';
    }
    const direct: string | undefined = node.attributes.get(name);
    if (direct !== undefined) {
      return direct;
    }
    let found: string = '';
    node.attributes.forEach((value: string, key: string) => {
      if (found.length === 0 && XmlParser.localName(key) === name) {
        found = value;
      }
    });
    return found;
  }
}
