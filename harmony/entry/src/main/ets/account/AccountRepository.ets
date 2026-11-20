import { database } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import {
  Account,
  AccountType,
  CredentialCodec,
  EMPTY_SECURITY_KEY,
  RemoteCredentials,
  dbId,
  emptyCredentials,
} from './AccountModels';
import { Feed, FeedGroup } from '../model/Models';
import { Logger } from '../common/Logger';

export const DEFAULT_GROUP_SUFFIX: string = 'read_you_app_default_group';
const INITIAL_FEED_URL: string = 'https://github.com/ReadYouApp/ReadYou/releases.atom';

/** Owns account CRUD and the currently selected account, like Android's AccountService. */
class ReadYouAccountRepository {
  private ensureTask?: Promise<void>;
  private firstRun: boolean = false;

  async ensureDefault(): Promise<void> {
    if (!this.ensureTask) {
      this.ensureTask = this.doEnsureDefault();
    }
    return this.ensureTask;
  }

  /** AccountService.initWithDefaultAccount() creates account + default group + starter feed. */
  private async doEnsureDefault(): Promise<void> {
    const accounts: Account[] = await database.listAccounts();
    if (accounts.length === 0) {
      this.firstRun = true;
      const local: Account = {
        id: '1',
        name: 'Read You',
        type: AccountType.LOCAL,
        securityKey: EMPTY_SECURITY_KEY,
        updateAt: null,
        lastArticleId: null,
        syncInterval: 30,
        syncOnStart: false,
        syncOnlyOnWiFi: false,
        syncOnlyWhenCharging: false,
        keepArchived: 2592000000,
        syncBlockList: '',
      };
      await database.insertAccount(local);
      await this.createDefaultGroup('1');
      const initialFeed: Feed = {
        id: dbId('1', `initial-${Date.now().toString()}`),
        title: 'ReadYou Releases',
        url: INITIAL_FEED_URL,
        groupId: dbId('1', DEFAULT_GROUP_SUFFIX),
        iconUrl: '',
        sortOrder: 0,
        unreadCount: 0,
      };
      await database.upsertFeed(initialFeed, '1');
      Logger.info('Created default account, group and starter feed');
      return;
    }
    const active: string = settingsStore.get().activeAccountId;
    if (!accounts.some((account: Account) => account.id === active)) {
      await settingsStore.setActiveAccountId(accounts[0].id);
    }
  }

  isFirstRun(): boolean {
    return this.firstRun;
  }

  private async createDefaultGroup(accountId: string): Promise<void> {
    const group: FeedGroup = {
      id: dbId(accountId, DEFAULT_GROUP_SUFFIX),
      name: 'Defaults',
      sortOrder: 0,
    };
    await database.upsertGroup(group, accountId);
  }

  async list(): Promise<Account[]> {
    await this.ensureDefault();
    return database.listAccounts();
  }

  async active(): Promise<Account | undefined> {
    await this.ensureDefault();
    return await database.getAccount(settingsStore.get().activeAccountId);
  }

  /** Creates an account; credentials are DES-encrypted before storage. */
  async add(type: AccountType, name: string, credentials: RemoteCredentials): Promise<Account> {
    const accounts: Account[] = await this.list();
    let next: number = 1;
    for (const account of accounts) {
      next = Math.max(next, Number.parseInt(account.id, 10) + 1);
    }
    const id: string = next.toString();
    const account: Account = {
      id: id,
      name: name,
      type: type,
      securityKey: type === AccountType.LOCAL
        ? EMPTY_SECURITY_KEY
        : CredentialCodec.encodeCredentials(credentials),
      updateAt: null,
      lastArticleId: null,
      syncInterval: 30,
      syncOnStart: false,
      syncOnlyOnWiFi: false,
      syncOnlyWhenCharging: false,
      keepArchived: 2592000000,
      syncBlockList: '',
    };
    await database.insertAccount(account);
    if (type === AccountType.LOCAL) {
      await this.createDefaultGroup(id);
    }
    await settingsStore.setActiveAccountId(id);
    return account;
  }

  async update(account: Account, credentials?: RemoteCredentials): Promise<void> {
    if (credentials && account.type !== AccountType.LOCAL) {
      account.securityKey = CredentialCodec.encodeCredentials(credentials);
    }
    await database.updateAccount(account);
  }

  /** Returns false when the last account cannot be removed (Android shows a toast). */
  async remove(id: string): Promise<boolean> {
    const accounts: Account[] = await this.list();
    if (accounts.length <= 1) {
      return false;
    }
    await database.deleteAccount(id);
    const remaining: Account[] = await database.listAccounts();
    if (remaining.length > 0) {
      await settingsStore.setActiveAccountId(remaining[0].id);
    }
    return true;
  }

  switchTo(id: string): Promise<void> {
    return settingsStore.setActiveAccountId(id);
  }

  credentials(account: Account): RemoteCredentials {
    if (account.type === AccountType.LOCAL) {
      return emptyCredentials();
    }
    return CredentialCodec.decodeCredentials(account.securityKey);
  }
}

export const accountRepository: ReadYouAccountRepository = new ReadYouAccountRepository();
