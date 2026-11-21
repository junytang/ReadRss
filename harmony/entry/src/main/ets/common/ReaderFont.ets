import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from './Logger';

/** Serves the installed custom font to ArkWeb through onInterceptRequest.
 *
 *  ArkUI's getFont().registerFont only affects native Text, and a data: URI in
 *  @font-face is not decoded by this ArkWeb build. Keeping the font bytes in
 *  memory under a same-origin virtual URL lets the WebView load it like any
 *  normal font resource, with no CORS or local-file restrictions.
 */
export class ReaderFont {
  private static readonly MARKER: string = '/__ry_font__/';
  private static bytes: ArrayBuffer | undefined = undefined;
  private static cachedPath: string = '';

  static isVirtualUrl(url: string): boolean {
    return url.includes(ReaderFont.MARKER);
  }

  /** Read the font once per path; reopening an article reuses cached bytes. */
  static load(path: string): ArrayBuffer | undefined {
    if (path.length === 0) {
      return undefined;
    }
    if (ReaderFont.bytes !== undefined && ReaderFont.cachedPath === path) {
      return ReaderFont.bytes;
    }
    try {
      const stat: fs.Stat = fs.statSync(path);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const bytes: ArrayBuffer = new ArrayBuffer(stat.size);
      try {
        fs.readSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      ReaderFont.bytes = bytes;
      ReaderFont.cachedPath = path;
      return bytes;
    } catch (error) {
      Logger.warn(`ReaderFont load failed: ${(error as Error).message}`);
      return undefined;
    }
  }

  static invalidate(): void {
    ReaderFont.bytes = undefined;
    ReaderFont.cachedPath = '';
  }

  static getBytes(): ArrayBuffer | undefined {
    return ReaderFont.bytes;
  }

  /** Build a virtual font URL on the article's own origin to avoid CORS. */
  static virtualUrl(articleLink: string): string {
    const matched: RegExpMatchArray | null = articleLink.match(/^(https?:\/\/[^\/]+)/);
    const origin: string = matched ? matched[1] : 'https://static3cdn.appinn.com';
    return `${origin}${ReaderFont.MARKER}custom.ttf`;
  }
}
