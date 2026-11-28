import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { rssRepository } from './RssRepository';
import { pendingStatusRegistry } from './PendingStatusRegistry';
import { StatusDiffs, ReadDiff, StarDiff, ReadIdPartition, StarIdPartition, PendingFilterIds } from './StatusDiffs';
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

  // Local changes not yet committed to the DB. This is the ONLY map that
  // drives read/star counts and row projection (Android's DiffMapHolder.diffMap).
  private diffs: StatusDiffs = new StatusDiffs();
  // Server-push retries, kept separate (Android's pendingSyncDiffs). The sync
  // services write to the DB for every id they receive but only confirm ids
  // whose remote tag edit succeeded. Keeping a failed id in `diffs` would make
  // unreadDelta subtract an already-committed change a second time, collapsing
  // the count to 0 while genuinely unread rows still render unread.
  private remoteReads: StatusDiffs = new StatusDiffs();
  private remoteStars: StatusDiffs = new StatusDiffs();
  private timer: number = -1;
  private remoteTimer: number = -1;
  private cacheTimer: number = -1;
  private flushing: boolean = false;
  private retryingRemote: boolean = false;
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

  /** Debug only: discard every pending/retry diff and its cache after the
   *  article table is wiped by the settings "clear all articles" action. */
  resetForDebug(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.remoteTimer >= 0) {
      clearTimeout(this.remoteTimer);
      this.remoteTimer = -1;
    }
    if (this.cacheTimer >= 0) {
      clearTimeout(this.cacheTimer);
      this.cacheTimer = -1;
    }
    this.flushing = false;
    this.retryingRemote = false;
    this.cacheDirty = false;
    this.diffs.clearAll();
    this.remoteReads.clearAll();
    this.remoteStars.clearAll();
    pendingStatusRegistry.clear();
    if (this.context !== undefined) {
      try {
        fs.unlinkSync(this.cachePath());
      } catch (error) {
        // Cache file may not exist yet — nothing to clean up.
      }
    }
  }

  /** Account-scoped variant used by the settings "clear this account" action.
   *  Other accounts' pending marks, retry queues and cache entries stay intact. */
  resetForDebugAccount(accountId: string): void {
    this.diffs.clearAccount(accountId);
    this.remoteReads.clearAccount(accountId);
    this.remoteStars.clearAccount(accountId);
    pendingStatusRegistry.clearAccount(accountId);
    this.markCacheDirty();
    this.flushCache();
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

  /** Pending local changes for the filtered article query. The DB still holds
   *  the old values until flush(), so the starred/unread WHERE clause must see
   *  these ids or a just-starred article is invisible until a manual refresh. */
  pendingFilterIds(): PendingFilterIds {
    const star: StarIdPartition = this.diffs.starIdsByState();
    const read: ReadIdPartition = this.diffs.readIdsByState();
    return {
      starredIds: star.starredIds,
      unstarredIds: star.unstarredIds,
      unreadIds: read.unreadIds,
      readIds: read.readIds,
    };
  }

  /** Number of ids waiting for a server-push retry (excluded from counts). */
  remotePendingCount(): number {
    return this.remoteReads.readCount() + this.remoteStars.starCount();
  }

  hasRemotePending(articleId: string): boolean {
    return this.remoteReads.hasRead(articleId) || this.remoteStars.hasStar(articleId);
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

  /** Account-scoped global deltas, for the drawer banner after a switch. */
  unreadDeltaForAccount(accountId: string): number {
    return this.diffs.unreadDeltaForAccount(accountId);
  }

  starredDeltaForAccount(accountId: string): number {
    return this.diffs.starredDeltaForAccount(accountId);
  }

  // -------------------------------- marking ------------------------------

  markRead(
    articleId: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string,
    silent: boolean = false
  ): void {
    if (this.diffs.markRead(articleId, unread, currentUnread, feedId, groupId)) {
      pendingStatusRegistry.add(articleId);
    }
    // A fresh local change supersedes any older server retry for this id.
    this.remoteReads.clear(articleId);
    this.publish(silent);
    this.schedule();
  }

  markReadLocal(
    articleId: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string,
    silent: boolean = false
  ): void {
    if (this.diffs.markRead(articleId, unread, currentUnread, feedId, groupId)) {
      pendingStatusRegistry.add(articleId);
    }
    this.remoteReads.clear(articleId);
    this.publish(silent);
  }

  markStarred(
    articleId: string, starred: boolean, currentStarred: boolean, feedId: string,
    silent: boolean = false
  ): void {
    if (this.diffs.markStarred(articleId, starred, currentStarred, feedId)) {
      pendingStatusRegistry.add(articleId);
    }
    this.remoteStars.clear(articleId);
    this.publish(silent);
    this.schedule();
  }

  /** Publish once after a batch of silent mark* calls. */
  notifyChanged(): void {
    this.publish(false);
  }

  private publish(silent: boolean = false): void {
    this.markCacheDirty();
    if (!silent) {
      // Monotonic counter: Date.now() can repeat within a millisecond, and
      // AppStorage/@Watch ignores equal values, dropping the refresh.
      const tick: number = (AppStorage.get<number>('readStatusTick') ?? 0) + 1;
      AppStorage.setOrCreate<number>('readStatusTick', tick);
    }
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

  private flushTask?: Promise<void>;

  async flush(): Promise<void> {
    if (this.flushing) {
      // A sync must wait for an already-running flush instead of reconciling
      // against a stale server view while marks are still being pushed.
      if (this.flushTask !== undefined) {
        await this.flushTask;
      }
      return;
    }
    if (this.diffs.readCount() === 0 && this.diffs.starCount() === 0) {
      return;
    }
    this.flushing = true;
    let finishFlush: () => void = (): void => {};
    this.flushTask = new Promise<void>((resolve: () => void): void => { finishFlush = resolve; });
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const read: ReadIdPartition = this.diffs.readIdsByState();
    const star: StarIdPartition = this.diffs.starIdsByState();
    try {
      // markReadBatch/markStarredBatch write EVERY submitted id to the DB before
      // pushing to the server, and return only the ids whose remote edit
      // succeeded. Once the call resolves the local diff is committed, so it
      // must go even for a remote failure — otherwise unreadDelta would subtract
      // the same change twice (DB already updated) and the unread count would
      // collapse to 0 while genuinely unread rows still show unread.
      if (read.readIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(read.readIds, true);
        this.commitRead(read.readIds, done);
      }
      if (read.unreadIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(read.unreadIds, false);
        this.commitRead(read.unreadIds, done);
      }
      if (star.starredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(star.starredIds, true);
        this.commitStar(star.starredIds, done);
      }
      if (star.unstarredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(star.unstarredIds, false);
        this.commitStar(star.unstarredIds, done);
      }
      // Commit only broadcasts the authoritative refresh (not readStatusTick):
      // local diffs are cleared (delta=0) while views still hold old DB baselines.
      this.markCacheDirty();
      // Monotonic counter, not Date.now(): two flushes in the same
      // millisecond produce equal values, which AppStorage/@Watch drops and
      // the drawer badges stay stale.
      const flushed: number = (AppStorage.get<number>('readStatusFlushedTick') ?? 0) + 1;
      AppStorage.setOrCreate<number>('readStatusFlushedTick', flushed);
      this.scheduleRemoteIfPending();
    } catch (error) {
      // The DB write itself failed: keep the local diffs and retry them (they
      // are still the only representation of the change).
      Logger.error(`Read status flush failed: ${(error as Error).message}`);
      let highest: number = 0;
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
      finishFlush();
      this.flushTask = undefined;
      this.flushCache();
    }
  }

  /** Drop the local diffs committed to the DB; failed remote pushes move to the
   *  independent retry queue and no longer affect counts/rows. */
  private commitRead(ids: string[], done: string[]): void {
    const ok: Set<string> = new Set<string>(done);
    for (const id of ids) {
      const diff: ReadDiff | undefined = this.diffs.readDiffOf(id);
      this.diffs.clearRead(id);
      if (ok.has(id)) {
        this.releaseRegistry(id);
      } else {
        // The server view is stale: keep protecting this id during sync while
        // retrying only the remote push.
        this.remoteReads.setReadDiff(id, diff ?? { unread: false, feedId: '', groupId: '' });
      }
    }
  }

  private commitStar(ids: string[], done: string[]): void {
    const ok: Set<string> = new Set<string>(done);
    for (const id of ids) {
      const diff: StarDiff | undefined = this.diffs.starDiffOf(id);
      this.diffs.clearStar(id);
      if (ok.has(id)) {
        this.releaseRegistry(id);
      } else {
        this.remoteStars.setStarDiff(id, diff ?? { starred: false, feedId: '' });
      }
    }
  }

  /** Keep an id protected from stale server reconciliation until every local
   *  and remote change for it has been accounted for. */
  private releaseRegistry(id: string): void {
    if (!this.diffs.hasRead(id) && !this.diffs.hasStar(id)
      && !this.remoteReads.hasRead(id) && !this.remoteStars.hasStar(id)) {
      pendingStatusRegistry.remove(id);
    }
  }

  private scheduleRemoteIfPending(): void {
    if (this.remoteReads.readCount() === 0 && this.remoteStars.starCount() === 0) {
      return;
    }
    this.scheduleRemote(ReadStatusStore.RETRY_BASE_MS);
  }

  private scheduleRemote(delay: number): void {
    if (this.remoteTimer >= 0) {
      clearTimeout(this.remoteTimer);
    }
    this.remoteTimer = setTimeout((): void => {
      this.remoteTimer = -1;
      this.retryRemote();
    }, delay);
  }

  /** Retry only the server push for changes already committed to the DB. */
  private async retryRemote(): Promise<void> {
    if (this.retryingRemote
      || (this.remoteReads.readCount() === 0 && this.remoteStars.starCount() === 0)) {
      return;
    }
    this.retryingRemote = true;
    let highest: number = 0;
    try {
      const read: ReadIdPartition = this.remoteReads.readIdsByState();
      const star: StarIdPartition = this.remoteStars.starIdsByState();
      if (read.readIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(read.readIds, true);
        highest = Math.max(highest, this.remoteReads.resolve(read.readIds, done, ReadStatusStore.MAX_ATTEMPTS));
        for (const id of done) { this.releaseRegistry(id); }
      }
      if (read.unreadIds.length > 0) {
        const done: string[] = await rssRepository.markReadBatch(read.unreadIds, false);
        highest = Math.max(highest, this.remoteReads.resolve(read.unreadIds, done, ReadStatusStore.MAX_ATTEMPTS));
        for (const id of done) { this.releaseRegistry(id); }
      }
      if (star.starredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(star.starredIds, true);
        highest = Math.max(highest, this.remoteStars.resolve(star.starredIds, done, ReadStatusStore.MAX_ATTEMPTS));
        for (const id of done) { this.releaseRegistry(id); }
      }
      if (star.unstarredIds.length > 0) {
        const done: string[] = await rssRepository.markStarredBatch(star.unstarredIds, false);
        highest = Math.max(highest, this.remoteStars.resolve(star.unstarredIds, done, ReadStatusStore.MAX_ATTEMPTS));
        for (const id of done) { this.releaseRegistry(id); }
      }
    } catch (error) {
      Logger.error(`Remote status retry failed: ${(error as Error).message}`);
      for (const id of this.remoteReads.allIds()) {
        const attempt: number = this.remoteReads.fail(id, ReadStatusStore.MAX_ATTEMPTS);
        if (attempt > highest) { highest = attempt; }
        else if (attempt < 0) { this.releaseRegistry(id); }
      }
      for (const id of this.remoteStars.allIds()) {
        const attempt: number = this.remoteStars.fail(id, ReadStatusStore.MAX_ATTEMPTS);
        if (attempt > highest) { highest = attempt; }
        else if (attempt < 0) { this.releaseRegistry(id); }
      }
    } finally {
      this.retryingRemote = false;
    }
    if (highest > 0) {
      this.scheduleRemote(this.backoffFor(highest));
    }
  }

  private clear(id: string): void {
    this.diffs.clear(id);
    this.remoteReads.clear(id);
    this.remoteStars.clear(id);
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
