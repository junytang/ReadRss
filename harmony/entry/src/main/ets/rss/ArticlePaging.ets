import { Article } from '../model/Models';

/**
 * Pure pagination state machine for the article list, extracted so its guard
 * logic (stale-result rejection, hasMore, dedupe) is unit-testable without UI,
 * DB or platform APIs. The ArkUI component owns an instance and adds side effects.
 */
export class ArticlePaging {
  private loadSeq: number = 0;
  private pageLoadSeq: number = 0;
  private orderKey: string = '';
  private displayLimit: number = 0;
  private hasMore: boolean = true;
  private loadingMore: boolean = false;

  /** Begin a fresh load: bumps the load seq and invalidates in-flight pages.
   *  Returns the new load seq (callers pass it to append operations). */
  beginLoad(firstPageSize: number, orderKey: string, resetPaging: boolean): number {
    this.loadSeq++;
    this.pageLoadSeq++;
    this.orderKey = orderKey;
    if (resetPaging) {
      this.displayLimit = firstPageSize;
    }
    return this.loadSeq;
  }

  /** Begin a loadMore: returns the new page seq, or -1 when it must be ignored. */
  beginLoadMore(): number {
    if (this.loadingMore || !this.hasMore) {
      return -1;
    }
    this.loadingMore = true;
    this.pageLoadSeq++;
    return this.pageLoadSeq;
  }

  endLoadMore(): void {
    this.loadingMore = false;
  }

  isLoadingMore(): boolean {
    return this.loadingMore;
  }

  getLoadSeq(): number {
    return this.loadSeq;
  }

  getPageSeq(): number {
    return this.pageLoadSeq;
  }

  getOrderKey(): string {
    return this.orderKey;
  }

  getDisplayLimit(): number {
    return this.displayLimit;
  }

  getHasMore(): boolean {
    return this.hasMore;
  }

  /** True when a result from the given seq/page/order is stale and must be
   *  discarded (a newer load/switch happened while it was in flight). */
  isStale(seq: number, capturedPageSeq: number, capturedOrderKey: string): boolean {
    return seq !== this.loadSeq
      || capturedPageSeq !== this.pageLoadSeq
      || capturedOrderKey !== this.orderKey;
  }

  /** Reject a loadMore result when a newer load started. */
  isPageStale(seq: number, pageSeq: number): boolean {
    return seq !== this.loadSeq || pageSeq !== this.pageLoadSeq;
  }

  /** Set hasMore from a query result size vs requested limit. */
  updateHasMore(rowCount: number, requestedLimit: number): void {
    this.hasMore = rowCount >= requestedLimit;
  }

  /** Merge freshly-loaded rows into existing ones, deduping by id.
   *  Returns true when at least one genuinely new row was appended. */
  mergeAppend(existing: Article[], rows: Article[]): AppendResult {
    const known: Set<string> = new Set<string>();
    for (const article of existing) {
      known.add(article.id);
    }
    const fresh: Article[] = [];
    for (const row of rows) {
      if (!known.has(row.id)) {
        known.add(row.id);
        fresh.push(row);
      }
    }
    const articles: Article[] = fresh.length > 0 ? existing.concat(fresh) : existing;
    return { articles: articles, appended: fresh.length > 0 };
  }

  /** Set the new display limit after a successful append. */
  setDisplayLimit(limit: number): void {
    this.displayLimit = limit;
  }

  /** Compute the next chunk target, clamped to FULL_PAGE_SIZE. */
  nextExpandTarget(fullPageSize: number, chunk: number): number {
    return Math.min(this.displayLimit + chunk, fullPageSize);
  }
}

export interface AppendResult {
  articles: Article[];
  appended: boolean;
}
