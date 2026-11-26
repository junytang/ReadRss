import { describe, it, expect, MockKit, when } from '@ohos/hypium';
import { accountRepository, DEFAULT_GROUP_SUFFIX } from '../main/ets/account/AccountRepository';
import { database } from '../main/ets/data/Database';
import { Account, AccountType, EMPTY_SECURITY_KEY, dbId } from '../main/ets/account/AccountModels';

function acc(id: string, type: AccountType): Account {
  const a: Account = {
    id: id, name: 'n' + id, type: type, securityKey: EMPTY_SECURITY_KEY,
    updateAt: null, lastArticleId: null, syncInterval: 30, syncOnStart: false,
    syncOnlyOnWiFi: false, syncOnlyWhenCharging: false, keepArchived: 2592000000,
    syncBlockList: '',
  };
  return a;
}

export default function accountRepositoryTest(): void {
  describe('AccountRepository.remove', () => {
    it('allows removing the last account', 0, async () => {
      const mock: MockKit = new MockKit();
      const la = mock.mockFunc(database, database.listAccounts);
      // After deletion there are no accounts left: clear the active id but do
      // NOT re-arm the first-run navigation guide.
      when(la)().afterReturn(Promise.resolve([]));
      const da = mock.mockFunc(database, database.deleteAccount);
      when(da)('1').afterReturn(Promise.resolve());
      AppStorage.setOrCreate<number>('firstRunTick', 0);
      const result: boolean = await accountRepository.remove('1');
      expect(result).assertTrue();
      mock.verify('deleteAccount', ['1']).once();
      expect(AppStorage.get<string>('activeAccountId') ?? 'x').assertEqual('');
      expect(AppStorage.get<number>('firstRunTick') ?? -1).assertEqual(0);
      mock.clear(database);
    });

    it('deletes and switches active when multiple accounts', 0, async () => {
      const mock: MockKit = new MockKit();
      const la = mock.mockFunc(database, database.listAccounts);
      const accounts: Account[] = [acc('1', AccountType.LOCAL), acc('2', AccountType.FEVER)];
      when(la)().afterReturn(Promise.resolve(accounts));
      const da = mock.mockFunc(database, database.deleteAccount);
      when(da)('1').afterReturn(Promise.resolve());
      const result: boolean = await accountRepository.remove('1');
      expect(result).assertTrue();
      mock.verify('deleteAccount', ['1']).once();
      mock.clear(database);
    });
  });

  describe('AccountRepository.credentials', () => {
    it('local account returns empty credentials', 0, () => {
      const c = accountRepository.credentials(acc('1', AccountType.LOCAL));
      expect(c.serverUrl).assertEqual('');
      expect(c.username).assertEqual('');
      expect(c.password).assertEqual('');
    });
  });

  describe('AccountRepository default group id', () => {
    it('DEFAULT_GROUP_SUFFIX produces a stable dbId', 0, () => {
      expect(dbId('1', DEFAULT_GROUP_SUFFIX)).assertEqual('1$' + DEFAULT_GROUP_SUFFIX);
    });
  });
}
