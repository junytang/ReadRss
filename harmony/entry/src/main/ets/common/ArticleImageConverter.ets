import { http } from '@kit.NetworkKit';
import { Logger } from './Logger';
import { md5Hex } from './Md5';

interface AvifPending {
  tag: string;
  url: string;
}

/**
 * Makes AVIF images displayable: neither the device ImageSource decoder nor its
 * ArkWeb build can decode AVIF. Each image is fetched through a public proxy as
 * JPEG and kept in memory under a fake https URL; ReadingView's
 * onInterceptRequest serves those bytes, so the WebView loads them through the
 * normal https image path (data:/blob:/file: are rejected by this ArkWeb).
 */
export class ArticleImageConverter {
  private static readonly PROXY: string = 'https://images.weserv.nl/?url=';
  // A path marker on a resolvable host. onInterceptRequest matches this exact
  // prefix; the host itself resolves so the request reaches the interceptor.
  private static readonly VIRTUAL: string = 'https://static3cdn.appinn.com/__ry_avif__/';
  // Cap cached JPEG bytes: a reader can open hundreds of articles, and each
  // converted image is tens of KB. Without a bound this map grows unbounded.
  private static readonly MAX_CACHED_IMAGES: number = 200;
  /** Also cap total bytes so a few very large JPEGs cannot dominate memory. */
  private static readonly MAX_CACHED_BYTES: number = 32 * 1024 * 1024;
  private static readonly bytes: Map<string, ArrayBuffer> = new Map();
  private static cachedBytes: number = 0;

  static getBytes(key: string): ArrayBuffer | undefined {
    const map: Map<string, ArrayBuffer> = ArticleImageConverter.bytes;
    const bytes: ArrayBuffer | undefined = map.get(key);
    if (bytes !== undefined && map.size > 1) {
      // Touch to keep frequently viewed images near the end (LRU).
      map.delete(key);
      map.set(key, bytes);
    }
    return bytes;
  }

  /** Insert with simple LRU eviction: delete + re-set moves the key to the end. */
  private static putBytes(key: string, bytes: ArrayBuffer): void {
    const map: Map<string, ArrayBuffer> = ArticleImageConverter.bytes;
    if (map.has(key)) {
      map.delete(key);
    }
    map.set(key, bytes);
    ArticleImageConverter.cachedBytes += bytes.byteLength;
    while (map.size > ArticleImageConverter.MAX_CACHED_IMAGES
      || ArticleImageConverter.cachedBytes > ArticleImageConverter.MAX_CACHED_BYTES) {
      const oldest: string | undefined = map.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      const old: ArrayBuffer | undefined = map.get(oldest);
      if (old !== undefined) {
        ArticleImageConverter.cachedBytes -= old.byteLength;
      }
      map.delete(oldest);
    }
  }

  static isVirtualUrl(url: string): boolean {
    return url.includes('/__ry_avif__/');
  }

  static keyFromUrl(url: string): string {
    const index: number = url.indexOf('/__ry_avif__/');
    return url.substring(index + '/__ry_avif__/'.length);
  }

  static async convertAvif(html: string): Promise<string> {
    if (html.length === 0 || html.toLowerCase().indexOf('.avif') < 0) {
      return html;
    }
    // One scan to collect AVIF tags, bounded-concurrency conversion, then one
    // replacement pass. The old split/await loop copied the whole article once
    // per tag and fetched images serially.
    const pending: AvifPending[] = [];
    const tags: Array<string> = html.match(/<img\b[^>]*>/gi) ?? [];
    for (const tag of tags) {
      const srcMatch: Array<string> | null = tag.match(/\bsrc\s*=\s*(["'])([^"']+)\1/i);
      if (srcMatch !== null && srcMatch.length >= 3 && /\.avif(\?|$)/i.test(srcMatch[2])) {
        pending.push({ tag: tag, url: srcMatch[2] });
      }
    }
    if (pending.length === 0) {
      return html;
    }
    const converted: Map<string, string> = new Map<string, string>();
    let next: number = 0;
    const worker = async (): Promise<void> => {
      while (next < pending.length) {
        const item: AvifPending = pending[next++];
        converted.set(item.tag, await ArticleImageConverter.convertTag(item.tag, item.url));
      }
    };
    const workers: Promise<void>[] = [];
    for (let i: number = 0; i < Math.min(3, pending.length); i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    return html.replace(/<img\b[^>]*>/gi, (tag: string): string => converted.get(tag) ?? tag);
  }

  private static async convertTag(tag: string, url: string): Promise<string> {
    const key: string = ArticleImageConverter.hash(url) + '.jpg';
    // Reuse already converted bytes: re-rendering the same article (font size /
    // dark mode change) used to hit the proxy again for every AVIF image.
    if (ArticleImageConverter.getBytes(key) === undefined) {
      try {
        const proxyUrl: string = ArticleImageConverter.PROXY + encodeURIComponent(url) +
          '&output=jpeg&w=800&q=80';
        const bytes: ArrayBuffer | undefined = await ArticleImageConverter.fetchBytes(proxyUrl);
        if (bytes === undefined) {
          return tag;
        }
        ArticleImageConverter.putBytes(key, bytes);
      } catch (error) {
        Logger.error(`AVIF convert failed: ${(error as Error).message}`);
        return tag;
      }
    }
    // Strip srcset/sizes so the browser uses src (our virtual URL) instead of
    // the original .avif candidates.
    let clean: string = tag.replace(/\ssrcset\s*=\s*(["'])[^"']*\1/gi, '')
      .replace(/\ssizes\s*=\s*(["'])[^"']*\1/gi, '');
    clean = clean.replace(/\bsrc\s*=\s*(["'])[^"']+\1/i,
      `src="${ArticleImageConverter.VIRTUAL}${key}"`);
    return clean;
  }

  private static async fetchBytes(url: string): Promise<ArrayBuffer | undefined> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return undefined;
      }
      return response.result as ArrayBuffer;
    } catch (error) {
      Logger.error(`AVIF proxy fetch failed: ${(error as Error).message}`);
      return undefined;
    } finally {
      request.destroy();
    }
  }

  private static hash(value: string): string {
    // A 32-bit hash collides on long URL lists and would serve the wrong image.
    return md5Hex(value).substring(0, 24);
  }
}
