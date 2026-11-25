import { Article } from '../model/Models';
import { rssRepository } from './RssRepository';
import { Logger } from '../common/Logger';
import { SYNC_CONCURRENCY } from './SyncRuntime';

/** A queued fetch together with the list index where it entered the viewport. */
interface PendingFetch {
  id: string;
  index: number;
}

/**
 * Sliding-window prefetcher for article full text.
 * Keeps a small buffer of full content ahead of the visible item so tapping an
 * article usually needs no network wait. Each buffered item costs one request
 * to the origin site, so the window is deliberately small: it only has to cover
 * the next few rows the user is likely to tap, not the whole page.
 */
class ReadYouFullContentPrefetcher {
  /** One extra screen of full text ahead; a big window fired a request per row. */
  private static readonly BUFFER_MULTIPLIER: number = 1;
  private static readonly DEFAULT_BUFFER: number = 6;
  private static readonly MAX_BUFFER: number = 10;
  /** Same cap as every sync protocol: gentle on the origin servers. */
  private static readonly CONCURRENCY: number = SYNC_CONCURRENCY;

  // Cap the tracking sets. They only exist to avoid duplicate fetches; once a
  // user scrolls far, old ids are irrelevant.
  private static readonly MAX_TRACKED: number = 300;
  // Bound the pending queue so a fast scroll cannot accumulate hundreds of
  // origin requests for rows the user has already scrolled past.
  private static readonly MAX_PENDING: number = 48;
  private done: Set<string> = new Set<string>();
  private failed: Set<string> = new Set<string>();
  private inFlight: Set<string> = new Set<string>();
  private running: boolean = false;
  private pending: PendingFetch[] = [];
  /** id -> index at which it was last seen in/near the viewport. */
  private lastSeen: Map<string, number> = new Map<string, number>();

  /** Evict the entries farthest from the current viewport, not the oldest by
   *  insertion order. A pure FIFO eviction dropped still-visible failed ids
   *  first, so scrolling back re-queued them and re-hit the origin site. */
  private trimTracking(currentIndex: number): void {
    this.evictFarthest(this.done, currentIndex);
    this.evictFarthest(this.failed, currentIndex);
  }

  private evictFarthest(tracked: Set<string>, currentIndex: number): void {
    while (tracked.size > ReadYouFullContentPrefetcher.MAX_TRACKED) {
      let farthest: string | undefined = undefined;
      let farthestDist: number = -1;
      tracked.forEach((id: string): void => {
        const seen: number | undefined = this.lastSeen.get(id);
        // An id without a position is considered farthest away.
        const dist: number = seen === undefined ? 1e12 : Math.abs(seen - currentIndex);
        if (dist > farthestDist) {
          farthestDist = dist;
          farthest = id;
        }
      });
      if (farthest === undefined) {
        return;
      }
      tracked.delete(farthest);
      this.lastSeen.delete(farthest);
    }
  }

  /** Drop queued entries that have scrolled far away, keeping only the ones
   *  nearest the viewport. inFlight tasks are already running and untouched. */
  private trimPending(currentIndex: number): void {
    while (this.pending.length > ReadYouFullContentPrefetcher.MAX_PENDING) {
      let worst: number = 0;
      let worstDist: number = -1;
      for (let i: number = 0; i < this.pending.length; i++) {
        const dist: number = Math.abs(this.pending[i].index - currentIndex);
        if (dist > worstDist) {
          worstDist = dist;
          worst = i;
        }
      }
      this.pending.splice(worst, 1);
    }
  }

  /**
   * @param visibleCount number of items currently on screen (from onScrollIndex end - start + 1).
   *                     When unknown, a default buffer is used until the first scroll event.
   */
  ensureWindow(articles: Article[], firstVisibleIndex: number, visibleCount?: number): void {
    if (articles.length === 0) {
      return;
    }
    const buffer: number = visibleCount && visibleCount > 0
      ? Math.min(
          Math.max(visibleCount * ReadYouFullContentPrefetcher.BUFFER_MULTIPLIER,
            ReadYouFullContentPrefetcher.DEFAULT_BUFFER),
          ReadYouFullContentPrefetcher.MAX_BUFFER
        )
      : ReadYouFullContentPrefetcher.DEFAULT_BUFFER;
    // Only the visible window and the rows just below it. Scanning from index 0
    // made every scroll event re-queue the whole list once old ids had been
    // evicted from the tracking sets — hundreds of origin requests per scroll.
    const start: number = Math.max(0, firstVisibleIndex);
    const end: number = Math.min(articles.length, start + buffer);
    const newly: PendingFetch[] = [];
    for (let i: number = start; i < end; i++) {
      const id: string = articles[i].id;
      // Touch on every sighting so "distance from viewport" is accurate.
      this.lastSeen.set(id, i);
      if (articles[i].fullContent.length > 0) {
        this.done.add(id);
        continue;
      }
      if (!this.done.has(id) && !this.failed.has(id) && !this.inFlight.has(id)
        && !this.pending.some((p: PendingFetch): boolean => p.id === id)) {
        newly.push({ id: id, index: i });
      }
    }
    // Items newly required by scrolling take priority over the initial backfill.
    for (let i: number = newly.length - 1; i >= 0; i--) {
      this.pending.unshift(newly[i]);
    }
    this.trimTracking(start);
    this.trimPending(start);
    this.drain();
  }

  private async drain(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    try {
      while (this.pending.length > 0) {
        const batch: PendingFetch[] = this.pending.splice(0, ReadYouFullContentPrefetcher.CONCURRENCY);
        const tasks: Array<Promise<void>> = [];
        for (const item of batch) {
          this.inFlight.add(item.id);
          tasks.push(this.fetchOne(item.id));
        }
        await Promise.all(tasks);
      }
    } finally {
      this.running = false;
    }
  }

  private async fetchOne(id: string): Promise<void> {
    try {
      // First make sure the remote body is cached (read-only articles may not have it).
      let article: Article | undefined = await rssRepository.ensureArticleContent(id);
      if (article) {
        // List rows are lightweight (no full text), so pass the loaded article
        // straight through instead of re-reading it from the database.
        article = await rssRepository.ensureFullContentFor(article) ?? article;
      }
      if (article && article.fullContent.length > 0) {
        this.done.add(id);
      } else {
        // One attempt per id: avoid hammering the origin site on every scroll event.
        this.failed.add(id);
      }
    } catch (error) {
      Logger.error(`Prefetch full content failed for ${id}: ${(error as Error).message}`);
    } finally {
      this.inFlight.delete(id);
    }
  }
}

export const fullContentPrefetcher: ReadYouFullContentPrefetcher = new ReadYouFullContentPrefetcher();
