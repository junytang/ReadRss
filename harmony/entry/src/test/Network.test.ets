import { describe, it, expect, MockKit, when } from '@ohos/hypium';
import { GoogleReaderSyncService } from '../main/ets/rss/GoogleReaderSyncService';
import { GoogleReaderApi, ApiParams, ItemIdsDto } from '../main/ets/rss/GoogleReaderApi';
import { Account, AccountType } from '../main/ets/account/AccountModels';
import { SyncResult, emptySyncResult } from '../main/ets/rss/SyncService';

interface AllIdsAccess {
  allItemIds(api: GoogleReaderApi, base: ApiParams, maxPages: number): Promise<string[]>;
}
interface ChunksAccess {
  chunks<T>(items: T[], size: number): Promise<T[][]>;
}

function account(type: AccountType): Account {
  const a: Account = {
    id: '1', name: 'a', type: type, securityKey: '', updateAt: 0, lastArticleId: null,
    syncInterval: 30, syncOnStart: false, syncOnlyOnWiFi: false, syncOnlyWhenCharging: false,
    keepArchived: 2592000000, syncBlockList: '',
  };
  return a;
}

export default function networkTest(): void {
  describe('GoogleReaderSyncService sync guards', () => {
    it('sync rejects invalid account type', 0, async () => {
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      let threw: boolean = false;
      try {
        await svc.sync(account(AccountType.LOCAL));
      } catch (error) {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });

  describe('allItemIds pagination with mocked network', () => {
    it('collects ids across continuation pages', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      const fakeApi: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const base: ApiParams = { s: 'feed/abc', xt: 'read', n: '1000' };

      // getItemIds called with base params (page 1, no c), then with c='cont1' (page 2).
      const p1: ApiParams = { s: base.s, xt: base.xt, it: undefined, ot: undefined, n: base.n, quickadd: undefined };
      const p2: ApiParams = { s: base.s, xt: base.xt, it: undefined, ot: undefined, n: base.n, quickadd: undefined, c: 'cont1' };
      const gi = mock.mockFunc(fakeApi, fakeApi.getItemIds);
      const page1: ItemIdsDto = { itemRefs: [{ id: '1' }, { id: '2' }], continuation: 'cont1' };
      const page2: ItemIdsDto = { itemRefs: [{ id: '3' }] };
      when(gi)(p1).afterReturn(Promise.resolve(page1));
      when(gi)(p2).afterReturn(Promise.resolve(page2));

      const access = svc as object as AllIdsAccess;
      // maxPages large; no stub for other params -> real method would hit network,
      // but the two pages above cover all calls.
      const ids: string[] = await access.allItemIds(fakeApi, base, 10);
      expect(ids.length).assertEqual(3);
      expect(ids[0]).assertEqual('1');
      expect(ids[2]).assertEqual('3');
      mock.clear(fakeApi);
    });

    it('stops at maxPages limit', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      const fakeApi: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const base: ApiParams = { s: 's', n: '1' };
      const p: ApiParams = { s: base.s, xt: undefined, it: undefined, ot: undefined, n: base.n, quickadd: undefined };
      const p2: ApiParams = { s: base.s, xt: undefined, it: undefined, ot: undefined, n: base.n, quickadd: undefined, c: 'next' };
      const gi = mock.mockFunc(fakeApi, fakeApi.getItemIds);
      const page: ItemIdsDto = { itemRefs: [{ id: 'a' }, { id: 'b' }], continuation: 'next' };
      when(gi)(p).afterReturn(Promise.resolve(page));
      when(gi)(p2).afterReturn(Promise.resolve(page));
      const access = svc as object as AllIdsAccess;
      const ids: string[] = await access.allItemIds(fakeApi, base, 2);
      // 2 pages max, each returns 2 ids -> 4.
      expect(ids.length).assertEqual(4);
      mock.clear(fakeApi);
    });
  });

  describe('chunks batching', () => {
    it('splits into fixed-size batches', 0, async () => {
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(svc, 'chunks');
      const access = svc as object as ChunksAccess;
      const result: string[][] = await access.chunks<string>(['1', '2', '3', '4', '5'], 2);
      expect(result.length).assertEqual(3);
      expect(result[0].length).assertEqual(2);
      expect(result[2].length).assertEqual(1);
      mock.clear(svc);
    });
  });
}
