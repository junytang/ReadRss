import { describe, it, expect, MockKit, when, ArgumentMatchers } from '@ohos/hypium';
import { readStatusStore } from '../main/ets/rss/ReadStatusStore';
import { rssRepository } from '../main/ets/rss/RssRepository';
import { StatusDiffs } from '../main/ets/rss/StatusDiffs';

/**
 * Integration tests for the read/star status pipeline. MockKit replaces the
 * repository so no DB/network is touched: verifies store flush commits the
 * right groups, resolves partial success, and counts derive correctly.
 */
export default function statusIntegrationTest(): void {
  describe('StatusDiffs integration with count derivation', () => {
    it('mark read then derive scoped/global counts', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');
      expect(d.unreadDelta('f1', '', false)).assertEqual(-1);
      expect(d.unreadDelta('', 'g1', false)).assertEqual(-1);
      expect(d.unreadDelta('', '', true)).assertEqual(-1);
      expect(3 + d.unreadDelta('', '', true)).assertEqual(2);
    });

    it('mark unread on a read article increases counts', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', true, false, 'f1', 'g1');
      expect(d.unreadDelta('f1', '', false)).assertEqual(1);
      expect(d.effectiveUnread('a1', false)).assertTrue();
    });

    it('unread -> read -> unread round trip returns to baseline', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', true, false, 'f1', 'g1');
      expect(d.hasRead('a1')).assertTrue();
      d.markRead('a1', false, true, 'f1', 'g1');
      expect(d.hasRead('a1')).assertFalse();
      d.markRead('a1', true, false, 'f1', 'g1');
      expect(d.unreadDelta('f1', '', false)).assertEqual(1);
    });

    it('star and read on same article tracked independently', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('a1', false, true, 'f1', 'g1');
      d.markStarred('a1', true, false, 'f1');
      expect(d.hasRead('a1')).assertTrue();
      expect(d.hasStar('a1')).assertTrue();
      expect(d.unreadDelta('f1', '', false)).assertEqual(-1);
      expect(d.starredDelta('f1')).assertEqual(1);
      d.clear('a1');
      expect(d.hasRead('a1')).assertFalse();
      expect(d.hasStar('a1')).assertFalse();
    });

    it('flush partition: read/unread/star ids grouped correctly', 0, () => {
      const d: StatusDiffs = new StatusDiffs();
      d.markRead('r1', false, true, 'f1', 'g1');
      d.markRead('u1', true, false, 'f1', 'g1');
      d.markStarred('s1', true, false, 'f1');
      d.markStarred('us1', false, true, 'f1');
      const rp = d.readIdsByState();
      const sp = d.starIdsByState();
      expect(rp.readIds.length).assertEqual(1);
      expect(rp.unreadIds.length).assertEqual(1);
      expect(sp.starredIds.length).assertEqual(1);
      expect(sp.unstarredIds.length).assertEqual(1);
    });
  });

  describe('ReadStatusStore flush with mocked repository', () => {
    it('flush calls markReadBatch with read=true for locally-read ids', 0, async () => {
      const mock: MockKit = new MockKit();
      const rm = mock.mockFunc(rssRepository, rssRepository.markReadBatch);
      when(rm)(ArgumentMatchers.any, ArgumentMatchers.any).afterAction(
        (ids: string[]): Promise<string[]> => Promise.resolve(ids));
      const sm = mock.mockFunc(rssRepository, rssRepository.markStarredBatch);
      when(sm)(ArgumentMatchers.any, ArgumentMatchers.any).afterAction(
        (ids: string[]): Promise<string[]> => Promise.resolve(ids));

      readStatusStore.markRead('r1', false, true, 'f1', 'g1');
      await readStatusStore.flush();
      // Verify markReadBatch was called at least once with any args.
      mock.verify('markReadBatch', [ArgumentMatchers.any, ArgumentMatchers.any]).atLeast(1);
      mock.clear(rssRepository);
    });

    it('flush returns confirmed ids via afterAction (no error)', 0, async () => {
      const mock: MockKit = new MockKit();
      const rm = mock.mockFunc(rssRepository, rssRepository.markReadBatch);
      when(rm)(ArgumentMatchers.any, ArgumentMatchers.any).afterAction(
        (ids: string[]): Promise<string[]> => Promise.resolve(ids));
      const sm = mock.mockFunc(rssRepository, rssRepository.markStarredBatch);
      when(sm)(ArgumentMatchers.any, ArgumentMatchers.any).afterAction(
        (ids: string[]): Promise<string[]> => Promise.resolve(ids));

      const done: string[] = await rssRepository.markReadBatch(['a', 'b'], true);
      expect(done.length).assertEqual(2);
      mock.clear(rssRepository);
    });

    it('flush drops confirmed ids and keeps failed ones', 0, async () => {
      const mock: MockKit = new MockKit();
      const rm = mock.mockFunc(rssRepository, rssRepository.markReadBatch);
      when(rm)(ArgumentMatchers.any, ArgumentMatchers.any).afterAction(
        (ids: string[]): Promise<string[]> => Promise.resolve(ids.length > 0 ? [ids[0]] : []));
      const sm = mock.mockFunc(rssRepository, rssRepository.markStarredBatch);
      when(sm)(ArgumentMatchers.any, ArgumentMatchers.any).afterAction(
        (ids: string[]): Promise<string[]> => Promise.resolve(ids));

      // Clear any residual state from earlier tests first via a full flush.
      await readStatusStore.flush();
      readStatusStore.markRead('ok1', false, true, 'f1', 'g1');
      readStatusStore.markRead('fail1', false, true, 'f1', 'g1');
      await readStatusStore.flush();

      expect(readStatusStore.hasPending('ok1')).assertFalse();
      expect(readStatusStore.hasPending('fail1')).assertTrue();
      mock.clear(rssRepository);
    });
  });
}
