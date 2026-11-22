import { Article } from '../model/Models';
import { rssRepository } from './RssRepository';
import { Logger } from '../common/Logger';

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
  private static readonly CONCURRENCY: number = 2;

  // Cap the tracking sets. They only exist to avoid duplicate fetches; once a
  // user scrolls far, old ids are irrelevant. Entries are evicted oldest-first
  // so the articles still near the viewport keep their "already handled" mark.
  private static readonly MAX_TRACKED: number = 300;
  private done: Set<string> = new Set<string>();
  private failed: Set<string> = new Set<string>();
  private inFlight: Set<string> = new Set<string>();
  private running: boolean = false;
  private pending: string[] = [];

  private trimTracking(): void {
    this.evictOldest(this.done);
    this.evictOldest(this.failed);
  }

  private evictOldest(tracked: Set<string>): void {
    while (tracked.size > ReadYouFullContentPrefetcher.MAX_TRACKED) {
      const oldest: string | undefined = tracked.keys().next().value;
      if (oldest === undefined) {
        return;
      }
      tracked.delete(oldest);
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
    const newly: string[] = [];
    for (let i = start; i < end; i++) {
      const id: string = articles[i].id;
      if (articles[i].fullContent.length > 0) {
        this.done.add(id);
        continue;
      }
      if (!this.done.has(id) && !this.failed.has(id) && !this.inFlight.has(id)
        && this.pending.indexOf(id) < 0) {
        newly.push(id);
      }
    }
    // Items newly required by scrolling take priority over the initial backfill.
    for (let i = newly.length - 1; i >= 0; i--) {
      this.pending.unshift(newly[i]);
    }
    this.trimTracking();
    this.drain();
  }

  private async drain(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    try {
      while (this.pending.length > 0) {
        const batch: string[] = this.pending.splice(0, ReadYouFullContentPrefetcher.CONCURRENCY);
        const tasks: Array<Promise<void>> = [];
        for (const id of batch) {
          this.inFlight.add(id);
          tasks.push(this.fetchOne(id));
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
