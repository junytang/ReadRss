import { describe, it, expect, MockKit, when, ArgumentMatchers } from '@ohos/hypium';
import { GoogleReaderSyncService } from '../main/ets/rss/GoogleReaderSyncService';
import { GoogleReaderApi } from '../main/ets/rss/GoogleReaderApi';
import { database } from '../main/ets/data/Database';
import { Account, AccountType, dbId, remoteId } from '../main/ets/account/AccountModels';
import { Article } from '../main/ets/model/Models';

function account(): Account {
  const a: Account = {
    id: '1', name: 'a', type: AccountType.GOOGLE_READER, securityKey: '',
    updateAt: 0, lastArticleId: null, syncInterval: 30, syncOnStart: false,
    syncOnlyOnWiFi: false, syncOnlyWhenCharging: false, keepArchived: 2592000000,
    syncBlockList: '',
  };
  return a;
}

/**
 * Service-layer tests using MockKit with EXACT value matchers.
 *
 * IMPORTANT: in this hypium build ArgumentMatchers.any() returns undefined,
 * which breaks multi-argument stubs (the key degenerates to a single anonymous
 * key). Always stub with concrete expected argument values, as done below.
 */
export default function serviceTest(): void {
  describe('GoogleReaderSyncService fast paths', () => {
    it('markRead on empty ids returns []', 0, async () => {
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      expect((await svc.markRead(account(), [], true)).length).assertEqual(0);
    });

    it('markStarredBatch on empty ids returns []', 0, async () => {
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      expect((await svc.markStarredBatch(account(), [], true)).length).assertEqual(0);
    });
  });

  describe('GoogleReaderSyncService.markRead with mocked DB/API', () => {
    it('confirms all ids when remote succeeds; writes DB with read=true', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '1'), dbId('1', '2')];
      const remotes: string[] = [remoteId(ids[0]), remoteId(ids[1])];

      // Mock private api() with exact value (the account object).
      const fakeApi: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const editTagMock = mock.mockFunc(fakeApi, fakeApi.editTag);
      when(editTagMock)(remotes, 'user/-/state/com.google/read', undefined)
        .afterReturn(Promise.resolve('ok'));
      // Mock DB setStates with exact args.
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, true, undefined).afterAction((): Promise<void> => Promise.resolve());

      const result: string[] = await svc.markRead(a, ids, true);
      expect(result.length).assertEqual(2);
      expect(result[0]).assertEqual(ids[0]);
      mock.verify('setStates', [ids, true, undefined]).once();
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });

    it('returns [] when remote editTag throws (failed ids not confirmed)', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '3')];
      const remotes: string[] = [remoteId(ids[0])];

      const fakeApi: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const editTagMock = mock.mockFunc(fakeApi, fakeApi.editTag);
      when(editTagMock)(remotes, 'user/-/state/com.google/read', undefined)
        .afterThrow('network down');
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, true, undefined).afterAction((): Promise<void> => Promise.resolve());

      const result: string[] = await svc.markRead(a, ids, true);
      expect(result.length).assertEqual(0);
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });
  });

  describe('GoogleReaderSyncService.markStarredBatch with mocks', () => {
    it('confirms ids on success; writes DB with starred=true', 0, async () => {
      const mock: MockKit = new MockKit();
      const svc: GoogleReaderSyncService = new GoogleReaderSyncService();
      const a: Account = account();
      const ids: string[] = [dbId('1', '7')];
      const remotes: string[] = [remoteId(ids[0])];

      const fakeApi: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const apiFn = mock.mockPrivateFunc(svc, 'api');
      when(apiFn)(a).afterReturn(fakeApi);
      const editTagMock = mock.mockFunc(fakeApi, fakeApi.editTag);
      when(editTagMock)(remotes, 'user/-/state/com.google/starred', undefined)
        .afterReturn(Promise.resolve('ok'));
      const dbMock = mock.mockFunc(database, database.setStates);
      when(dbMock)(ids, undefined, true).afterAction((): Promise<void> => Promise.resolve());

      const result: string[] = await svc.markStarredBatch(a, ids, true);
      expect(result.length).assertEqual(1);
      mock.clear(database);
      mock.clear(fakeApi);
      mock.clear(svc);
    });
  });
}
