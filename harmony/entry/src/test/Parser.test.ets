import { describe, it, expect } from '@ohos/hypium';
import { XmlParser, XmlNode } from '../main/ets/rss/XmlParser';
import { RssParser, ParsedFeed } from '../main/ets/rss/RssParser';
import { HtmlDom, HtmlNode } from '../main/ets/rss/HtmlDom';
import { WebViewStyle } from '../main/ets/rss/WebViewStyle';

const RSS2: string = `<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>测试源</title>
  <item>
    <title>第一篇文章</title>
    <link>https://example.com/1</link>
    <guid>https://example.com/1</guid>
    <description>摘要内容</description>
    <pubDate>Mon, 23 Nov 2026 12:00:00 GMT</pubDate>
  </item>
  <item>
    <title>第二篇文章</title>
    <link>https://example.com/2</link>
    <guid>https://example.com/2</guid>
    <description>摘要二</description>
  </item>
</channel></rss>`;

const ATOM: string = `<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom 源</title>
  <entry>
    <title>Atom 文章</title>
    <id>urn:atom:1</id>
    <link href="https://example.com/atom/1"/>
    <summary>atom 摘要</summary>
    <updated>2026-11-23T10:00:00Z</updated>
  </entry>
</feed>`;

export default function parserTest(): void {
  describe('XmlParser', () => {
    it('parses nested elements and text', 0, () => {
      const doc: XmlNode = new XmlParser().parse('<rss><channel><title>Hello</title></channel></rss>');
      const channel: XmlNode | undefined = XmlParser.firstDescendant(doc, 'channel');
      expect(channel === undefined).assertFalse();
      expect(XmlParser.text(XmlParser.child(channel!, 'title'))).assertEqual('Hello');
    });

    it('decodes XML entities', 0, () => {
      expect(XmlParser.decode('a &amp; b &lt;tag&gt; &quot;q&quot; &#39;s&#39;')).assertEqual("a & b <tag> \"q\" 's'");
    });

    it('decodes numeric entities beyond the BMP without throwing', 0, () => {
      // fromCodePoint, not fromCharCode: emoji numeric references must survive.
      expect(XmlParser.decode('hi &#128512;')).assertEqual('hi 😀');
      expect(XmlParser.decode('hi &#x1F600;')).assertEqual('hi 😀');
    });

    it('leaves malformed numeric entities untouched instead of throwing', 0, () => {
      expect(XmlParser.decode('a &#x110000; b')).assertEqual('a &#x110000; b');
      expect(XmlParser.decode('a &#xD800; b')).assertEqual('a &#xD800; b');
      expect(XmlParser.decode('a &#99999999; b')).assertEqual('a &#99999999; b');
    });

    it('does not double-decode nested amp entities', 0, () => {
      expect(XmlParser.decode('&amp;lt;')).assertEqual('&lt;');
    });

    it('reads attributes', 0, () => {
      const doc: XmlNode = new XmlParser().parse('<root><link href="https://a.com" rel="alternate"/></root>');
      const link: XmlNode | undefined = XmlParser.firstDescendant(doc, 'link');
      expect(XmlParser.attr(link, 'href')).assertEqual('https://a.com');
    });
  });

  describe('RssParser', () => {
    it('parses RSS 2.0 feed', 0, () => {
      const feed: ParsedFeed = new RssParser().parse(RSS2, 'feed-1', 'fallback');
      expect(feed.title).assertEqual('测试源');
      expect(feed.articles.length).assertEqual(2);
      expect(feed.articles[0].title).assertEqual('第一篇文章');
      expect(feed.articles[0].link).assertEqual('https://example.com/1');
      expect(feed.articles[0].id).assertEqual('feed-1|https://example.com/1');
    });

    it('parses Atom feed', 0, () => {
      const feed: ParsedFeed = new RssParser().parse(ATOM, 'feed-2', 'fallback');
      expect(feed.title).assertEqual('Atom 源');
      expect(feed.articles.length).assertEqual(1);
      expect(feed.articles[0].title).assertEqual('Atom 文章');
    });

    it('throws on unsupported format', 0, () => {
      let threw: boolean = false;
      try {
        new RssParser().parse('<html><body>nope</body></html>', 'f', 'x');
      } catch (error) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('uses fallback title when channel title missing', 0, () => {
      const feed: ParsedFeed = new RssParser().parse(
        '<rss><channel><item><title>T</title></item></channel></rss>', 'f', '默认标题');
      expect(feed.title).assertEqual('默认标题');
    });
  });

  describe('HtmlDom', () => {
    it('extracts text length', 0, () => {
      const root: HtmlNode = HtmlDom.parse('<article><p>Hello</p><p>World</p></article>');
      const len: number = HtmlDom.textLength(root);
      expect(len >= 10).assertTrue();
    });

    it('counts images', 0, () => {
      const root: HtmlNode = HtmlDom.parse('<article><p>x</p><img src="a"/><img src="b"/></article>');
      expect(HtmlDom.imageCount(root)).assertEqual(2);
    });

    it('survives pathologically deep nesting without stack overflow', 0, () => {
      let html: string = '<article>';
      for (let i: number = 0; i < 400; i++) {
        html += '<div>';
      }
      html += 'deep';
      for (let i: number = 0; i < 400; i++) {
        html += '</div>';
      }
      html += '</article>';
      const root: HtmlNode = HtmlDom.parse(html);
      // Depth guards must stop recursion instead of throwing / overflowing.
      expect(HtmlDom.textLength(root) >= 0).assertTrue();
      expect(HtmlDom.toHtml(root).length >= 0).assertTrue();
    });

    it('parses attributes and nested structure', 0, () => {
      const root: HtmlNode = HtmlDom.parse('<div class="wrap"><p id="p1">text</p></div>');
      expect(root.children.length).assertEqual(1);
      expect(root.children[0].tag).assertEqual('div');
      expect(root.children[0].attrs.indexOf('class') >= 0).assertTrue();
      expect(root.children[0].children[0].tag).assertEqual('p');
      expect(root.children[0].children[0].attrs.indexOf('id') >= 0).assertTrue();
      // Text is stored as a #text child node.
      expect(root.children[0].children[0].children[0].tag).assertEqual('#text');
      expect(root.children[0].children[0].children[0].text).assertEqual('text');
    });

    it('toHtml produces well-formed markup', 0, () => {
      const root: HtmlNode = HtmlDom.parse('<p>Hello <b>World</b></p>');
      const html: string = HtmlDom.toHtml(root);
      expect(html.indexOf('<p>') >= 0).assertTrue();
      expect(html.indexOf('<b>') >= 0).assertTrue();
      expect(html.indexOf('Hello') >= 0).assertTrue();
    });

    it('bestContentNode picks the largest text block', 0, () => {
      const root: HtmlNode = HtmlDom.parse(
        '<html><body><nav>short</nav><article>' + 'x'.repeat(200) + '</article></body></html>'
      );
      const best: HtmlNode | undefined = HtmlDom.bestContentNode(root);
      expect(best === undefined).assertFalse();
      expect(best!.tag).assertEqual('article');
    });
  });

  describe('WebViewStyle', () => {
    it('reflects font size and dark mode in CSS', 0, () => {
      const light: string = WebViewStyle.get(false, 16, 'sans-serif', 16, 1.5);
      const dark: string = WebViewStyle.get(true, 20, 'serif', 24, 2);
      expect(light.indexOf('--font-size: 16px') >= 0).assertTrue();
      expect(dark.indexOf('--font-size: 20px') >= 0).assertTrue();
      expect(light.indexOf('#191C1E') >= 0).assertTrue();
      expect(dark.indexOf('#E8EAED') >= 0).assertTrue();
    });
  });
}
