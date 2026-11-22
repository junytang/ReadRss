import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { CredentialCodec } from '../account/AccountModels';
import { Logger } from './Logger';

/** Two-level (memory + sandbox file) cache for remote feed icons. */
class FeedIconCacheImpl {
  private memory: Map<string, string> = new Map<string, string>();
  private inFlight: Set<string> = new Set<string>();
  private tickTimer: number = -1;

  /** Coalesce icon-ready notifications: publishing one tick per icon made the
   *  article list rebuild its whole ForEach once per downloaded favicon. */
  private publishTick(): void {
    if (this.tickTimer >= 0) {
      return;
    }
    this.tickTimer = setTimeout(() => {
      this.tickTimer = -1;
      AppStorage.set<number>('feedIconTick', Date.now());
    }, 300);
  }

  private directory(context: common.Context): string {
    return `${context.filesDir}/feed_icons`;
  }

  private fileName(url: string): string {
    return `${CredentialCodec.md5Hex(url)}.png`;
  }

  /** Local path already known in memory (synchronous, safe to call from build()). */
  cachedPath(url: string): string {
    return this.memory.get(url) ?? '';
  }

  /** Ensure the icon is downloaded once; subsequent calls return the cached path. */
  async ensure(context: common.Context, url: string): Promise<string> {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return '';
    }
    const known: string = this.memory.get(url) ?? '';
    if (known.length > 0) {
      return known;
    }
    if (this.inFlight.has(url)) {
      return '';
    }
    this.inFlight.add(url);
    try {
      const dir: string = this.directory(context);
      try {
        fs.mkdirSync(dir, true);
      } catch (error) {
        // Directory already exists.
      }
      const path: string = `${dir}/${this.fileName(url)}`;
      try {
        if (fs.statSync(path).size > 0) {
          this.memory.set(url, path);
          return path;
        }
      } catch (error) {
        // File does not exist yet.
      }

      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 10000,
          readTimeout: 10000,
          header: { 'User-Agent': 'Mozilla/5.0 ReadYou-Harmony' },
        });
        if (response.responseCode !== 200) {
          return '';
        }
        const data: ArrayBuffer = response.result as ArrayBuffer;
        if (data.byteLength === 0) {
          return '';
        }
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        try {
          fs.truncateSync(file.fd, 0);
          fs.writeSync(file.fd, data);
        } finally {
          fs.closeSync(file);
        }
        this.memory.set(url, path);
        this.publishTick();
        return path;
      } finally {
        request.destroy();
      }
    } catch (error) {
      Logger.error(`Feed icon download failed: ${(error as Error).message} url=${url}`);
      return '';
    } finally {
      this.inFlight.delete(url);
    }
  }
}

export const feedIconCache: FeedIconCacheImpl = new FeedIconCacheImpl();
