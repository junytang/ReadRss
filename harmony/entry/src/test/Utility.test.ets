import { describe, it, expect } from '@ohos/hypium';
import { ReaderFont } from '../main/ets/common/ReaderFont';
import { FeedIcon } from '../main/ets/common/FeedIcon';
import { HtmlBuilder } from '../main/ets/rss/HtmlBuilder';
import { FeverApi } from '../main/ets/rss/FeverApi';
import { Article, Feed, filterFeedsByDrawer, defaultSettings } from '../main/ets/model/Models';
import { RemoteCredentials, emptyCredentials } from '../main/ets/account/AccountModels';
import { FULL_CONTENT_VERSION_MARKER } from '../main/ets/rss/FullContentFetcher';
import { WebViewHtml } from '../main/ets/rss/WebViewHtml';
import { WebViewStyle } from '../main/ets/rss/WebViewStyle';
import {
  FILTER_UNREAD, FILTER_STARRED, FILTER_ALL,
  READ_ALIGN_START, READ_ALIGN_END, READ_ALIGN_CENTER, READ_ALIGN_JUSTIFY,
  readerAlignCss, readerAlignLabel,
} from '../main/ets/common/Constants';

function makeArticle(o: Partial<Article>): Article {
  const a: Article = {
    id: o.id ?? 'a1', feedId: o.feedId ?? 'f1', feedTitle: o.feedTitle ?? 'Feed',
    title: o.title ?? 'Title', author: o.author ?? 'Author',
    link: o.link ?? 'https://example.com/a', summary: o.summary ?? 'Summary',
    content: o.content ?? 'Content', fullContent: o.fullContent ?? '',
    imageUrl: o.imageUrl ?? '', publishedAt: o.publishedAt ?? 1000,
    isRead: o.isRead ?? false, isStarred: o.isStarred ?? false,
  };
  return a;
}

function makeFeed(id: string, unread: number, starred: number): Feed {
  return {
    id: id, title: id, url: '', groupId: '', iconUrl: '', sortOrder: 0,
    unreadCount: unread, starredCount: starred,
  };
}

