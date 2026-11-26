import { Logger } from '../common/Logger';

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

/** Called once when the whole sync finishes (success or failure), by
 *  RssRepository.doSync()'s finally block. Guarantees the spinner stops and
 *  the list gets a final reload with every committed batch, even when no new
 *  article was committed or the sync failed before the first batch. */
export function notifySyncFinal(succeeded: boolean = true, failedCount: number = 0): void {
  const now: number = Date.now();
  signalFirstBatch(now);
  lastNotify = now;
  AppStorage.setOrCreate<number>('feedDataTick', now);
  AppStorage.setOrCreate<boolean>('syncFinishedOk', succeeded);
  AppStorage.setOrCreate<number>('syncFailedCount', failedCount);
  AppStorage.setOrCreate<number>('syncFinishedTick', now);
}

/**
 * One-shot UI readiness signal shared by all protocols. Fired as soon as the
 * first article batch (the visible window + buffer) is committed: the spinner
 * stops and the first batch is loaded immediately. It deliberately does NOT
 * emit syncFinishedTick — that signal now belongs to the real end of sync,
 * so later batches and state reconciliation are always reflected in the list.
 */
export class UiReadySignal {
  private fired: boolean = false;
  private start: number;

  constructor(startTime: number) {
    this.start = startTime;
  }

  fire(): void {
    if (this.fired) {
      return;
    }
    this.fired = true;
    // Time-to-UI: the moment the first article batch is usable. Later batches
    // and reconciliation continue silently; the final reload is driven by
    // notifySyncFinal() at the real end of sync.
    Logger.info(`UI ready after ${Date.now() - this.start}ms`);
    signalFirstBatch(Date.now());
  }
}
