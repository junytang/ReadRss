import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { rssRepository } from './RssRepository';
import { pendingStatusRegistry } from './PendingStatusRegistry';
import { StatusDiffs, ReadDiff, StarDiff, ReadIdPartition, StarIdPartition } from './StatusDiffs';
import { Article } from '../model/Models';
import { Logger } from '../common/Logger';

/**
 * Local-first read/star status holder (ArkTS port of Android's DiffMapHolder).
 *
 * The pure state machine lives in StatusDiffs (unit-testable, no side effects).
 * This class adds the platform concerns: persistence, AppStorage ticks, debounced
 * batching, retry backoff and the actual DB/server commits.
 */
class ReadStatusStore {
  private static readonly DEBOUNCE_MS: number = 5000;
  private static readonly MAX_ATTEMPTS: number = 5;
  private static readonly RETRY_BASE_MS: number = 5000;
  private static readonly RETRY_MAX_MS: number = 60000;
  private static readonly CACHE_WRITE_MS: number = 500;

  private diffs: StatusDiffs = new StatusDiffs();
  private timer: number = -1;
  private cacheTimer: number = -1;
  private flushing: boolean = false;
  private cacheDirty: boolean = false;
  private context: common.Context | undefined = undefined;

  init(context: common.Context): void {
    this.context = context;
    this.loadFromCache();
    // Restored diffs from a previous crash still need to be pushed.
    if (this.diffs.readCount() > 0 || this.diffs.starCount() > 0) {
      this.schedule();
    }
  }

  // ------------------------------ persistence -----------------------------

  private cachePath(): string {
    return `${this.context!.cacheDir}/read_status_diffs.txt`;
  }

