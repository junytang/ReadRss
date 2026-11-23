import { rssRepository } from './RssRepository';
import { pendingStatusRegistry } from './PendingStatusRegistry';
import { Logger } from '../common/Logger';

interface PendingStar {
  starred: boolean;
  attempts: number;
}

/**
 * Debounces and merges read/star status pushes to the server (Android
 * DiffMapHolder equivalent). Failed pushes are NOT discarded: they stay queued
 * and are retried in the background with exponential backoff, up to
 * MAX_ATTEMPTS total tries, after which the id is dropped.
 */
class ReadStatusBatcher {
  private static readonly DELAY_MS: number = 10000;
  /** Total attempts per id before giving up (initial push + retries). */
  private static readonly MAX_ATTEMPTS: number = 5;
  private static readonly RETRY_BASE_MS: number = 5000;
  private static readonly RETRY_MAX_MS: number = 60000;

  /** read ids -> number of failed attempts so far (0 = never tried). */
  private pending: Map<string, number> = new Map<string, number>();
  /** star ids -> desired state + attempts. */
  private pendingStars: Map<string, PendingStar> = new Map<string, PendingStar>();
  private timer: number = -1;
  private flushing: boolean = false;

  /** Ids whose local state is pending. Sync reconciliation MUST NOT overwrite
   *  these with stale server state (Android pendingSyncDiffs semantics). */
  pendingIds(): string[] {
    const ids: string[] = [];
    this.pending.forEach((_attempt: number, id: string): void => { ids.push(id); });
    this.pendingStars.forEach((_star: PendingStar, id: string): void => { ids.push(id); });
    return ids;
  }

  add(articleId: string): void {
    this.pending.set(articleId, 0);
    pendingStatusRegistry.add(articleId);
    this.schedule(ReadStatusBatcher.DELAY_MS);
  }

  addStar(articleId: string, starred: boolean): void {
    this.pendingStars.set(articleId, { starred: starred, attempts: 0 });
    pendingStatusRegistry.add(articleId);
    this.schedule(ReadStatusBatcher.DELAY_MS);
  }

  /** True when an id is queued for a background mark-as-read (e.g. scroll marks
   *  that are only optimistic so far). */
  hasPendingRead(articleId: string): boolean {
    return this.pending.has(articleId);
  }

  /** Cancel a queued push when the user reverts the state manually. Otherwise a
   *  stale pending mark-read would overwrite the user's newer state on flush. */
  remove(articleId: string): void {
    const hadRead: boolean = this.pending.delete(articleId);
    const hadStar: boolean = this.pendingStars.delete(articleId);
    if (hadRead || hadStar) {
      pendingStatusRegistry.remove(articleId);
    }
  }

  private schedule(delay: number): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flush();
    }, delay);
  }

  /** Flush pending marks. Only ids confirmed by the service are removed;
   *  failures stay queued and are retried until MAX_ATTEMPTS is reached. */
  async flush(): Promise<void> {
    if (this.flushing || (this.pending.size === 0 && this.pendingStars.size === 0)) {
      return;
    }
    this.flushing = true;
    // Snapshot the ids up front. Items added during the await belong to the
    // next round and must not be misclassified as failures here.
    const readIds: string[] = [];
    this.pending.forEach((_attempt: number, id: string): void => { readIds.push(id); });
    const starIds: string[] = [];
    this.pendingStars.forEach((_star: PendingStar, id: string): void => { starIds.push(id); });
    let highest: number = 0;
    try {
      if (readIds.length > 0) {
        const succeeded: string[] = await rssRepository.markReadBatch(readIds, true);
        const ok: Set<string> = new Set<string>(succeeded);
        const toRemove: string[] = [];
        const failed: string[] = [];
        for (const id of readIds) {
          if (ok.has(id)) {
            toRemove.push(id);
          } else {
            failed.push(id);
          }
        }
        for (const id of toRemove) {
          this.pending.delete(id);
          pendingStatusRegistry.remove(id);
        }
        highest = Math.max(highest, this.bumpFailures(failed));
      }
      for (const id of starIds) {
        const mark: PendingStar | undefined = this.pendingStars.get(id);
        if (mark === undefined) {
          continue; // state changed again while flushing; leave it for next round
        }
        try {
          await rssRepository.markStarred(id, mark.starred);
          this.pendingStars.delete(id);
          pendingStatusRegistry.remove(id);
        } catch (error) {
          Logger.error(`Star sync failed: ${(error as Error).message} id=${id}`);
          const next: number = mark.attempts + 1;
          if (next >= ReadStatusBatcher.MAX_ATTEMPTS) {
            this.pendingStars.delete(id);
            pendingStatusRegistry.remove(id);
            Logger.warn(`Gave up syncing star for ${id} after ${next} attempts`);
          } else {
            mark.attempts = next;
            highest = Math.max(highest, next);
          }
        }
      }
      // Each service writes the DB (setStates / setArticleStarred) BEFORE any
      // remote call, so the DB is authoritative once markReadBatch/markStarred
      // resolve. Always clear the optimistic deltas here — even if the remote
      // push failed and the id was requeued — otherwise the unread count drifts
      // permanently low. (Older code emitted this tick only on success.)
      AppStorage.setOrCreate<number>('readStatusFlushedTick', Date.now());
      if (highest > 0) {
        this.schedule(this.backoffFor(highest));
      }
    } catch (error) {
      Logger.error(`Flush read status failed: ${(error as Error).message}`);
      const allRead: string[] = [];
      this.pending.forEach((_attempt: number, id: string): void => { allRead.push(id); });
      highest = Math.max(highest, this.bumpFailures(allRead));
      const allStars: string[] = [];
      this.pendingStars.forEach((_star: PendingStar, id: string): void => { allStars.push(id); });
      for (const id of allStars) {
        const mark: PendingStar | undefined = this.pendingStars.get(id);
        if (mark === undefined) {
          continue;
        }
        const next: number = mark.attempts + 1;
        if (next >= ReadStatusBatcher.MAX_ATTEMPTS) {
          this.pendingStars.delete(id);
          pendingStatusRegistry.remove(id);
        } else {
          mark.attempts = next;
          highest = Math.max(highest, next);
        }
      }
      if (highest > 0) {
        this.schedule(this.backoffFor(highest));
      }
    } finally {
      this.flushing = false;
    }
  }

  /** Bump the attempt counter for the given read ids. Ids reaching MAX_ATTEMPTS
   *  are dropped. Returns the highest resulting attempt (for backoff). */
  private bumpFailures(ids: string[]): number {
    let highest: number = 0;
    for (const id of ids) {
      const attempt: number | undefined = this.pending.get(id);
      if (attempt === undefined) {
        continue;
      }
      const next: number = attempt + 1;
      if (next >= ReadStatusBatcher.MAX_ATTEMPTS) {
        this.pending.delete(id);
        pendingStatusRegistry.remove(id);
        Logger.warn(`Gave up syncing read status for ${id} after ${next} attempts`);
      } else {
        this.pending.set(id, next);
        if (next > highest) {
          highest = next;
        }
      }
    }
    return highest;
  }

  private backoffFor(highestAttempt: number): number {
    return Math.min(
      ReadStatusBatcher.RETRY_BASE_MS * Math.pow(2, Math.max(0, highestAttempt - 1)),
      ReadStatusBatcher.RETRY_MAX_MS
    );
  }
}

export const readStatusBatcher: ReadStatusBatcher = new ReadStatusBatcher();
