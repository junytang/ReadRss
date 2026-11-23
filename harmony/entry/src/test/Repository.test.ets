import { describe, it, expect, MockKit, when, ArgumentMatchers } from '@ohos/hypium';
import { rssRepository } from '../main/ets/rss/RssRepository';
import { SyncResult, emptySyncResult } from '../main/ets/rss/SyncService';

/**
 * Repository tests using MockKit: verify the in-flight sync coalescing and
 * delegation without touching DB/network.
 */
export default function repositoryTest(): void {
  describe('RssRepository.syncAll in-flight coalescing', () => {
    it('concurrent syncAll calls share one doSync execution', 0, async () => {
      const mock: MockKit = new MockKit();
      let calls: number = 0;
      // Mock the private doSync to count invocations and resolve asynchronously.
      const ds = mock.mockPrivateFunc(rssRepository, 'doSync');
      when(ds)().afterAction((): Promise<SyncResult> => {
        calls++;
        return new Promise<SyncResult>((resolve: (r: SyncResult) => void): void => {
          setTimeout((): void => {
            const r: SyncResult = emptySyncResult();
            r.succeeded = 1;
            resolve(r);
          }, 30);
        });
      });

      const p1: Promise<SyncResult> = rssRepository.syncAll();
      const p2: Promise<SyncResult> = rssRepository.syncAll();
      const r1: SyncResult = await p1;
      const r2: SyncResult = await p2;

      // Only one underlying doSync ran for two concurrent callers.
      expect(calls).assertEqual(1);
      expect(r1.succeeded).assertEqual(1);
      expect(r2.succeeded).assertEqual(1);
      mock.clear(rssRepository);
    });

    it('sequential syncAll after completion starts a fresh doSync', 0, async () => {
      const mock: MockKit = new MockKit();
      let calls: number = 0;
      const ds = mock.mockPrivateFunc(rssRepository, 'doSync');
      when(ds)().afterAction((): Promise<SyncResult> => {
        calls++;
        return Promise.resolve(emptySyncResult());
      });

      await rssRepository.syncAll();
      await rssRepository.syncAll();
      expect(calls).assertEqual(2);
      mock.clear(rssRepository);
    });
  });
}
