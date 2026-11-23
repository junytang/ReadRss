import { describe, it, expect } from '@ohos/hypium';
import { ReaderFont } from '../main/ets/common/ReaderFont';
import { FeedIcon } from '../main/ets/common/FeedIcon';
import { HtmlBuilder } from '../main/ets/rss/HtmlBuilder';
import { FeverApi } from '../main/ets/rss/FeverApi';
import { Article, Feed, filterFeedsByDrawer, defaultSettings } from '../main/ets/model/Models';
import { RemoteCredentials, emptyCredentials } from '../main/ets/account/AccountModels';
import { FULL_CONTENT_VERSION_MARKER } from '../main/ets/rss/FullContentFetcher';
import { WebViewHtml } from '../main/ets/rss/WebViewHtml';
import { FILTER_UNREAD, FILTER_STARRED, FILTER_ALL } from '../main/ets/common/Constants';

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
  });
}
