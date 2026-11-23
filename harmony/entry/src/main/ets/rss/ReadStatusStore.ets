import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { rssRepository } from './RssRepository';
import { pendingStatusRegistry } from './PendingStatusRegistry';
import { Article } from '../model/Models';
import { Logger } from '../common/Logger';

/** One pending read-state change. Only stored while the desired state differs
 *  from the DB state (mirrors Android DiffMapHolder.Diff). */
interface ReadDiff {
  unread: boolean;
  feedId: string;
  groupId: string;
}

/** One pending star-state change, tracking feedId so per-feed starred badges
 *  can be derived just like unread badges. */
interface StarDiff {
  starred: boolean;
  feedId: string;
}

/**
 * Local-first read/star status holder (ArkTS port of Android's DiffMapHolder).
 *
 * The single source of truth for read/star UI state is the in-memory diff map
 * layered over the DB. Marking only touches the diff and publishes a tick; the
 * UI derives each row's state via effectiveUnread/effectiveStarred and derives
 * counts as DB value + diff delta. A debounced background flush commits the
 * diffs to the DB and pushes them to the server, retrying failures with a bound.
 */
class ReadStatusStore {
  private static readonly DEBOUNCE_MS: number = 5000;
  private static readonly MAX_ATTEMPTS: number = 5;
  private static readonly RETRY_BASE_MS: number = 5000;
  private static readonly RETRY_MAX_MS: number = 60000;

  private readDiffs: Map<string, ReadDiff> = new Map<string, ReadDiff>();
  private starDiffs: Map<string, StarDiff> = new Map<string, StarDiff>();
  private attempts: Map<string, number> = new Map<string, number>();
  private static readonly CACHE_WRITE_MS: number = 500;

  private timer: number = -1;
  private cacheTimer: number = -1;
  private flushing: boolean = false;
  private cacheDirty: boolean = false;
  private context: common.Context | undefined = undefined;

  init(context: common.Context): void {
    this.context = context;
    this.loadFromCache();
    // Restored diffs from a previous crash still need to be pushed.
    if (this.readDiffs.size > 0 || this.starDiffs.size > 0) {
      this.schedule();
    }
  }

