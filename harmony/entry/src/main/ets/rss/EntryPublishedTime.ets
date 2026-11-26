/**
 * Pure, testable derivation of an article's published timestamp from a remote
 * feed entry. Extracted from MinifluxSyncService so the "time must match the
 * GReader/server ordering" invariant can be unit-tested.
 *
 * GReader returns `published` as Unix SECONDS and the port multiplies by 1000.
 * Miniflux returns `published_at` as an RFC3339 string — but some compatible
 * servers / proxies emit a numeric timestamp (often seconds) instead. Feeding
 * seconds to `new Date()` yields a 1970 date, which drops the article to the
 * bottom of the list (findable under its feed, missing from the top of the
 * global unread list). Conversely an unparseable value silently falls back to
 * "now", which pins the article at the top. Both break ordering parity.
 */

/** Device clocks are often behind the server by minutes or hours. Clamping a
 *  genuinely newer article to device `now` rewrites its time to the sync
 *  moment, which differs between interfaces and breaks list ordering. Only
 *  discard timestamps absurdly far in the future. */
const MAX_FUTURE_SKEW_MS: number = 24 * 60 * 60 * 1000;

/** Parse a remote published value into epoch ms. `nowMs` clamps far-future values. */
export function parseEntryPublishedAt(
  raw: string | number | undefined,
  fallbackMs: number,
  nowMs: number
): number {
  if (raw === undefined || raw === null) {
    return clampPublished(fallbackMs, nowMs);
  }
  let ms: number;
  if (typeof raw === 'number') {
    ms = raw < 1e11 ? raw * 1000 : raw;
  } else {
    const text: string = raw.trim();
    if (/^\d+$/.test(text)) {
      const numeric: number = Number(text);
      ms = numeric < 1e11 ? numeric * 1000 : numeric;
    } else {
      ms = new Date(text).getTime();
    }
  }
  if (!Number.isFinite(ms)) {
    return clampPublished(fallbackMs, nowMs);
  }
  return clampPublished(ms, nowMs);
}

/** GReader parity helper: Unix seconds -> epoch ms, same future clamp. */
export function gReaderPublishedAt(seconds: number | undefined, nowMs: number): number {
  const ms: number = seconds === undefined ? nowMs : seconds * 1000;
  return clampPublished(ms, nowMs);
}

function clampPublished(ms: number, nowMs: number): number {
  if (!Number.isFinite(ms)) {
    return nowMs;
  }
  return ms > nowMs + MAX_FUTURE_SKEW_MS ? nowMs : ms;
}
