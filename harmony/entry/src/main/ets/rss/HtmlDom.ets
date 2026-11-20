/** Minimal HTML DOM used for Readability-like article extraction. */
export interface HtmlNode {
  tag: string;
  attrs: string;
  children: HtmlNode[];
  text: string;
}

/** Signals used by the generic content-scoring algorithm. */
interface ContentStats {
  text: number;
  linkText: number;
  paragraphs: number;
  images: number;
}

/** Lenient HTML parser: enough structure for article-body extraction. */
export class HtmlDom {
  static parse(html: string): HtmlNode {
    const root: HtmlNode = HtmlDom.node('#document');
    const stack: HtmlNode[] = [root];
    let i: number = 0;
    // figure is a container (it wraps images/captions), NOT a void tag.
    const voidTags: string[] = ['br', 'hr', 'img', 'input', 'meta', 'link', 'source', 'wbr'];
    while (i < html.length) {
      if (html.startsWith('<!--', i)) {
        const end: number = html.indexOf('-->', i + 4);
        i = end < 0 ? html.length : end + 3;
        continue;
      }
      if (html.charAt(i) !== '<') {
        const next: number = html.indexOf('<', i);
        const raw: string = next < 0 ? html.substring(i) : html.substring(i, next);
        const text: string = raw.replace(/\s+/g, ' ').trim();
        if (text.length > 0) {
          stack[stack.length - 1].text += text;
        }
        i = next < 0 ? html.length : next;
        continue;
      }
      const gt: number = html.indexOf('>', i + 1);
      if (gt < 0) {
        break;
      }
      let rawTag: string = html.substring(i + 1, gt).trim();
      i = gt + 1;
      if (rawTag.startsWith('/')) {
        // Pop up to the matching open tag instead of blindly popping one level.
        // Lenient HTML often has skipped or stray closing tags; a blind pop can
        // prematurely close an ancestor such as the article container.
        const closeTag: string = rawTag.substring(1).trim().toLowerCase();
        for (let s: number = stack.length - 1; s > 0; s--) {
          if (stack[s].tag === closeTag) {
            stack.length = s;
            break;
          }
        }
        continue;
      }
      if (rawTag.startsWith('!') || rawTag.startsWith('?')) continue;
      const selfClosing: boolean = rawTag.endsWith('/');
      if (selfClosing) rawTag = rawTag.substring(0, rawTag.length - 1).trim();
      const space: number = HtmlDom.firstSpace(rawTag);
      const tag: string = (space < 0 ? rawTag : rawTag.substring(0, space)).toLowerCase();
      const attrs: string = space < 0 ? '' : rawTag.substring(space);
      const node: HtmlNode = HtmlDom.node(tag, attrs);
      stack[stack.length - 1].children.push(node);
      if (!selfClosing && voidTags.indexOf(tag) < 0) stack.push(node);
    }
    return root;
  }

  private static node(tag: string, attrs: string = ''): HtmlNode {
    return { tag: tag, attrs: attrs, children: [], text: '' };
  }

  private static firstSpace(value: string): number {
    for (let i = 0; i < value.length; i++) {
      const c: string = value.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') return i;
    }
    return -1;
  }

  /** Total text length of a node including descendants. */
  static textLength(node: HtmlNode): number {
    let total: number = node.text.length;
    for (const child of node.children) {
      total += HtmlDom.textLength(child);
    }
    return total;
  }

  /** Count images inside a node (including descendants). */
  static imageCount(node: HtmlNode): number {
    let count: number = node.tag === 'img' ? 1 : 0;
    for (const child of node.children) {
      count += HtmlDom.imageCount(child);
    }
    return count;
  }

  /** Android-style CMS content hints, supporting both "-" and "_" separators. */
  private static isContentNode(node: HtmlNode): boolean {
    if (node.tag === 'article') return true;
    const hints: string = node.attrs.toLowerCase();
    return /entry[-_]content|post[-_]content|post[-_]single[-_]content|article[-_]content|content[-_]body|rich_media_content|articlebody|post[-_]body|main[-_]content|post[-_]text|p[-_]mainnew/.test(hints);
  }

  /**
   * Collect ALL content containers at the first level that has any, because
   * article bodies are often split into several sibling divs/p nodes.
   */
  static findContentContainers(node: HtmlNode): HtmlNode[] {
    const matched: HtmlNode[] = [];
    for (const child of node.children) {
      if (HtmlDom.isContentNode(child) && HtmlDom.textLength(child) > 120) {
        matched.push(child);
      }
    }
    if (matched.length > 0) return matched;
    for (const child of node.children) {
      const found: HtmlNode[] = HtmlDom.findContentContainers(child);
      if (found.length > 0) return found;
    }
    return [];
  }

  /**
   * Fallback Readability-like heuristic: keep the child with the most text and
   * discard siblings, but stop once the node holds multiple images so a photo
   * sequence is preserved.
   */
  static selectArticle(root: HtmlNode): HtmlNode {
    let current: HtmlNode = root;
    for (;;) {
      if (current.tag === 'article' || HtmlDom.imageCount(current) >= 2) break;
      let best: HtmlNode | undefined = undefined;
      let bestLength: number = 0;
      for (const child of current.children) {
        const length: number = HtmlDom.textLength(child);
        if (length > bestLength) {
          bestLength = length;
          best = child;
        }
      }
      if (!best || bestLength < 200) break;
      current = best;
    }
    return current;
  }

