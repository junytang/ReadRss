import { describe, it, expect } from '@ohos/hypium';
import { StatusDiffs, ReadIdPartition } from '../main/ets/rss/StatusDiffs';

export default function storeTest(): void {
  describe('StatusDiffs - mark / derive / cancel', () => {
    it('mark read creates a diff and derives effective state', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      // Article shown unread (dbUnread=true), user marks read (unread=false).
      expect(d.markRead('a1', false, true, 'f1', 'g1')).assertTrue();
      expect(d.effectiveUnread('a1', true)).assertFalse();
      expect(d.hasRead('a1')).assertTrue();
    });

    it('mark read is idempotent when state already matches', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      // dbUnread=false (already read), mark read again -> no diff.
      expect(d.markRead('a1', false, false, 'f1', 'g1')).assertFalse();
      expect(d.hasRead('a1')).assertFalse();
    });

    it('toggling twice cancels the diff back to baseline', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');   // unread -> read
      // Now current unread = false; mark unread (unread=true) -> back to DB.
      expect(d.markRead('a1', true, false, 'f1', 'g1')).assertFalse();
      expect(d.hasRead('a1')).assertFalse();
    });

    it('unreadDelta: -1 for locally-read, +1 for locally-unread', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');   // locally read, DB unread -> -1
      d.markRead('a2', true, false, 'f1', 'g1');   // locally unread, DB read -> +1
      expect(d.unreadDelta('f1', '', false)).assertEqual(0);
      expect(d.unreadDelta('f2', '', false)).assertEqual(0);
      expect(d.unreadDelta('', '', true)).assertEqual(0);
    });

    it('clearAccount removes only one account\'s diffs', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('1|r1', false, true, 'f1', 'g1');
      d.markRead('2|r2', false, true, 'f1', 'g1');
      d.markStarred('1|s1', true, false, 'f1');
      d.markStarred('2|s2', true, false, 'f1');
      d.clearAccount('1');
      expect(d.hasRead('1|r1')).assertFalse();
      expect(d.hasStar('1|s1')).assertFalse();
      expect(d.hasRead('2|r2')).assertTrue();
      expect(d.hasStar('2|s2')).assertTrue();
    });

    it('unreadDelta scoped by feed and group', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');
      d.markRead('a2', false, true, 'f2', 'g2');
      expect(d.unreadDelta('f1', '', false)).assertEqual(-1);
      expect(d.unreadDelta('', 'g2', false)).assertEqual(-1);
      expect(d.unreadDelta('', '', true)).assertEqual(-2);
    });

    it('star diff tracks feedId and starredDelta filters by feed', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markStarred('a1', true, false, 'f1');   // star it
      d.markStarred('a2', true, false, 'f2');
      expect(d.starredDelta('f1')).assertEqual(1);
      expect(d.starredDelta('f2')).assertEqual(1);
      expect(d.starredDelta('')).assertEqual(2);
      expect(d.effectiveStarred('a1', false)).assertTrue();
    });

    it('star toggle twice cancels diff', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markStarred('a1', true, false, 'f1');
      expect(d.markStarred('a1', false, true, 'f1')).assertFalse();
      expect(d.hasStar('a1')).assertFalse();
      expect(d.starredDelta('f1')).assertEqual(0);
    });

    it('partition read ids by state for flush', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('r1', false, true, 'f1', 'g1');
      d.markRead('u1', true, false, 'f1', 'g1');
      const parts: ReadIdPartition = d.readIdsByState();
      expect(parts.readIds.length).assertEqual(1);
      expect(parts.unreadIds.length).assertEqual(1);
      expect(parts.readIds[0]).assertEqual('r1');
      expect(parts.unreadIds[0]).assertEqual('u1');
    });
  });

  describe('StatusDiffs - resolve / retry', () => {
    it('resolve clears confirmed ids and keeps failed ones', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');
      d.markRead('a2', false, true, 'f1', 'g1');
      const highest: number = d.resolve(['a1', 'a2'], ['a1'], 5);
      expect(highest).assertEqual(1);
      expect(d.hasRead('a1')).assertFalse();
      expect(d.hasRead('a2')).assertTrue();
      expect(d.attemptOf('a2')).assertEqual(1);
    });

    it('fail drops id after max attempts', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');
      expect(d.fail('a1', 3)).assertEqual(1);
      expect(d.fail('a1', 3)).assertEqual(2);
      expect(d.fail('a1', 3)).assertEqual(-1);
      expect(d.hasRead('a1')).assertFalse();
    });

    it('allIds contains unique ids across read and star', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');
      d.markStarred('a1', true, false, 'f1');
      d.markStarred('a2', true, false, 'f1');
      expect(d.allIds().length).assertEqual(2);
    });
  });
}
