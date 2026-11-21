/** Minimum interval between UI progress notifications, in milliseconds.
 *  Prevents a storm of full list reloads when many small batches are inserted. */
const NOTIFY_INTERVAL_MS: number = 800;
let lastNotify: number = 0;
let firstBatchNotified: boolean = false;

/** Reset progress state at the start of a sync so its first batch always
 *  notifies the UI immediately, even if a previous sync just finished. */
export function beginSync(): void {
  lastNotify = 0;
  firstBatchNotified = false;
}

/** Signal that the first content batch is committed: the pull-to-refresh
 *  spinner can stop here so the user is not kept waiting for background work. */
function signalFirstBatch(now: number): void {
  if (!firstBatchNotified) {
    firstBatchNotified = true;
    AppStorage.setOrCreate<number>('syncFirstBatchTick', now);
  }
}

/**
 * Called after each content batch is inserted. Refreshes unread badges (throttled)
 * and stops the refresh spinner on the very first batch.
 */
export function notifySyncBatch(): void {
  const now: number = Date.now();
  signalFirstBatch(now);
  if (now - lastNotify >= NOTIFY_INTERVAL_MS) {
    lastNotify = now;
    AppStorage.setOrCreate<number>('feedDataTick', now);
  }
}

/** Called when the content fetch/insert phase is complete, regardless of whether
 *  any new article was committed. The readable content is ready at this point, so
 *  the spinner can stop without waiting for the slower reconciliation phase. */
export function notifyContentReady(): void {
  signalFirstBatch(Date.now());
}

/** Called when a sync finishes. Guarantees the spinner stops even when no new
 *  article batch was ever committed (e.g. everything is already up to date). */
export function notifySyncFinal(): void {
  const now: number = Date.now();
  signalFirstBatch(now);
  lastNotify = now;
  AppStorage.setOrCreate<number>('feedDataTick', now);
  // Separate signal: a full sync finished, so the article list should reload
  // with everything committed so far (e.g. first-install sync started from the
  // EntryAbility, which has no page-level sync() to do a final load itself).
  AppStorage.setOrCreate<number>('syncFinishedTick', now);
}
