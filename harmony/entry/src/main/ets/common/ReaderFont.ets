import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from './Logger';

/** Serves the installed custom font to ArkWeb through onInterceptRequest.
 *
 *  ArkUI's getFont().registerFont only affects native Text, and a data: URI in
 *  @font-face is not decoded by this ArkWeb build. The font bytes are exposed
 *  through one fixed virtual URL intercepted by onInterceptRequest, with CORS
 *  and cache headers so the WebView loads it as a normal cached font resource.
 *
 *  No long-lived byte cache: a 22MB TTF kept in a static ArrayBuffer would
 *  permanently duplicate the copy ArkWeb keeps in its renderer. The file is
 *  read only when the WebView actually requests it, then released as soon as
 *  the response callback returns.
 */
export class ReaderFont {
  private static readonly MARKER: string = '/__ry_font__/';
  private static readonly VIRTUAL_URL: string =
    'https://static3cdn.appinn.com/__ry_font__/custom.ttf';

  static isVirtualUrl(url: string): boolean {
    return url.includes(ReaderFont.MARKER);
  }

  /** Existence check that does not load the (possibly 22MB) file. */
  static exists(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      return fs.statSync(path).size > 0;
    } catch (error) {
      return false;
    }
  }

  /** Read on demand. The caller hands the buffer to WebResourceResponse and
   *  drops its reference; we never retain a second copy in memory. */
  static load(path: string): ArrayBuffer | undefined {
    if (path.length === 0) {
      return undefined;
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
      return bytes;
    } catch (error) {
      Logger.warn(`ReaderFont load failed: ${(error as Error).message}`);
      return undefined;
    }
  }

  /** One URL for every article and every site, so ArkWeb caches a single copy.
   *  The mtime suffix changes when a new font is installed, which busts that
   *  cache without needing a second in-memory buffer. */
  static virtualUrl(path: string): string {
    let version: string = '0';
    if (path.length > 0) {
      try {
        version = fs.statSync(path).mtime.toString();
      } catch (error) {
        // Fall back to the unversioned URL.
      }
    }
    return `${ReaderFont.VIRTUAL_URL}?v=${version}`;
  }
}
