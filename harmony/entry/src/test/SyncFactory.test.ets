import { describe, it, expect } from '@ohos/hypium';
import { syncServiceFor } from '../main/ets/rss/SyncServiceFactory';
import { LocalSyncService } from '../main/ets/rss/LocalSyncService';
import { FeverSyncService } from '../main/ets/rss/FeverSyncService';
import { GoogleReaderSyncService } from '../main/ets/rss/GoogleReaderSyncService';
import { MinifluxSyncService } from '../main/ets/rss/MinifluxSyncService';
import { Account, AccountType } from '../main/ets/account/AccountModels';

function account(type: AccountType): Account {
  const a: Account = {
    id: '1', name: 'a', type: type, securityKey: '', updateAt: 0, lastArticleId: null,
    syncInterval: 30, syncOnStart: false, syncOnlyOnWiFi: false,
    syncOnlyWhenCharging: false, keepArchived: 2592000000, syncBlockList: '',
  };
  return a;
}

export default function syncFactoryTest(): void {
  describe('syncServiceFor routing', () => {
    it('FEVER -> FeverSyncService', 0, () => {
      expect(syncServiceFor(account(AccountType.FEVER)) instanceof FeverSyncService).assertTrue();
    });

    it('GOOGLE_READER and FRESH_RSS -> GoogleReaderSyncService', 0, () => {
      expect(syncServiceFor(account(AccountType.GOOGLE_READER)) instanceof GoogleReaderSyncService).assertTrue();
      expect(syncServiceFor(account(AccountType.FRESH_RSS)) instanceof GoogleReaderSyncService).assertTrue();
    });

    it('MINIFLUX -> MinifluxSyncService', 0, () => {
      expect(syncServiceFor(account(AccountType.MINIFLUX)) instanceof MinifluxSyncService).assertTrue();
    });

    it('FEEDLY / INOREADER / LOCAL -> LocalSyncService', 0, () => {
      expect(syncServiceFor(account(AccountType.FEEDLY)) instanceof LocalSyncService).assertTrue();
      expect(syncServiceFor(account(AccountType.INOREADER)) instanceof LocalSyncService).assertTrue();
      expect(syncServiceFor(account(AccountType.LOCAL)) instanceof LocalSyncService).assertTrue();
    });

    it('returns the same singleton instance for repeated calls', 0, () => {
      const a: Account = account(AccountType.FEVER);
      expect(syncServiceFor(a) === syncServiceFor(a)).assertTrue();
    });
  });
}
