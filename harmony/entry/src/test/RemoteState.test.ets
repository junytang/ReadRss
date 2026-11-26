import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRemoteItemState, reconcileRemoteStates, selectContentFetchIds,
  LocalRowState, StateReconciliation,
} from '../main/ets/rss/RemoteStateResolver';

const READ_TAG: string = 'user/-/state/com.google/read';
const STARRED_TAG: string = 'user/-/state/com.google/starred';
const READING_LIST: string = 'user/-/state/com.google/reading-list';

function ids(prefix: string, count: number): string[] {
  const result: string[] = [];
  for (let i: number = 0; i < count; i++) {
    result.push(`${prefix}${i}`);
  }
  return result;
}

/**
 * Deterministic in-memory model of the two-client scenario:
 * A read everything; B marked 100 of the newly arrived articles read; the
 * server now has 100 read + 50 unread. The sync must converge in ONE pass.
 */
export default function remoteStateTest(): void {
  describe('GReader insert state - authoritative sets win over categories', () => {
    it('first sync converges to 50 unread, not 150', 0, () => {
      const readByB: string[] = ids('r', 100);
      const unread: string[] = ids('u', 50);
      const unreadSet: Set<string> = new Set<string>(unread);
      const starredSet: Set<string> = new Set<string>();
      const recentReadSet: Set<string> = new Set<string>();
      // Every item carries only the reading-list tag — no read tag.
      let unreadInserted: number = 0;
      for (const id of readByB.concat(unread)) {
        const state = resolveRemoteItemState(
          { id: id, categories: [READING_LIST] },
          true, true, unreadSet, starredSet, recentReadSet, READ_TAG, STARRED_TAG
        );
        if (!state.isRead) {
          unreadInserted++;
        }
      }
      expect(unreadInserted).assertEqual(50);
    });

    it('an id absent from the complete unread set is inserted read', 0, () => {
      const unreadSet: Set<string> = new Set<string>(['u1']);
      const state = resolveRemoteItemState(
        { id: 'r1', categories: [READING_LIST] },
        true, true, unreadSet, new Set<string>(), new Set<string>(), READ_TAG, STARRED_TAG
      );
      expect(state.isRead).assertTrue();
    });

    it('authoritative unread set overrides a misleading read tag', 0, () => {
      // Android parity: unreadIds.contains(id) decides, not item.categories.
      const unreadSet: Set<string> = new Set<string>(['u1']);
      const state = resolveRemoteItemState(
        { id: 'u1', categories: [READ_TAG] },
        true, true, unreadSet, new Set<string>(), new Set<string>(), READ_TAG, STARRED_TAG
      );
      expect(state.isRead).assertFalse();
    });

    it('truncated read stream never mass-marks read on absence', 0, () => {
      // Partial set: unknown ids must stay unread rather than be hidden.
      const state = resolveRemoteItemState(
        { id: 'unknown', categories: [READING_LIST] },
        false, true, new Set<string>(), new Set<string>(), new Set<string>(),
        READ_TAG, STARRED_TAG
      );
      expect(state.isRead).assertFalse();
      const positivelyRead = resolveRemoteItemState(
        { id: 'known' },
        false, true, new Set<string>(), new Set<string>(), new Set<string>(['known']),
        READ_TAG, STARRED_TAG
      );
      expect(positivelyRead.isRead).assertTrue();
    });

    it('star state also derives from the authoritative set', 0, () => {
      const starredSet: Set<string> = new Set<string>(['s1']);
      const state = resolveRemoteItemState(
        { id: 's1', categories: [READING_LIST] },
        true, true, new Set<string>(['s1']), starredSet, new Set<string>(),
        READ_TAG, STARRED_TAG
      );
      expect(state.isStarred).assertTrue();
    });
  });

  describe('Content fetch set stays small', () => {
    it('read ids are never fetched; only new unread/starred are', 0, () => {
      const known: Set<string> = new Set<string>(['u-old']);
      const result: string[] = selectContentFetchIds(
        known, ['u1', 'u2', 'u-old'], ['s1'], ids('r', 3000)
      );
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual('u1');
      expect(result[1]).assertEqual('u2');
      expect(result[2]).assertEqual('s1');
      expect(result.indexOf('r0') < 0).assertTrue();
    });

    it('already stored ids are deduped', 0, () => {
      const result: string[] = selectContentFetchIds(
        new Set<string>(['u1']), ['u1', 'u2'], ['u2', 'u3'], []
      );
      expect(result.length).assertEqual(2);
      expect(result[0]).assertEqual('u2');
      expect(result[1]).assertEqual('u3');
    });
  });

  describe('Post-insert reconciliation converges stale rows in one pass', () => {
    it('marks the 100 stale rows read, converging to 50 unread', 0, () => {
      const readByB: string[] = ids('r', 100);
      const unread: string[] = ids('u', 50);
      const unreadSet: Set<string> = new Set<string>(unread);
      const local: LocalRowState[] = readByB.concat(unread).map(
        (id: string): LocalRowState => ({
          localId: `1|${id}`, remoteId: id, isRead: false, isStarred: false,
        })
      );
      const diff: StateReconciliation = reconcileRemoteStates(
        local, unreadSet, new Set<string>(), new Set<string>(), true, true
      );
      expect(diff.toRead.length).assertEqual(100);
      expect(diff.toUnread.length).assertEqual(0);
      // Applying toRead once leaves exactly the 50 authoritative unread ids.
      const readIds: Set<string> = new Set<string>(diff.toRead);
      let unreadAfter: number = 0;
      for (const row of local) {
        if (!readIds.has(row.localId)) {
          unreadAfter++;
        }
      }
      expect(unreadAfter).assertEqual(50);
    });

    it('compares remote ids but emits local ids', 0, () => {
      // DB primary keys differ from remote ids ("1|r1" vs "r1"). A mismatch
      // here would reconcile nothing / everything and break the convergence.
      const local: LocalRowState[] = [
        { localId: '1|r1', remoteId: 'r1', isRead: false, isStarred: false },
        { localId: '1|u1', remoteId: 'u1', isRead: false, isStarred: false },
      ];
      const diff: StateReconciliation = reconcileRemoteStates(
        local, new Set<string>(['u1']), new Set<string>(), new Set<string>(), true, true
      );
      expect(diff.toRead.length).assertEqual(1);
      expect(diff.toRead[0]).assertEqual('1|r1');
      expect(diff.toUnread.length).assertEqual(0);
    });

    it('skips ids with a pending local mark', 0, () => {
      const local: LocalRowState[] = [
        { localId: '1|r1', remoteId: 'r1', isRead: false, isStarred: false },
        { localId: '1|r2', remoteId: 'r2', isRead: false, isStarred: false },
      ];
      const diff: StateReconciliation = reconcileRemoteStates(
        local, new Set<string>(), new Set<string>(), new Set<string>(['1|r1']), true, true
      );
      expect(diff.toRead.length).assertEqual(1);
      expect(diff.toRead[0]).assertEqual('1|r2');
    });

    it('does not emit mass reconciliation from a truncated stream', 0, () => {
      const local: LocalRowState[] = [
        { localId: '1|a', remoteId: 'a', isRead: false, isStarred: false },
      ];
      const diff: StateReconciliation = reconcileRemoteStates(
        local, new Set<string>(), new Set<string>(), new Set<string>(), false, false
      );
      expect(diff.toRead.length).assertEqual(0);
      expect(diff.toStar.length).assertEqual(0);
    });
  });
}