  private loadFromCache(): void {
    if (this.context === undefined) {
      return;
    }
    try {
      const path: string = this.cachePath();
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(path);
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
        const text: string = buffer.from(buf).toString('utf8');
        for (const line of text.split('\n')) {
          if (line.length === 0) {
            continue;
          }
          const parts: string[] = line.split('|');
          if (parts[0] === 'r' && parts.length >= 5) {
            this.diffs.setReadDiff(parts[1], {
              unread: parts[2] === '1', feedId: parts[3], groupId: parts[4],
            });
            pendingStatusRegistry.add(parts[1]);
          } else if (parts[0] === 's' && parts.length >= 3) {
            this.diffs.setStarDiff(parts[1], {
              starred: parts[2] === '1', feedId: parts.length >= 4 ? parts[3] : '',
            });
            pendingStatusRegistry.add(parts[1]);
          }
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      // No cache yet — normal on first launch.
    }
  }

  /** Mark the cache dirty; the write is coalesced to one per flush/batch. */
  private markCacheDirty(): void {
    this.cacheDirty = true;
    if (this.cacheTimer < 0) {
      this.cacheTimer = setTimeout((): void => {
        this.cacheTimer = -1;
        this.flushCache();
      }, ReadStatusStore.CACHE_WRITE_MS);
    }
  }

  flushCache(): void {
    if (this.cacheTimer >= 0) {
      clearTimeout(this.cacheTimer);
      this.cacheTimer = -1;
    }
    if (!this.cacheDirty || this.context === undefined) {
      return;
    }
    this.cacheDirty = false;
    try {
      const lines: string[] = [];
      this.diffs.forEachRead((d: ReadDiff, id: string): void => {
        lines.push(`r|${id}|${d.unread ? '1' : '0'}|${d.feedId}|${d.groupId}`);
      });
      this.diffs.forEachStar((s: StarDiff, id: string): void => {
        lines.push(`s|${id}|${s.starred ? '1' : '0'}|${s.feedId}`);
      });
      const file = fs.openSync(this.cachePath(), fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        fs.truncateSync(file.fd, 0);
        fs.writeSync(file.fd, lines.join('\n'));
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Logger.warn(`Failed to persist status diffs: ${(error as Error).message}`);
    }
  }

  // --------------------------- state derivation --------------------------

  effectiveUnread(articleId: string, dbUnread: boolean): boolean {
    return this.diffs.effectiveUnread(articleId, dbUnread);
  }

  effectiveStarred(articleId: string, dbStarred: boolean): boolean {
    return this.diffs.effectiveStarred(articleId, dbStarred);
  }

  applyTo(articles: Article[]): void {
    for (const article of articles) {
      article.isRead = !this.effectiveUnread(article.id, !article.isRead);
      article.isStarred = this.effectiveStarred(article.id, article.isStarred);
    }
  }

  hasPending(articleId: string): boolean {
    return this.diffs.hasRead(articleId) || this.diffs.hasStar(articleId);
  }

  clearConfirmed(articleId: string): void {
    this.clear(articleId);
  }

  unreadDelta(feedId: string, groupId: string, global: boolean): number {
    return this.diffs.unreadDelta(feedId, groupId, global);
  }

  starredDelta(feedId: string): number {
    return this.diffs.starredDelta(feedId);
  }

  // -------------------------------- marking ------------------------------

  markRead(articleId: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string): void {
    if (this.diffs.markRead(articleId, unread, currentUnread, feedId, groupId)) {
      pendingStatusRegistry.add(articleId);
    }
    this.publish();
    this.schedule();
  }

  markReadLocal(articleId: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string): void {
    if (this.diffs.markRead(articleId, unread, currentUnread, feedId, groupId)) {
      pendingStatusRegistry.add(articleId);
    }
    this.publish();
  }

  markStarred(articleId: string, starred: boolean, currentStarred: boolean, feedId: string): void {
    if (this.diffs.markStarred(articleId, starred, currentStarred, feedId)) {
      pendingStatusRegistry.add(articleId);
    }
    this.publish();
    this.schedule();
  }

  private publish(): void {
    this.markCacheDirty();
    AppStorage.setOrCreate<number>('readStatusTick', Date.now());
    AppStorage.setOrCreate<number>('bannerTick', Date.now());
  }

  // ------------------------------ background merge -----------------------

  private schedule(delay: number = ReadStatusStore.DEBOUNCE_MS): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout((): void => {
      this.timer = -1;
      this.flush();
    }, delay);
  }

  async flush(): Promise<void> {
    if (this.flushing || (this.diffs.readCount() === 0 && this.diffs.starCount() === 0)) {
      return;
    }
    this.flushing = true;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const read: ReadIdPartition = this.diffs.readIdsByState();
    const star: StarIdPartition = this.diffs.starIdsByState();
    let highest: number = 0;
    try {
      if (read.readIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(read.readIds, true);
        highest = Math.max(highest, this.resolve(read.readIds, done));
      }
      if (read.unreadIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(read.unreadIds, false);
        highest = Math.max(highest, this.resolve(read.unreadIds, done));
      }
      if (star.starredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(star.starredIds, true);
        highest = Math.max(highest, this.resolve(star.starredIds, done));
      }
      if (star.unstarredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(star.unstarredIds, false);
        highest = Math.max(highest, this.resolve(star.unstarredIds, done));
      }
      // Commit only broadcasts the authoritative refresh (not readStatusTick):
      // diffs are cleared (delta=0) while views still hold old DB baselines.
      this.markCacheDirty();
      AppStorage.setOrCreate<number>('readStatusFlushedTick', Date.now());
      if (highest > 0) {
        this.schedule(this.backoffFor(highest));
      }
    } catch (error) {
      Logger.error(`Read status flush failed: ${(error as Error).message}`);
      for (const id of this.diffs.allIds()) {
        const attempt: number = this.fail(id);
        if (attempt > highest) {
          highest = attempt;
        }
      }
      if (highest > 0) {
        this.schedule(this.backoffFor(highest));
      }
    } finally {
      this.flushing = false;
      this.flushCache();
    }
  }

  private resolve(ids: string[], done: string[]): number {
    const highest: number = this.diffs.resolve(ids, done, ReadStatusStore.MAX_ATTEMPTS);
    // Sync the pending registry for ids removed by the pure state machine.
    const ok: Set<string> = new Set<string>(done);
    for (const id of ids) {
      if (ok.has(id) || !this.diffs.hasRead(id) && !this.diffs.hasStar(id)) {
        pendingStatusRegistry.remove(id);
      }
    }
    return highest;
  }

  private clear(id: string): void {
    this.diffs.clear(id);
    pendingStatusRegistry.remove(id);
    this.markCacheDirty();
  }

  private fail(id: string): number {
    const next: number = this.diffs.fail(id, ReadStatusStore.MAX_ATTEMPTS);
    if (next < 0) {
      pendingStatusRegistry.remove(id);
      Logger.warn(`Gave up syncing status for ${id} after ${ReadStatusStore.MAX_ATTEMPTS} attempts`);
      return 0;
    }
    return next;
  }

  private backoffFor(highestAttempt: number): number {
    return Math.min(
      ReadStatusStore.RETRY_BASE_MS * Math.pow(2, Math.max(0, highestAttempt - 1)),
      ReadStatusStore.RETRY_MAX_MS
    );
  }
}

export const readStatusStore: ReadStatusStore = new ReadStatusStore();