  /** Accumulate the signals used by the generic content-scoring algorithm. */
  private static stats(node: HtmlNode): ContentStats {
    let text: number = node.text.length;
    let linkText: number = 0;
    let paragraphs: number = 0;
    let images: number = 0;
    if (node.tag === 'a') {
      linkText = HtmlDom.textLength(node);
    }
    if (node.tag === 'p') {
      paragraphs = 1;
    }
    if (node.tag === 'img') {
      images = 1;
    }
    for (const child of node.children) {
      const childStats: ContentStats = HtmlDom.stats(child);
      text += childStats.text;
      linkText += childStats.linkText;
      paragraphs += childStats.paragraphs;
      images += childStats.images;
    }
    return { text: text, linkText: linkText, paragraphs: paragraphs, images: images };
  }

  private static classAndId(node: HtmlNode): string {
    let result: string = '';
    const matcher: RegExp = /\b(?:class|id)\s*=\s*(["'])([^"']*)\1/gi;
    let match: Array<string> | null = matcher.exec(node.attrs);
    while (match !== null) {
      result += ` ${match[2]}`;
      match = matcher.exec(node.attrs);
    }
    return result.toLowerCase();
  }

  /** Readability-like score: dense text and paragraphs win, link-heavy chrome loses. */
  private static contentScore(node: HtmlNode): number {
    const stats: ContentStats = HtmlDom.stats(node);
    const chrome: string = HtmlDom.classAndId(node);
    let penalty: number =
      /header|footer|nav|sidebar|rightbar|leftbar|menu|comment|share|related|recommend|advert|promo|pagination|breadcrumb|toolbar|login|copyright|meta|notice|guide|ads|tools|pro-campaign|pro-unit|campaign|adsbygoogle/.test(chrome)
        ? 200 : 0;
    // Navigation/footer bars are link-heavy with no paragraphs. Article bodies
    // almost always contain <p> elements, so penalise the opposite pattern.
    const linkRatio: number = stats.text > 0 ? stats.linkText / stats.text : 0;
    if (stats.paragraphs === 0 && linkRatio > 0.2) {
      penalty += 200;
    }
    return stats.text - stats.linkText * 2 + stats.paragraphs * 30 + stats.images * 10 - penalty;
  }

  private static isBlock(node: HtmlNode): boolean {
    return node.tag === 'div' || node.tag === 'article' ||
      node.tag === 'section' || node.tag === 'main';
  }

  /** Pick the block container with the strongest article signal. */
  static bestContentNode(root: HtmlNode): HtmlNode | undefined {
    let best: HtmlNode | undefined = undefined;
    let bestScore: number = -1e18;
    const stack: HtmlNode[] = [root];
    while (stack.length > 0) {
      const node: HtmlNode = stack.pop() as HtmlNode;
      if (HtmlDom.isBlock(node)) {
        const stats: ContentStats = HtmlDom.stats(node);
        // One-character posts ("？") and image-only posts are valid articles;
        // let text OR images into the candidate set and let scoring decide.
        if (stats.text >= 1 || stats.images >= 1) {
          const score: number = HtmlDom.contentScore(node);
          if (score > bestScore) {
            bestScore = score;
            best = node;
          }
        }
      }
      for (const child of node.children) {
        stack.push(child);
      }
    }
    return best;
  }

  /** Walk inward while a child keeps most of the parent's score. */
  static drillToContent(node: HtmlNode): HtmlNode {
    let current: HtmlNode = node;
    let currentScore: number = HtmlDom.contentScore(current);
    for (;;) {
      let bestChild: HtmlNode | undefined = undefined;
      let bestScore: number = -1e18;
      for (const child of current.children) {
        const childStats: ContentStats = HtmlDom.stats(child);
        if (!HtmlDom.isBlock(child) ||
            (childStats.text < 1 && childStats.images < 1)) {
          continue;
        }
        const score: number = HtmlDom.contentScore(child);
        if (score > bestScore) {
          bestScore = score;
          bestChild = child;
        }
      }
      if (bestChild === undefined || bestScore < currentScore * 0.7) {
        break;
      }
      current = bestChild;
      currentScore = bestScore;
    }
    return current;
  }

  /** Wrap sibling nodes into a document node for serialization. */
  static wrap(nodes: HtmlNode[]): HtmlNode {
    const root: HtmlNode = HtmlDom.node('#document');
    root.children = nodes;
    return root;
  }

  static toHtml(node: HtmlNode): string {
    if (node.tag === '#document') {
      let out: string = node.text;
      for (const child of node.children) out += HtmlDom.toHtml(child);
      return out;
    }
    let out: string = `<${node.tag}${node.attrs}>` + node.text;
    for (const child of node.children) out += HtmlDom.toHtml(child);
    out += `</${node.tag}>`;
    return out;
  }
}
