import { describe, it, expect, MockKit, when } from '@ohos/hypium';
import { MinifluxSyncService } from '../main/ets/rss/MinifluxSyncService';
import {
  MinifluxApi, MinifluxEntryParams, MinifluxEntry, iconDataUrl, isUnsupportedStarFieldError,
} from '../main/ets/rss/MinifluxApi';
import { database } from '../main/ets/data/Database';
import { Account, AccountType, dbId } from '../main/ets/account/AccountModels';

interface ApiAccess { entryQuery(params: MinifluxEntryParams): string; }
interface ApiInternals { basic: string; token: string; baseUrl: string; }
interface ServiceAccess { lastMaxEntryId(account: Account): number; }
interface StreamAccess {
  bodyFetchStreams(idsAvailable: boolean, lastMaxId: number, freshSync: boolean): MinifluxEntryParams[];
}

function account(): Account {
  const a: Account = {
    id: '1', name: 'a', type: AccountType.MINIFLUX, securityKey: '',
    updateAt: 0, lastArticleId: null, syncInterval: 30, syncOnStart: false,
    syncOnlyOnWiFi: false, syncOnlyWhenCharging: false, keepArchived: 2592000000,
    syncBlockList: '',
  };
  return a;
}

export default function minifluxTest(): void {
  describe('MinifluxSyncService fast paths', () => {
    it('accepts MINIFLUX accounts; rejects other types', 0, async () => {
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const other = account();
      other.type = AccountType.FEVER;
      let threw: boolean = false;
      try {
        await svc.sync(other);
      } catch (error) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('empty batches are no-ops', 0, async () => {
      const svc: MinifluxSyncService = new MinifluxSyncService();
      expect((await svc.markRead(account(), [], true)).length).assertEqual(0);
      expect((await svc.markStarredBatch(account(), [], true)).length).assertEqual(0);
    });
  });

  describe('MinifluxSyncService.markRead with mocks', () => {
    it('confirms ids and writes DB when remote succeeds', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '10'), dbId('1', '11')];
      const fakeApi: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const remotes: number[] = [10, 11];
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const numbersFn = mock.mockPrivateFunc(svc, 'remoteNumbers');
      when(numbersFn)(ids).afterReturn(remotes);
      const updateMock = mock.mockFunc(fakeApi, fakeApi.updateEntries);
      when(updateMock)(remotes, 'read', undefined)
        .afterAction((): Promise<void> => Promise.resolve());
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, true, undefined).afterAction((): Promise<void> => Promise.resolve());

      const result: string[] = await svc.markRead(a, ids, true);
      expect(result.length).assertEqual(2);
      mock.verify('setStates', [ids, true, undefined]).once();
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });

    it('returns no confirmed ids when remote fails', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '12')];
      const fakeApi: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const remotes: number[] = [12];
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const numbersFn = mock.mockPrivateFunc(svc, 'remoteNumbers');
      when(numbersFn)(ids).afterReturn(remotes);
      const updateMock = mock.mockFunc(fakeApi, fakeApi.updateEntries);
      when(updateMock)(remotes, 'unread', undefined).afterThrow('network down');
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, false, undefined).afterAction((): Promise<void> => Promise.resolve());

      expect((await svc.markRead(a, ids, false)).length).assertEqual(0);
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });
  });

  describe('MinifluxSyncService.markStarredBatch fallback', () => {
    it('does not toggle bookmarks on auth/network errors', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '20')];
      const fakeApi: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const numbersFn = mock.mockPrivateFunc(svc, 'remoteNumbers');
      when(numbersFn)(ids).afterReturn([20]);
      const updateMock = mock.mockFunc(fakeApi, fakeApi.updateEntries);
      when(updateMock)([20], undefined, true).afterThrow('Miniflux HTTP 401');
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, undefined, true).afterAction((): Promise<void> => Promise.resolve());

      const result: string[] = await svc.markStarredBatch(a, ids, true);
      expect(result.length).assertEqual(0);
      mock.verify('toggleBookmark', [20]).never();
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });

    it('reads current state before toggling on unsupported-field error', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '21')];
      const fakeApi: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const numbersFn = mock.mockPrivateFunc(svc, 'remoteNumbers');
      when(numbersFn)(ids).afterReturn([21]);
      const updateMock = mock.mockFunc(fakeApi, fakeApi.updateEntries);
      when(updateMock)([21], undefined, true).afterThrow('Miniflux HTTP 400: starred field unsupported');
      const entry: MinifluxEntry = { id: 21, starred: false };
      const getMock = mock.mockFunc(fakeApi, fakeApi.getEntry);
      when(getMock)(21).afterReturn(entry);
      const toggleMock = mock.mockFunc(fakeApi, fakeApi.toggleBookmark);
      when(toggleMock)(21).afterAction((): Promise<void> => Promise.resolve());
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, undefined, true).afterAction((): Promise<void> => Promise.resolve());

      const result: string[] = await svc.markStarredBatch(a, ids, true);
      expect(result.length).assertEqual(1);
      mock.verify('toggleBookmark', [21]).once();
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });
  });

  describe('MinifluxApi query building', () => {
    it('builds entry query filters', 0, () => {
      const api: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const access = api as object as ApiAccess;
      const query: string = access.entryQuery({
        status: 'unread', starred: false, offset: 20, limit: 50,
        order: 'id', direction: 'desc', after: 123,
      });
      expect(query.indexOf('status=unread') >= 0).assertTrue();
      expect(query.indexOf('starred=false') >= 0).assertTrue();
      expect(query.indexOf('offset=20') >= 0).assertTrue();
      expect(query.indexOf('limit=50') >= 0).assertTrue();
      expect(query.indexOf('after=123') >= 0).assertTrue();
    });

    it('builds cursor paging for the newest-first body fetch', 0, () => {
      const api: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const first: string = (api as object as ApiAccess).entryQuery({
        afterEntryId: 456, limit: 100, order: 'id', direction: 'desc',
      });
      expect(first.indexOf('after_entry_id=456') >= 0).assertTrue();
      expect(first.indexOf('order=id') >= 0).assertTrue();
      expect(first.indexOf('direction=desc') >= 0).assertTrue();
      expect(first.indexOf('before_entry_id=') >= 0).assertFalse();
      expect(first.indexOf('offset=') >= 0).assertFalse();

      // Later pages keep the lower bound fixed and walk the upper bound down.
      const next: string = (api as object as ApiAccess).entryQuery({
        afterEntryId: 456, beforeEntryId: 500, limit: 100, order: 'id', direction: 'desc',
      });
      expect(next.indexOf('after_entry_id=456') >= 0).assertTrue();
      expect(next.indexOf('before_entry_id=500') >= 0).assertTrue();
    });
  });

  describe('MinifluxSyncService incremental cursor', () => {
    it('reads last max entry id from the stored high-water mark', 0, () => {
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const access = svc as object as ServiceAccess;
      const a: Account = account();
      a.lastArticleId = dbId('1', '456');
      expect(access.lastMaxEntryId(a)).assertEqual(456);
      a.lastArticleId = null;
      expect(access.lastMaxEntryId(a)).assertEqual(0);
    });

    it('builds data URIs with the server MIME type', 0, () => {
      expect(iconDataUrl('image/jpeg;base64,AAA', 'image/jpeg'))
        .assertEqual('data:image/jpeg;base64,AAA');
      expect(iconDataUrl('AAA', undefined)).assertEqual('data:image/png;base64,AAA');
      expect(iconDataUrl('data:image/png;base64,AAA', 'image/jpeg'))
        .assertEqual('data:image/png;base64,AAA');
    });

    it('only treats 400 starred-field errors as fallback-worthy', 0, () => {
      expect(isUnsupportedStarFieldError('Miniflux HTTP 400: unknown field starred')).assertTrue();
      expect(isUnsupportedStarFieldError('Miniflux HTTP 401')).assertFalse();
      expect(isUnsupportedStarFieldError('Miniflux HTTP 500')).assertFalse();
      expect(isUnsupportedStarFieldError('network down')).assertFalse();
    });

    it('uses Basic auth for username/password and X-Auth-Token for a token', 0, () => {
      const basicApi = new MinifluxApi('https://x/v1/', 'user', 'pass');
      const basic = basicApi as object as ApiInternals;
      expect(basic.basic.length > 0).assertTrue();
      expect(basic.token.length).assertEqual(0);
      expect(basic.baseUrl).assertEqual('https://x');

      const tokenApi = new MinifluxApi('https://x', 'secret-token', '');
      const token = tokenApi as object as ApiInternals;
      expect(token.basic.length).assertEqual(0);
      expect(token.token).assertEqual('secret-token');
    });
  });

  describe('MinifluxSyncService cross-client content preservation', () => {
    it('fetches bodies unfiltered from the cursor so another client\'s read is not lost', 0, () => {
      const svc: MinifluxSyncService = new MinifluxSyncService();
      const access = svc as object as StreamAccess;
      // Modern server with /entries/ids: a single unfiltered stream from the
      // last high-water mark. An entry read (but not starred) by another client
      // is in neither the unread nor starred stream — an unfiltered fetch is
      // the only way to store its body.
      const streams: MinifluxEntryParams[] = access.bodyFetchStreams(true, 100, false);
      expect(streams.length).assertEqual(1);
      expect(streams[0].afterEntryId).assertEqual(100);
      expect(streams[0].status).assertUndefined();
      expect(streams[0].starred).assertUndefined();

      // Fresh sync (no cursor): fetching every read entry's full HTML would
      // timeout on a large account, so only unread + starred bodies are pulled.
      const fresh: MinifluxEntryParams[] = access.bodyFetchStreams(true, 0, true);
      expect(fresh.length).assertEqual(2);
      expect(fresh[0].status).assertEqual('unread');
      expect(fresh[0].afterEntryId).assertEqual(0);
      expect(fresh[1].starred).assertTrue();

      // Legacy server: state sets come from full unread/starred streams, but
      // the unfiltered incremental stream is still present for cross-client
      // read entries.
      const legacy: MinifluxEntryParams[] = access.bodyFetchStreams(false, 100, false);
      expect(legacy.length).assertEqual(3);
      expect(legacy[0].status).assertEqual('unread');
      expect(legacy[0].afterEntryId).assertEqual(0);
      expect(legacy[1].starred).assertTrue();
      expect(legacy[2].afterEntryId).assertEqual(100);
      expect(legacy[2].status).assertUndefined();
      expect(legacy[2].starred).assertUndefined();
    });
  });
}
