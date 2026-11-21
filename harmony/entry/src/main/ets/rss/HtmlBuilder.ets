import { Article } from '../model/Models';
import { WebViewStyle } from './WebViewStyle';
import { WebViewHtml } from './WebViewHtml';
import { FULL_CONTENT_VERSION_MARKER } from './FullContentFetcher';

/** Builds the reader HTML using the same template/CSS system as Android's WebViewHtml. */
export class HtmlBuilder {
  static build(article: Article, dark: boolean, fontSizeIndex: number): string {
    const sizes: number[] = [15, 17, 20, 23];
    const size: number = fontSizeIndex >= 0 && fontSizeIndex < sizes.length
      ? sizes[fontSizeIndex]
      : 17;

    // Android only renders the article body; title/time are native UI.
    // A fullContent that is only the version marker means extraction failed
    // (e.g. a JS-rendered site); fall back to the RSS content, which often has
    // the images and text the feed provided.
    let body: string = article.fullContent.replace(FULL_CONTENT_VERSION_MARKER, '');
    if (body.length === 0) {
      body = article.content;
    }
    if (body.length === 0) {
      body = HtmlBuilder.escape(article.summary).replace(/\n/g, '<br/>');
    }
    // IT之家等站点用占位 src + data-original 保存真实图片地址。
    // 必须替换现有 src 的值，而不是追加第二个 src 属性（否则 WebView 取占位图）。
    body = HtmlBuilder.normalizeImages(body);
    body = HtmlBuilder.removeAspectRatioPadding(body);
    body = HtmlBuilder.collapseEmptyBreaks(body);
    body = body.replace(/(["'])(\/\/[^"']+)\1/g, '$1https:$2$1');

    const fontFamily: string = '"HarmonyOS Sans SC", "Noto Sans CJK SC", sans-serif';
    const style: string = WebViewStyle.get(dark, size, fontFamily);
    const baseHref: string = article.link.length > 0
      ? HtmlBuilder.escape(article.link)
      : '';
    return WebViewHtml.fill(style, baseHref, body);
  }

  private static attribute(tag: string, name: string): string {
    const match: Array<string> | null = tag.match(
      new RegExp('\\s' + name + '\\s*=\\s*(["\'])([^"\']*)\\1', 'i')
    );
    return match && match.length > 2 ? match[2] : '';
  }

  private static normalizeImages(html: string): string {
    return html.replace(/<img\b[^>]*>/gi, (tag: string) => {
      const real: string = HtmlBuilder.attribute(tag, 'data-original') ||
        HtmlBuilder.attribute(tag, 'data-src') ||
        HtmlBuilder.attribute(tag, 'data-lazy-src');
      if (real.length === 0) {
        return tag;
      }
      let normalized: string = tag;
      if (/\ssrc\s*=\s*(["'])[^"']*\1/i.test(normalized)) {
        normalized = normalized.replace(/(\ssrc\s*=\s*)(["'])[^"']*\2/i, `$1$2${real}$2`);
      } else {
        normalized = normalized.replace(/^<img/, `<img src="${real}"`);
      }
      // Strip non-standard / lazy-load attributes that can confuse the WebView.
      normalized = normalized.replace(/\s(?:w|h|data-[\w-]+|srcset)\s*=\s*(["'])[^"']*\1/gi, '');
      return normalized;
    });
  }

  /**
   * Image wrappers use the "padding-top: X%" aspect-ratio trick, which needs
   * CSS (absolute positioning) the reader WebView doesn't apply. The padding
   * then renders as a huge empty gap above each image. Percentage padding is
   * only used for this trick, so strip it globally from inline styles.
   */
  private static removeAspectRatioPadding(html: string): string {
    return html.replace(/padding-top\s*:\s*[\d.]+%\s*;?/gi, '');
  }

  /**
   * Some feeds use <p ...><br></p> as a blank line. In ArkWeb the paragraph's
   * default margins plus the <br> render as roughly four lines of whitespace.
   * Collapse those empty paragraphs to a single <br/> so a blank line is one line.
   */
  private static collapseEmptyBreaks(html: string): string {
    // Avoid \\b assertions: on some ArkTS engines they do not match as in JS.
    const patterns: RegExp[] = [
      /<p[^>]*>\s*<br[^>]*>\s*(?:<\/br>)?\s*<\/p>/gi,
      /<p[^>]*>\s*(?:&nbsp;)+\s*<\/p>/gi,
      /<p[^>]*>\s*<\/p>/gi,
    ];
    let result: string = html;
    for (const pattern of patterns) {
      // Remove the empty paragraph entirely: adjacent paragraph margins then
      // collapse to a single ~one-line gap. Replacing it with <br/> would add
      // another full line on top of those margins (~2-3 lines of whitespace).
      result = result.replace(pattern, '');
    }
    return result;
  }

  static escape(value: string): string {
    return value
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
}