export default function utilityTest(): void {
  describe('ReaderFont', () => {
    it('detects virtual font URL', 0, () => {
      expect(ReaderFont.isVirtualUrl('https://x/__ry_font__/custom.ttf?v=1')).assertTrue();
      expect(ReaderFont.isVirtualUrl('https://example.com/font.ttf')).assertFalse();
    });

    it('virtualUrl has version param; empty path uses v=0', 0, () => {
      const url: string = ReaderFont.virtualUrl('');
      expect(url.indexOf('/__ry_font__/') >= 0).assertTrue();
      expect(url.indexOf('?v=0') >= 0).assertTrue();
    });

    it('exists returns false for empty path', 0, () => {
      expect(ReaderFont.exists('')).assertFalse();
    });
  });

  describe('FeedIcon', () => {
    it('empty url returns empty', 0, () => {
      expect(FeedIcon.src('')).assertEqual('');
    });

    it('data url passes through', 0, () => {
      expect(FeedIcon.src('data:image/png;base64,AAA')).assertEqual('data:image/png;base64,AAA');
    });

    it('base64 favicon gets data prefix', 0, () => {
      expect(FeedIcon.src('iVBORw0KGgo=')).assertEqual('data:image/png;base64,iVBORw0KGgo=');
    });
  });

  describe('HtmlBuilder.escape', () => {
    it('escapes all HTML special chars', 0, () => {
      expect(HtmlBuilder.escape(`<a href="x">& 'y'</a>`))
        .assertEqual('&lt;a href=&quot;x&quot;&gt;&amp; &#39;y&#39;&lt;/a&gt;');
    });

    it('empty string stays empty', 0, () => {
      expect(HtmlBuilder.escape('')).assertEqual('');
    });
  });

  describe('HtmlBuilder.build', () => {
    it('falls back to content when fullContent empty', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: 'BODY_CONTENT' }), false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('BODY_CONTENT') >= 0).assertTrue();
    });

    it('strips version marker from full content', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ fullContent: `${FULL_CONTENT_VERSION_MARKER}FULL_TEXT` }),
        false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('FULL_TEXT') >= 0).assertTrue();
      expect(html.indexOf(FULL_CONTENT_VERSION_MARKER) >= 0).assertFalse();
    });

    it('escapes title and renders h1', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ title: '<b>Title</b>', summary: 'S' }), false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('&lt;b&gt;Title&lt;/b&gt;') >= 0).assertTrue();
      expect(html.indexOf('article-title') >= 0).assertTrue();
    });

    it('escapes summary fallback and converts newlines', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: '', summary: 'line1\nline2' }), false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('line1<br/>line2') >= 0).assertTrue();
    });

    it('normalizes protocol-relative image URLs', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: '<img src="//cdn.example.com/a.jpg"/>' }),
        false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('https://cdn.example.com/a.jpg') >= 0).assertTrue();
    });

    it('replaces placeholder src with data-original (lazy images)', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: '<img src="placeholder.gif" data-original="https://real.com/big.jpg"/>' }),
        false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('https://real.com/big.jpg') >= 0).assertTrue();
      expect(html.indexOf('placeholder.gif') >= 0).assertFalse();
      // The <img> tag itself must have src replaced (the reader script still
      // mentions data-original, so check the img tag specifically).
      expect(html.indexOf('src="https://real.com/big.jpg"') >= 0).assertTrue();
    });

    it('strips percentage padding used for aspect-ratio hacks', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: '<div style="padding-top: 56.25%;">x</div>' }),
        false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('56.25%') >= 0).assertFalse();
    });

    it('collapses empty paragraphs', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: '<p>keep</p><p></p><p><br/></p>' }),
        false, 16, 16, 1.5, 'sans-serif'
      );
      expect(html.indexOf('keep') >= 0).assertTrue();
      // Empty <p></p> and <p><br/></p> should be removed.
      expect(html.indexOf('<p></p>') >= 0).assertFalse();
    });
  });

  describe('Reader typography settings', () => {
    it('alignment values map to CSS and UI labels', 0, () => {
      expect(readerAlignCss(READ_ALIGN_START)).assertEqual('start');
      expect(readerAlignCss(READ_ALIGN_END)).assertEqual('end');
      expect(readerAlignCss(READ_ALIGN_CENTER)).assertEqual('center');
      expect(readerAlignCss(READ_ALIGN_JUSTIFY)).assertEqual('justify');
      expect(readerAlignLabel(READ_ALIGN_JUSTIFY)).assertEqual('两端对齐');
      // Unknown values fall back to the default rather than emitting bad CSS.
      expect(readerAlignCss(99)).assertEqual('start');
    });

    it('WebViewStyle uses letter spacing and alignment arguments', 0, () => {
      const css: string = WebViewStyle.get(false, 17, 'sans-serif', 16, 1.75, 1.2, 3);
      expect(css.indexOf('--letter-spacing: 1.2px;') >= 0).assertTrue();
      expect(css.indexOf('--text-align: justify;') >= 0).assertTrue();
      const defaults: string = WebViewStyle.get(false, 17, 'sans-serif', 16, 1.75);
      expect(defaults.indexOf('--letter-spacing: 0.5px;') >= 0).assertTrue();
      expect(defaults.indexOf('--text-align: start;') >= 0).assertTrue();
      expect(defaults.indexOf('--letter-spacing: 0px;') >= 0).assertFalse();
    });

    it('HtmlBuilder passes typography through to the generated CSS', 0, () => {
      const html: string = HtmlBuilder.build(
        makeArticle({ content: 'BODY' }), false, 16, 16, 1.5,
        'sans-serif', 2, READ_ALIGN_CENTER
      );
      expect(html.indexOf('--letter-spacing: 2px;') >= 0).assertTrue();
      expect(html.indexOf('--text-align: center;') >= 0).assertTrue();
    });

    it('settings preview is rendered by the same HtmlBuilder pipeline', 0, () => {
      const preview: string = HtmlBuilder.buildPreview(
        false, 17, 16, 1.75, 'sans-serif', 1.2, READ_ALIGN_JUSTIFY
      );
      expect(preview.indexOf('--letter-spacing: 1.2px;') >= 0).assertTrue();
      expect(preview.indexOf('--text-align: justify;') >= 0).assertTrue();
      expect(preview.indexOf('article-title') >= 0).assertTrue();
      expect(preview.indexOf('一级标题示例') >= 0).assertTrue();
      expect(preview.indexOf('二级标题示例') >= 0).assertTrue();
      expect(preview.indexOf('三级标题示例') >= 0).assertTrue();
    });

    it('CSS variables are exposed for in-place preview updates', 0, () => {
      const vars: Map<string, string> = WebViewStyle.variables(
        false, 18, 'serif', 20, 2, 1.3, READ_ALIGN_END
      );
      expect(vars.get('--font-size') ?? '').assertEqual('18px');
      expect(vars.get('--text-margin') ?? '').assertEqual('20px');
      expect(vars.get('--letter-spacing') ?? '').assertEqual('1.3px');
      expect(vars.get('--text-align') ?? '').assertEqual('end');
      expect(vars.get('--line-height') ?? '').assertEqual('2');
      expect(vars.get('--table-row-even-bg') ?? '').assertEqual('#F8F9FA');
    });

    it('applyVariables rewrites styles in place without reloading the document', 0, () => {
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('--font-size', '20px');
      vars.set('--font-family', '"serif", "HarmonyOS Sans SC", sans-serif');
      const script: string = WebViewHtml.applyVariables(vars);
      expect(script.indexOf('document.documentElement.style') >= 0).assertTrue();
      expect(script.indexOf('setProperty') >= 0).assertTrue();
      expect(script.indexOf('--font-size') >= 0).assertTrue();
      expect(script.indexOf('loadData') >= 0).assertFalse();
    });

    it('article title is larger than in-article headings and has top spacing', 0, () => {
      const css: string = WebViewStyle.get(false, 17, 'sans-serif', 16, 1.75);
      expect(css.indexOf('font-size: calc(var(--font-size) * 1.35) !important;') >= 0).assertTrue();
      expect(css.indexOf('h1 { font-size: calc(var(--font-size) * 1.2) !important; }') >= 0).assertTrue();
      expect(css.indexOf('h2 { font-size: calc(var(--font-size) * 1.12) !important; }') >= 0).assertTrue();
      expect(css.indexOf('h3 { font-size: calc(var(--font-size) * 1.05) !important; }') >= 0).assertTrue();
      expect(css.indexOf('margin-top: 0.8em !important;') >= 0).assertTrue();
    });
  });

  describe('FeverApi.decodeHtml', () => {
    it('decodes entities in plain text', 0, () => {
      expect(FeverApi.decodeHtml('<p>A &amp; B</p>')).assertEqual('A & B');
    });

    it('empty / undefined returns empty', 0, () => {
      expect(FeverApi.decodeHtml(undefined)).assertEqual('');
      expect(FeverApi.decodeHtml('')).assertEqual('');
    });
  });

  describe('Models helpers', () => {
    it('filterFeedsByDrawer filters unread and starred', 0, () => {
      const feeds: Feed[] = [makeFeed('a', 3, 0), makeFeed('b', 0, 2), makeFeed('c', 0, 0)];
      expect(filterFeedsByDrawer(feeds, FILTER_UNREAD).length).assertEqual(1);
      expect(filterFeedsByDrawer(feeds, FILTER_STARRED).length).assertEqual(1);
      expect(filterFeedsByDrawer(feeds, FILTER_ALL).length).assertEqual(3);
    });

    it('defaultSettings has expected defaults', 0, () => {
      const s = defaultSettings();
      expect(s.markReadOnScroll).assertFalse();
      expect(s.fetchBatchSize).assertEqual(100);
      expect(s.readingTextLetterSpacing).assertEqual(0.5);
      expect(s.readingTextAlign).assertEqual(READ_ALIGN_START);
    });
  });

  describe('RemoteCredentials', () => {
    it('emptyCredentials has blank fields', 0, () => {
      const c: RemoteCredentials = emptyCredentials();
      expect(c.serverUrl).assertEqual('');
      expect(c.username).assertEqual('');
      expect(c.password).assertEqual('');
      expect(c.clientCertificateAlias).assertEqual('');
    });
  });

  describe('WebViewHtml.fill', () => {
    it('replaces all 4 placeholders with style/base/body/script', 0, () => {
      const html: string = WebViewHtml.fill('CSS_HERE', 'https://base.com/', 'BODY_HERE');
      expect(html.indexOf('CSS_HERE') >= 0).assertTrue();
      expect(html.indexOf('BODY_HERE') >= 0).assertTrue();
      expect(html.indexOf('https://base.com/') >= 0).assertTrue();
      // Script placeholder replaced (SCRIPT contains the reader init script).
      expect(html.indexOf('<base href=') >= 0).assertTrue();
      expect(html.indexOf('%s') >= 0).assertFalse();
    });

    it('body script keeps MutationObserver and font-ready logic', 0, () => {
      expect(WebViewHtml.SCRIPT.indexOf('MutationObserver') >= 0).assertTrue();
      expect(WebViewHtml.SCRIPT.indexOf('document.fonts.ready') >= 0).assertTrue();
      expect(WebViewHtml.SCRIPT.indexOf('readYouBridge') >= 0).assertTrue();
    });

    it('body script wires image taps to the native zoom viewer', 0, () => {
      expect(WebViewHtml.SCRIPT.indexOf('onImageClick') >= 0).assertTrue();
      expect(WebViewHtml.SCRIPT.indexOf('data-ry-zoom') >= 0).assertTrue();
      // Linked images must keep their link behaviour instead of zooming.
      expect(WebViewHtml.SCRIPT.indexOf('closest("a")') >= 0).assertTrue();
    });
  });
}