  /** Diffs survive a process restart, matching Android's DiffMapHolder cache.
   *  Format: one line per id: r|id|unread|feedId|groupId  or  s|id|starred. */
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
        const lines: string[] = text.split('\n');
        for (const line of lines) {
          if (line.length === 0) {
            continue;
          }
          const parts: string[] = line.split('|');
          if (parts[0] === 'r' && parts.length >= 5) {
            this.readDiffs.set(parts[1], {
              unread: parts[2] === '1', feedId: parts[3], groupId: parts[4],
            });
            pendingStatusRegistry.add(parts[1]);
          } else if (parts[0] === 's' && parts.length >= 3) {
            this.starDiffs.set(parts[1], { starred: parts[2] === '1', feedId: parts.length >= 4 ? parts[3] : '' });
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

  /** Mark the cache dirty; the actual write is coalesced to one per flush so a
   *  bulk mark or a multi-id commit never does N sequential disk writes. */
  private markCacheDirty(): void {
    this.cacheDirty = true;
    if (this.cacheTimer < 0) {
      this.cacheTimer = setTimeout((): void => {
        this.cacheTimer = -1;
        this.flushCache();
      }, ReadStatusStore.CACHE_WRITE_MS);
    }
  }

  /** Write the whole diff map once. Called at the end of a flush and on exit. */
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
      this.readDiffs.forEach((d: ReadDiff, id: string): void => {
        lines.push(`r|${id}|${d.unread ? '1' : '0'}|${d.feedId}|${d.groupId}`);
      });
      this.starDiffs.forEach((s: StarDiff, id: string): void => {
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
    const diff: ReadDiff | undefined = this.readDiffs.get(articleId);
    return diff === undefined ? dbUnread : diff.unread;
  }

  effectiveStarred(articleId: string, dbStarred: boolean): boolean {
    const diff: StarDiff | undefined = this.starDiffs.get(articleId);
    return diff === undefined ? dbStarred : diff.starred;
  }

  /** Project the diff map onto freshly loaded rows so the UI shows local state
   *  even before the DB commit. Mutates only the row copies in the list. */
  applyTo(articles: Article[]): void {
    for (const article of articles) {
      article.isRead = !this.effectiveUnread(article.id, !article.isRead);
      article.isStarred = this.effectiveStarred(article.id, article.isStarred);
    }
  }

  hasPending(articleId: string): boolean {
    return this.readDiffs.has(articleId) || this.starDiffs.has(articleId);
  }

  /** Drop a local diff after a bulk operation: either the service confirmed it
   *  to the DB, or the operation failed and the UI rolled back. */
  clearConfirmed(articleId: string): void {
    this.clear(articleId);
  }

  // ------------------------------ count delta ----------------------------

  /** Count delta to add to a DB-based count: +1 per article locally unread but
   *  DB-read, -1 per article locally read but DB-unread. */
  unreadDelta(feedId: string, groupId: string, global: boolean): number {
    let delta: number = 0;
    this.readDiffs.forEach((diff: ReadDiff): void => {
      if (!global && feedId.length > 0 && diff.feedId !== feedId) {
        return;
      }
      if (!global && feedId.length === 0 && groupId.length > 0 && diff.groupId !== groupId) {
        return;
      }
      delta += diff.unread ? 1 : -1;
    });
    return delta;
  }

  /** Starred count delta, optionally scoped to one feed (empty = global). */
  starredDelta(feedId: string): number {
    let delta: number = 0;
    this.starDiffs.forEach((diff: StarDiff): void => {
      if (feedId.length > 0 && diff.feedId !== feedId) {
        return;
      }
      delta += diff.starred ? 1 : -1;
    });
    return delta;
  }

  // -------------------------------- marking ------------------------------

  /** Record a desired read state. `currentUnread` is the state the UI showed
   *  before the toggle (equal to the DB state unless a diff already exists).
   *  The store derives the baseline itself, so callers never pass raw DB flags. */
  markRead(articleId: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string): void {
    const baseline: boolean = this.readDiffs.has(articleId)
      ? !this.readDiffs.get(articleId)!.unread
      : currentUnread;
    if (unread === baseline) {
      this.readDiffs.delete(articleId);
      this.attempts.delete(articleId);
    } else {
      this.readDiffs.set(articleId, { unread: unread, feedId: feedId, groupId: groupId });
      pendingStatusRegistry.add(articleId);
    }
    this.publish();
    this.schedule();
  }

  /** Like markRead but does NOT schedule a background flush — use when the
   *  caller persists via its own bulk service call (mark-all/before). The diff
   *  is display-only and removed by clearConfirmed once that call completes. */
  markReadLocal(articleId: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string): void {
    const baseline: boolean = this.readDiffs.has(articleId)
      ? !this.readDiffs.get(articleId)!.unread
      : currentUnread;
    if (unread !== baseline) {
      this.readDiffs.set(articleId, { unread: unread, feedId: feedId, groupId: groupId });
      pendingStatusRegistry.add(articleId);
    }
    this.publish();
  }

  /** Record a desired star state. `currentStarred` is the UI state before the
   *  toggle (equal to the DB state unless a diff already exists). */
  markStarred(articleId: string, starred: boolean, currentStarred: boolean, feedId: string): void {
    const baseline: boolean = this.starDiffs.has(articleId)
      ? !this.starDiffs.get(articleId)!.starred
      : currentStarred;
    if (starred === baseline) {
      this.starDiffs.delete(articleId);
      this.attempts.delete(articleId);
    } else {
      this.starDiffs.set(articleId, { starred: starred, feedId: feedId });
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

  /** Commit all diffs to DB + server. Called by the debounce timer, by sync
   *  start, and on page exit. Failures keep their diff and retry with backoff. */
  async flush(): Promise<void> {
    if (this.flushing || (this.readDiffs.size === 0 && this.starDiffs.size === 0)) {
      return;
    }
    this.flushing = true;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const unreadIds: string[] = [];
    const readIds: string[] = [];
    this.readDiffs.forEach((diff: ReadDiff, id: string): void => {
      if (diff.unread) {
        unreadIds.push(id);
      } else {
        readIds.push(id);
      }
    });
    const starredIds: string[] = [];
    const unstarredIds: string[] = [];
    this.starDiffs.forEach((diff: StarDiff, id: string): void => {
      if (diff.starred) {
        starredIds.push(id);
      } else {
        unstarredIds.push(id);
      }
    });
    let highest: number = 0;
    try {
      if (readIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(readIds, true);
        highest = Math.max(highest, this.resolve(readIds, done));
      }
      if (unreadIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(unreadIds, false);
        highest = Math.max(highest, this.resolve(unreadIds, done));
      }
      if (starredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(starredIds, true);
        highest = Math.max(highest, this.resolve(starredIds, done));
      }
      if (unstarredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(unstarredIds, false);
        highest = Math.max(highest, this.resolve(unstarredIds, done));
      }
      // Batch committed to DB. Do NOT broadcast readStatusTick here: diffs are
      // already cleared (delta=0) but feed baselines in the views are still the
      // old DB snapshot — broadcasting now would flash stale counts. Instead
      // signal only the authoritative refresh, which re-reads feeds + counts.
      this.markCacheDirty();
      AppStorage.setOrCreate<number>('readStatusFlushedTick', Date.now());
      if (highest > 0) {
        this.schedule(this.backoffFor(highest));
      }
    } catch (error) {
      Logger.error(`Read status flush failed: ${(error as Error).message}`);
      const all: string[] = [];
      this.readDiffs.forEach((_diff: ReadDiff, id: string): void => { all.push(id); });
      this.starDiffs.forEach((_star: StarDiff, id: string): void => { all.push(id); });
      for (const id of all) {
        highest = Math.max(highest, this.fail(id));
      }
      if (highest > 0) {
        this.schedule(this.backoffFor(highest));
      }
    } finally {
      this.flushing = false;
      // One disk write for the entire batch (mark/clear only set a dirty flag).
      this.flushCache();
    }
  }

  /** Remove ids the server confirmed, keep the rest for retry. */
  private resolve(ids: string[], done: string[]): number {
    const ok: Set<string> = new Set<string>(done);
    let highest: number = 0;
    for (const id of ids) {
      if (ok.has(id)) {
        this.clear(id);
      } else {
        highest = Math.max(highest, this.fail(id));
      }
    }
    return highest;
  }

  private clear(id: string): void {
    this.readDiffs.delete(id);
    this.starDiffs.delete(id);
    this.attempts.delete(id);
    pendingStatusRegistry.remove(id);
    this.markCacheDirty();
  }

  private fail(id: string): number {
    const next: number = (this.attempts.get(id) ?? 0) + 1;
    if (next >= ReadStatusStore.MAX_ATTEMPTS) {
      this.clear(id);
      Logger.warn(`Gave up syncing status for ${id} after ${next} attempts`);
      return 0;
    }
    this.attempts.set(id, next);
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
