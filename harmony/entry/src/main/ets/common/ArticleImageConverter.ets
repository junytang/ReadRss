import { http } from '@kit.NetworkKit';
import { Logger } from './Logger';

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
  private static readonly MAX_CACHED_IMAGES: number = 20;
  private static readonly bytes: Map<string, ArrayBuffer> = new Map();

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
    while (map.size > ArticleImageConverter.MAX_CACHED_IMAGES) {
      const oldest: string | undefined = map.keys().next().value;
      if (oldest === undefined) {
        break;
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
    const parts: Array<string> = html.split(/(<img\b[^>]*>)/gi);
    let result: string = '';
    for (const part of parts) {
      if (!/^<img\b/i.test(part)) {
        result += part;
        continue;
      }
      const srcMatch: Array<string> | null = part.match(/\bsrc\s*=\s*(["'])([^"']+)\1/i);
      if (srcMatch === null || srcMatch.length < 3 || !/\.avif(\?|$)/i.test(srcMatch[2])) {
        result += part;
        continue;
      }
      result += await ArticleImageConverter.convertTag(part, srcMatch[2]);
    }
    return result;
  }

  private static async convertTag(tag: string, url: string): Promise<string> {
    try {
      const proxyUrl: string = ArticleImageConverter.PROXY + encodeURIComponent(url) +
        '&output=jpeg&w=800&q=80';
      const bytes: ArrayBuffer | undefined = await ArticleImageConverter.fetchBytes(proxyUrl);
      if (bytes === undefined) {
        return tag;
      }
      const key: string = ArticleImageConverter.hash(url) + '.jpg';
      ArticleImageConverter.putBytes(key, bytes);
      // Strip srcset/sizes so the browser uses src (our virtual URL) instead of
      // the original .avif candidates.
      let clean: string = tag.replace(/\ssrcset\s*=\s*(["'])[^"']*\1/gi, '')
        .replace(/\ssizes\s*=\s*(["'])[^"']*\1/gi, '');
      clean = clean.replace(/\bsrc\s*=\s*(["'])[^"']+\1/i,
        `src="${ArticleImageConverter.VIRTUAL}${key}"`);
      return clean;
    } catch (error) {
      Logger.error(`AVIF convert failed: ${(error as Error).message}`);
      return tag;
    }
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
    let h: number = 5381;
    for (let i: number = 0; i < value.length; i++) {
      h = ((h << 5) + h + value.charCodeAt(i)) | 0;
    }
    return (h >>> 0).toString(36);
  }
}
