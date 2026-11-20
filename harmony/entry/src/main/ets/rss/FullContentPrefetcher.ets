import { Article } from '../model/Models';
import { rssRepository } from './RssRepository';
import { Logger } from '../common/Logger';

/**
 * Sliding-window prefetcher for article full text.
 * Keeps roughly 2 screens (30 items) of full content ahead of the visible item so
 * that tapping an article never has to wait for a network fetch.
 */
class ReadYouFullContentPrefetcher {
  /** Keep 2 screens of full text ahead; cap to avoid an unbounded burst. */
  private static readonly BUFFER_MULTIPLIER: number = 2;
  private static readonly DEFAULT_BUFFER: number = 30;
  private static readonly MAX_BUFFER: number = 60;
  private static readonly CONCURRENCY: number = 3;

  private done: Set<string> = new Set<string>();
  private failed: Set<string> = new Set<string>();
  private inFlight: Set<string> = new Set<string>();
  private running: boolean = false;
  private pending: string[] = [];

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
    const end: number = Math.min(articles.length, firstVisibleIndex + buffer);
    const newly: string[] = [];
    for (let i = 0; i < end; i++) {
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
        article = await rssRepository.ensureFullContent(id) ?? article;
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
