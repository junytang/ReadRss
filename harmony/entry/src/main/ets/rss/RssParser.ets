import { XmlNode, XmlParser } from './XmlParser';
import { Article } from '../model/Models';
import { normalizeFeedText } from '../model/FeedDisplay';

export interface ParsedFeed {
  title: string;
  siteUrl: string;
  description: string;
  articles: Article[];
}

/** Converts RSS 2.0 / Atom XML into the same Article shape used by the local DB. */
export class RssParser {
  parse(xml: string, feedId: string, fallbackTitle: string): ParsedFeed {
    const document: XmlNode = new XmlParser().parse(xml);
    const channel: XmlNode | undefined = XmlParser.firstDescendant(document, 'channel');
    if (channel) {
      return this.parseRss2(channel, feedId, fallbackTitle);
    }
    const atom: XmlNode | undefined = XmlParser.firstDescendant(document, 'feed');
    if (atom) {
      return this.parseAtom(atom, feedId, fallbackTitle);
    }
    throw new Error('Unsupported feed format (expected RSS 2.0 or Atom)');
  }

  private parseRss2(channel: XmlNode, feedId: string, fallbackTitle: string): ParsedFeed {
    const title: string = normalizeFeedText(
      XmlParser.text(XmlParser.child(channel, 'title')) || fallbackTitle
    );
    const siteUrl: string = XmlParser.text(XmlParser.child(channel, 'link'));
    const description: string = XmlParser.text(XmlParser.child(channel, 'description'));

    const articles: Article[] = [];
    const items: XmlNode[] = XmlParser.descendants(channel, 'item');
    for (const item of items) {
      const titleText: string = XmlParser.text(XmlParser.child(item, 'title')) || title;
      const link: string = XmlParser.text(XmlParser.child(item, 'link'));
      const guid: string =
        XmlParser.text(XmlParser.child(item, 'guid')) || link || titleText;
      const content: string = this.firstNonEmpty([
        XmlParser.text(XmlParser.child(item, 'encoded')),
        XmlParser.text(XmlParser.child(item, 'content')),
        XmlParser.text(XmlParser.child(item, 'description')),
      ]);
      const summary: string = this.firstNonEmpty([
        XmlParser.text(XmlParser.child(item, 'description')),
        XmlParser.text(XmlParser.child(item, 'summary')),
      ]);
      articles.push({
        id: `${feedId}|${guid}`,
        feedId: feedId,
        feedTitle: title,
        title: titleText,
        author: this.firstNonEmpty([
          XmlParser.text(XmlParser.child(item, 'creator')),
          XmlParser.text(XmlParser.child(item, 'author')),
        ]),
        link: link,
        summary: this.plainText(summary).substring(0, 280),
        content: content,
        imageUrl: this.findImage(item, content),
        publishedAt: Math.min(
          this.parseDate(
            this.firstNonEmpty([
              XmlParser.text(XmlParser.child(item, 'pubDate')),
              XmlParser.text(XmlParser.child(item, 'date')),
            ])
          ),
          Date.now()
        ),
        isRead: false,
        isStarred: false,
        fullContent: '',
      });
    }
    return { title: title, siteUrl: siteUrl, description: description, articles: articles };
  }

  private parseAtom(feed: XmlNode, feedId: string, fallbackTitle: string): ParsedFeed {
    const title: string = normalizeFeedText(
      XmlParser.text(XmlParser.child(feed, 'title')) || fallbackTitle
    );
    const siteUrl: string = XmlParser.attr(XmlParser.child(feed, 'link'), 'href');
    const description: string = XmlParser.text(XmlParser.child(feed, 'subtitle'));

    const articles: Article[] = [];
    const entries: XmlNode[] = XmlParser.descendants(feed, 'entry');
    for (const entry of entries) {
      const titleText: string = XmlParser.text(XmlParser.child(entry, 'title')) || title;
      const link: string = XmlParser.attr(XmlParser.child(entry, 'link'), 'href');
      const id: string = XmlParser.text(XmlParser.child(entry, 'id')) || link || titleText;
      const content: string = this.firstNonEmpty([
        XmlParser.text(XmlParser.child(entry, 'content')),
        XmlParser.text(XmlParser.child(entry, 'summary')),
      ]);
      articles.push({
        id: `${feedId}|${id}`,
        feedId: feedId,
        feedTitle: title,
        title: titleText,
        author: XmlParser.text(XmlParser.child(entry, 'name')),
        link: link,
        summary: this.plainText(XmlParser.text(XmlParser.child(entry, 'summary'))).substring(0, 280),
        content: content,
        imageUrl: this.findImage(entry, content),
        publishedAt: Math.min(
          this.parseDate(
            this.firstNonEmpty([
              XmlParser.text(XmlParser.child(entry, 'published')),
              XmlParser.text(XmlParser.child(entry, 'updated')),
            ])
          ),
          Date.now()
        ),
        isRead: false,
        isStarred: false,
        fullContent: '',
      });
    }
    return { title: title, siteUrl: siteUrl, description: description, articles: articles };
  }

  private plainText(html: string): string {
    const cleaned: string = html.replace(/<(script|style|noscript)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ');
    return XmlParser.decode(cleaned.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ')).trim();
  }

  private firstNonEmpty(values: string[]): string {
    for (const value of values) {
      if (value.length > 0) {
        return value;
      }
    }
    return '';
  }

  private parseDate(value: string): number {
    if (value.length === 0) {
      return Date.now();
    }
    const parsed: number = Date.parse(value);
    return Number.isNaN(parsed) ? Date.now() : parsed;
  }

  private findImage(item: XmlNode, content: string): string {
    const enclosure: string = XmlParser.attr(XmlParser.child(item, 'enclosure'), 'url');
    if (enclosure.length > 0 && enclosure.startsWith('http')) {
      return enclosure;
    }
    const thumbnail: string = XmlParser.attr(XmlParser.child(item, 'thumbnail'), 'url');
    if (thumbnail.length > 0 && thumbnail.startsWith('http')) {
      return thumbnail;
    }
    const mediaContent: string = XmlParser.attr(XmlParser.child(item, 'content'), 'url');
    if (mediaContent.length > 0 && mediaContent.startsWith('http')) {
      return mediaContent;
    }
    const match: Array<string> | null = content.match(/<img[^>]*\ssrc\s*=\s*['"]([^'"]+)['"]/i);
    const url: string = match && match.length > 1 ? match[1] : '';
    return url.startsWith('data:') ? '' : url;
  }
}
