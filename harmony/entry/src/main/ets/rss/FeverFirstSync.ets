/**
 * First-install scope rule for Fever, matching the GReader optimisation:
 * store bodies only for articles the server reports as unread or starred.
 * Fever's `items_since` endpoint cannot filter by status, so the sync still
 * scans pages but skips read/unstarred items instead of importing thousands
 * of already-read articles on first install.
 */
export function shouldKeepFeverFirstSyncItem(
  id: string, unreadIds: Set<string>, starredIds: Set<string>
): boolean {
  return unreadIds.has(id) || starredIds.has(id);
}

/** Upper bound on pages scanned during a fresh Fever sync (50 items/page). */
export const FEVER_FRESH_MAX_PAGES: number = 30;
