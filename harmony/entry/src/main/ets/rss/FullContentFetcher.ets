import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { HtmlDom, HtmlNode } from './HtmlDom';

/** Bumped whenever the extraction algorithm changes so stale cached bodies are re-fetched. */
export const FULL_CONTENT_VERSION_MARKER: string = '<!--ry-extract-v16-->';

/**
 * Lightweight stand-in for Android's Readability4J-based article extraction.
 * Removes page chrome before returning the article body HTML.
 */
export class FullContentFetcher {
  static async fetch(url: string, title: string): Promise<string> {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return '';
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 10000,
        header: {
          'User-Agent': 'Mozilla/5.0 (compatible; ReadYou-Harmony/0.1)',
          'Accept': 'text/html,application/xhtml+xml',
        },
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return '';
      }
      const bytes: ArrayBuffer = response.result as ArrayBuffer;
      const charset: string = FullContentFetcher.detectCharset(response, bytes);
      const html: string = FullContentFetcher.decode(bytes, charset);
      return FullContentFetcher.clean(html, title);
    } catch (error) {
      Logger.error(`Full content fetch failed: ${(error as Error).message}`);
      return '';
    } finally {
      request.destroy();
    }
  }

  /** Detect charset from Content-Type header, then from the HTML <meta> tag. */
  private static detectCharset(response: http.HttpResponse, bytes: ArrayBuffer): string {
    // response.header is an object on older APIs and a Map on newer ones;
    // stringifying covers both without depending on either type.
    let charset: string = FullContentFetcher.charsetFrom(JSON.stringify(response.header));
    if (charset.length > 0) {
      return charset;
    }
    // Read the leading part of the document for <meta charset=...>. The charset
    // declaration itself is ASCII, so a UTF-8 decode is safe here.
    const headBytes: ArrayBuffer = bytes.byteLength > 2048
      ? bytes.slice(0, 2048) : bytes;
    let head: string = '';
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      head = decoder.decodeToString(new Uint8Array(headBytes));
    } catch (error) {
      head = '';
    }
    charset = FullContentFetcher.charsetFrom(head);
    return charset.length > 0 ? charset : 'utf-8';
  }

  private static charsetFrom(value: string): string {
    const match: Array<string> | null =
      value.match(/charset\s*=\s*["']?\s*([\w-]+)/i);
    if (match === null || match.length < 2) {
      return '';
    }
    return match[1].toLowerCase();
  }

  private static decode(bytes: ArrayBuffer, charset: string): string {
    // TextDecoder labels include 'gbk', 'gb2312', 'utf-8', etc.
    const label: string = charset.length > 0 ? charset : 'utf-8';
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create(label, { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(bytes));
    } catch (error) {
      Logger.warn(`Unsupported charset ${label}, falling back to utf-8`);
      const fallback: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return fallback.decodeToString(new Uint8Array(bytes));
    }
  }

  private static findBody(node: HtmlNode): HtmlNode | undefined {
    if (node.tag === 'body') return node;
    for (const child of node.children) {
      const found: HtmlNode | undefined = FullContentFetcher.findBody(child);
      if (found) return found;
    }
    return undefined;
  }

  /** Only the values of class/id matter for junk detection, not URLs/titles in other attributes. */
  private static classAndId(attrs: string): string {
    let result: string = '';
    const matcher: RegExp = /\b(?:class|id)\s*=\s*(["'])([^"']*)\1/gi;
    let match: Array<string> | null = matcher.exec(attrs);
    while (match) {
      result += ` ${match[2]}`;
      match = matcher.exec(attrs);
    }
    return result.toLowerCase();
  }

  private static stripChrome(node: HtmlNode): void {
    const chrome: string[] = [
      'script', 'style', 'noscript', 'nav', 'header', 'footer', 'aside',
      'form', 'iframe', 'svg', 'button',
    ];
    // Filter children by rebuilding the array (ArkTS-safe mutation).
    const kept: HtmlNode[] = [];
    for (const child of node.children) {
      if (chrome.indexOf(child.tag) >= 0) continue;
      const classId: string = FullContentFetcher.classAndId(child.attrs);
      if (classId.length > 0 &&
        /header|footer|nav|sidebar|rightbar|leftbar|menu|breadcrumb|related|recommend|comment|share|advert|ads|promo|toolbar|pagination|guide|notice|tools|actions|meta|copyright|pro-campaign|pro-unit|campaign|adsbygoogle/.test(classId)) {
        continue;
      }
      FullContentFetcher.stripChrome(child);
      kept.push(child);
    }
    node.children = kept;
    // Android removes an h1 whose text equals the article title (handled by caller via regex).
  }

  /** Replace script/style/noscript bodies with spaces, keeping indices stable. */
  private static maskScripts(html: string): string {
    let result: string = html;
    const tags: string[] = ['script', 'style', 'noscript'];
    for (const tag of tags) {
      let from: number = 0;
      for (;;) {
        const lower: string = result.toLowerCase();
        const start: number = lower.indexOf('<' + tag, from);
        if (start < 0) {
          break;
        }
        const end: number = lower.indexOf('</' + tag, start);
        if (end < 0) {
          break;
        }
        const closeEnd: number = result.indexOf('>', end);
        if (closeEnd < 0) {
          break;
        }
        const blank: string = ' '.repeat(closeEnd - start + 1);
        result = result.substring(0, start) + blank + result.substring(closeEnd + 1);
        from = start;
      }
    }
    return result;
  }

  private static clean(html: string, title: string): string {
    Logger.info(`Extract start: html=${html.length}`);
    let cleaned: string = html.replace(/<!--[\s\S]*?-->/g, '');
    // Blank out script/style/noscript blocks while preserving string length:
    // their JS/CSS often contains '<div>' style text that breaks both div
    // counting and the lenient DOM parser.
    cleaned = FullContentFetcher.maskScripts(cleaned);
    Logger.info(`Extract stage raw images=${(cleaned.match(/<img/gi) ?? []).length}`);
    const root: HtmlNode = HtmlDom.parse(cleaned);
    const body: HtmlNode | undefined = FullContentFetcher.findBody(root);
    if (!body) return '';
    FullContentFetcher.stripChrome(body);
    // Site-agnostic: score every block by text/paragraph density minus link
    // noise and chrome keywords, then descend to the innermost strong container.
    const found: HtmlNode | undefined = HtmlDom.bestContentNode(body);
    const article: HtmlNode = HtmlDom.drillToContent(found ?? body);
    const containersCount: number = found === undefined ? 0 : 1;
    let result: string = HtmlDom.toHtml(article);
    Logger.info(`Extract stage containers=${containersCount} images=${(result.match(/<img/gi) ?? []).length}`);
    if (title.length > 0) {
      const escaped: string = title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      result = result.replace(new RegExp(`<h1[^>]*>[\\s\\S]*?${escaped}[\\s\\S]*?<\\/h1>`, 'i'), '');
    }
    const finalHtml: string = result.trim();
    Logger.info(`Extract article: containers=${containersCount} length=${finalHtml.length} images=${(finalHtml.match(/<img/gi) ?? []).length}`);
    // Never cache an empty body, otherwise the version marker alone would
    // suppress future re-fetches forever.
    if (finalHtml.length === 0) {
      return '';
    }
    return FULL_CONTENT_VERSION_MARKER + finalHtml;
  }
}
