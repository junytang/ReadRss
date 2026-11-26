/**
 * Pure model for deriving read/star state of articles fetched from a
 * Google-Reader-compatible server. Extracted from the sync service so the
 * cross-client convergence rule is unit-testable without DB/network.
 *
 * Android (GoogleReaderRssService.kt) derives unread solely from the
 * authoritative unread-ID set, never from `item.categories`. Some servers
 * omit the read tag in item categories, so trusting categories inserted
 * articles another client had already read as unread — the first refresh
 * showed a stale count and only the second converged. The authoritative
 * unread/star ID streams are complete, so they always win when available.
 */

export interface RemoteItemStateInput {
  id: string;
  categories?: string[];
}

export interface ResolvedRemoteState {
  isRead: boolean;
  isStarred: boolean;
}

/**
 * Resolve one item's local flags.
 *
 * - When the authoritative streams are complete, `unreadSet`/`starredSet`
 *   are the only source of truth: an id absent from unreadSet is read.
 * - When a stream was truncated, its set is partial, so absence proves
 *   nothing. Fall back to the item's tags, then (for read) to the positively
 *   observed recent-read ids. Unknown items stay unread rather than being
 *   silently hidden.
 */
export function resolveRemoteItemState(
  item: RemoteItemStateInput,
  authoritativeRead: boolean,
  authoritativeStar: boolean,
  unreadSet: Set<string>,
  starredSet: Set<string>,
  recentReadSet: Set<string>,
  readTag: string,
  starredTag: string
): ResolvedRemoteState {
  const hasCategories: boolean = item.categories !== undefined && item.categories.length > 0;
  const isRead: boolean = authoritativeRead
    ? !unreadSet.has(item.id)
    : (hasCategories
      ? item.categories!.indexOf(readTag) >= 0
      : recentReadSet.has(item.id));
  const isStarred: boolean = authoritativeStar
    ? starredSet.has(item.id)
    : (hasCategories ? item.categories!.indexOf(starredTag) >= 0 : false);
  return { isRead: isRead, isStarred: isStarred };
}

/** Ids whose BODIES a sync should fetch. Only unread + starred (authoritative
 *  state sets) — never the `ot` read stream. Fetching read bodies on a fresh
 *  sync stored thousands of already-read articles at once and made the sync
 *  take minutes; read bodies are loaded on demand when opened. */
export function selectContentFetchIds(
  knownIds: Set<string>, unreadIds: string[], starredIds: string[], readIds: string[]
): string[] {
  const seen: Set<string> = new Set<string>(knownIds);
  const result: string[] = [];
  for (const id of unreadIds) {
    if (!seen.has(id)) {
      seen.add(id);
      result.push(id);
    }
  }
  for (const id of starredIds) {
    if (!seen.has(id)) {
      seen.add(id);
      result.push(id);
    }
  }
  // readIds are intentionally ignored.
  return result;
}

/** Reconcile locally stored rows against the authoritative sets. Returns the
 *  id groups to update. Pending local marks are skipped so the server's stale
 *  view cannot revert a just-changed state. */
export interface StateReconciliation {
  toRead: string[];
  toUnread: string[];
  toStar: string[];
  toUnstar: string[];
}

export interface LocalRowState {
  /** Local DB primary key (e.g. "1|abc"). Goes into the update arrays. */
  localId: string;
  /** Remote short id (e.g. "abc"). Compared against the authoritative sets. */
  remoteId: string;
  isRead: boolean;
  isStarred: boolean;
}

export function reconcileRemoteStates(
  local: LocalRowState[],
  unreadSet: Set<string>,
  starredSet: Set<string>,
  pendingLocalIds: Set<string>,
  reconcileRead: boolean,
  reconcileStar: boolean
): StateReconciliation {
  const result: StateReconciliation = {
    toRead: [], toUnread: [], toStar: [], toUnstar: [],
  };
  for (const row of local) {
    if (pendingLocalIds.has(row.localId)) {
      continue;
    }
    if (reconcileRead) {
      if (row.isRead && unreadSet.has(row.remoteId)) {
        result.toUnread.push(row.localId);
      } else if (!row.isRead && !unreadSet.has(row.remoteId)) {
        result.toRead.push(row.localId);
      }
    }
    if (reconcileStar) {
      if (!row.isStarred && starredSet.has(row.remoteId)) {
        result.toStar.push(row.localId);
      } else if (row.isStarred && !starredSet.has(row.remoteId)) {
        result.toUnstar.push(row.localId);
      }
    }
  }
  return result;
}
