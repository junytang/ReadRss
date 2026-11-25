/**
 * Shared runtime policy for every sync protocol (GReader/FreshRSS, Fever,
 * Miniflux) and for the full-text prefetcher.
 *
 * Goals: cap network concurrency to reduce server load, and de-duplicate
 * identical in-flight content requests so the same body is never fetched twice
 * by sync, the visible-window prefetcher and the reader at the same time.
 */

/** Hard cap for parallel network tasks. Gentle on self-hosted servers. */
export const SYNC_CONCURRENCY: number = 3;

/** First-screen article count on a fresh install: one visible screen plus the
 *  prefetcher's buffer. Only this many bodies are fetched before the UI is
 *  declared ready; the rest of the library is filled in silently afterwards. */
export const UI_WINDOW_SIZE: number = 20;

/** Run `worker` over `items` with at most `limit` tasks in flight. Items are
 *  claimed synchronously before each await, so no two workers take the same
 *  item. Used by every protocol's content-fetch phase. */
export async function forEachLimited<T>(
  items: T[], worker: (item: T) => Promise<void>, limit: number = SYNC_CONCURRENCY
): Promise<void> {
  if (items.length === 0) {
    return;
  }
  let next: number = 0;
  const run = async (): Promise<void> => {
    while (next < items.length) {
      const item: T = items[next++];
      await worker(item);
    }
  };
  const workers: Promise<void>[] = [];
  const count: number = Math.min(limit, items.length);
  for (let i: number = 0; i < count; i++) {
    workers.push(run());
  }
  await Promise.all(workers);
}

/** De-duplicates identical content requests that are still in flight. */
export class ContentInFlight {
  private tasks: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  /** Run `action` once for a given key while its promise is pending. Later
   *  callers with the same key share the result. */
  run(key: string, action: () => Promise<string>): Promise<string> {
    const existing: Promise<string> | undefined = this.tasks.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<string> = action();
    this.tasks.set(key, task);
    const clear = (): void => { this.tasks.delete(key); };
    task.then(clear, clear);
    return task;
  }
}

/** RSS-server article body (`Article.content`). Key: article id. */
export const articleBodyInFlight: ContentInFlight = new ContentInFlight();
/** Original-page extraction (`Article.fullContent`). Key: article id. */
export const fullContentInFlight: ContentInFlight = new ContentInFlight();
