import {
  describe, it, expect, MockKit, when, ArgumentMatchers,
} from '@ohos/hypium';
import {
  MinifluxApi, MinifluxCategory, MinifluxEntry, MinifluxFeed, MinifluxEntryParams,
} from '../main/ets/rss/MinifluxApi';
import {
  GoogleReaderApi, GReaderSubscription, ItemIdsDto, ItemsContentsResult, GReaderItem,
} from '../main/ets/rss/GoogleReaderApi';
import { FeverApi } from '../main/ets/rss/FeverApi';
import { StatusDiffs } from '../main/ets/rss/StatusDiffs';
import { Account, AccountType, dbId } from '../main/ets/account/AccountModels';

/** Fake-data tests for every protocol API. The transport layer is mocked so no
 *  network, database or device service is touched; each public API method is
 *  driven by a canned response and its parsing/parameterisation is verified. */

interface FakeEntryIds { entry_ids: number[]; total: number }
interface FakeEntries { entries: MinifluxEntry[]; total: number }
interface ApiQueryAccess { entryQuery(params: MinifluxEntryParams): string }
interface FakeItemRef { id: string }
interface FakeItemRefs { itemRefs: FakeItemRef[] }
interface FakeSubscriptions { subscriptions: GReaderSubscription[] }
interface FakeContents { items: GReaderItem[]; updated: number }
interface FakeFeverGroup { id: number; title: string }
interface FakeFeverFeed { id: number; title: string; url: string }
interface FakeFeverMapping { group_id: number; feed_ids: string }
interface FakeFeverState {
  groups: FakeFeverGroup[];
  feeds: FakeFeverFeed[];
  feeds_groups: FakeFeverMapping[];
}
interface FakeFeverItem { id: string; feed_id: number; title: string; html: string; is_read: number }
interface FakeFeverItems { items: FakeFeverItem[] }
interface FakeFeverIds { unread_item_ids?: string; saved_item_ids?: string }

function account(): Account {
  const a: Account = {
    id: '1', name: 'a', type: AccountType.MINIFLUX, securityKey: '',
    updateAt: 0, lastArticleId: null, syncInterval: 30, syncOnStart: false,
    syncOnlyOnWiFi: false, syncOnlyWhenCharging: false, keepArchived: 2592000000,
    syncBlockList: '',
  };
  return a;
}

export default function protocolApiTest(): void {
  describe('MinifluxApi with fake responses', () => {
    it('parses categories and feeds', 0, async () => {
      const mock: MockKit = new MockKit();
      const api: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const categories: MinifluxCategory[] = [{ id: 1, title: 'All' }, { id: 2, title: 'Tech' }];
      const feeds: MinifluxFeed[] = [
        { id: 10, title: 'Feed', feed_url: 'https://f', category: { id: 2 } },
      ];
      const requestFn = mock.mockPrivateFunc(api, 'request');
      when(requestFn)(ArgumentMatchers.any, 'categories')
        .afterReturn(Promise.resolve(categories));
      when(requestFn)(ArgumentMatchers.any, 'feeds')
        .afterReturn(Promise.resolve(feeds));

      const gotCategories: MinifluxCategory[] = await api.getCategories();
      const gotFeeds: MinifluxFeed[] = await api.getFeeds();
      expect(gotCategories.length).assertEqual(2);
      expect(gotCategories[1].title).assertEqual('Tech');
      expect(gotFeeds[0].id).assertEqual(10);
      expect(gotFeeds[0].category?.id).assertEqual(2);
      mock.clear(api);
    });

    it('parses entry ids, entries and a single entry', 0, async () => {
      const mock: MockKit = new MockKit();
      const api: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const entry: MinifluxEntry = {
        id: 101, feed_id: 10, title: 'x', content: '<p>body</p>', status: 'read', starred: false,
      };
      const idsBody: FakeEntryIds = { entry_ids: [101, 102], total: 2 };
      const entriesBody: FakeEntries = { entries: [entry], total: 1 };
      const requestFn = mock.mockPrivateFunc(api, 'request');
      when(requestFn)(ArgumentMatchers.any, 'entries/ids', undefined, ArgumentMatchers.any)
        .afterReturn(Promise.resolve(idsBody));
      when(requestFn)(ArgumentMatchers.any, 'entries/101')
        .afterReturn(Promise.resolve(entry));
      when(requestFn)(ArgumentMatchers.any, 'entries', undefined, ArgumentMatchers.any)
        .afterReturn(Promise.resolve(entriesBody));

      const ids: number[] = await api.getEntryIds({ status: 'unread', limit: 100 });
      const page = await api.getEntries({ afterEntryId: 100, limit: 100 });
      const single: MinifluxEntry = await api.getEntry(101);
      expect(ids.length).assertEqual(2);
      expect(ids[0]).assertEqual(101);
      expect((page.entries ?? []).length).assertEqual(1);
      expect(single.content).assertEqual('<p>body</p>');
      expect(single.status).assertEqual('read');
      mock.clear(api);
    });

    it('sends status and starred in the update entries body', 0, async () => {
      const mock: MockKit = new MockKit();
      const api: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const requestFn = mock.mockPrivateFunc(api, 'request');
      let sentBody: string = '';
      when(requestFn)(ArgumentMatchers.any, 'entries', ArgumentMatchers.any)
        .afterAction((method: Object, path: Object, body: Object): Promise<string> => {
          sentBody = body === undefined ? '' : String(body);
          return Promise.resolve('');
        });
      await api.updateEntries([101, 102], 'read', true);
      expect(sentBody.indexOf('"entry_ids":[101,102]') >= 0).assertTrue();
      expect(sentBody.indexOf('"status":"read"') >= 0).assertTrue();
      expect(sentBody.indexOf('"starred":true') >= 0).assertTrue();
      mock.clear(api);
    });

    it('builds incremental cursor queries without offset', 0, () => {
      const api: MinifluxApi = new MinifluxApi('https://x', 'token', '');
      const access = api as object as ApiQueryAccess;
      const query: string = access.entryQuery({
        afterEntryId: 500, beforeEntryId: 480, limit: 300, order: 'id', direction: 'desc',
      });
      expect(query.indexOf('after_entry_id=500') >= 0).assertTrue();
      expect(query.indexOf('before_entry_id=480') >= 0).assertTrue();
      expect(query.indexOf('limit=300') >= 0).assertTrue();
      expect(query.indexOf('offset=') >= 0).assertFalse();
    });
  });

  describe('GoogleReaderApi with fake responses', () => {
    it('parses subscriptions, item ids and item contents', 0, async () => {
      const mock: MockKit = new MockKit();
      const api: GoogleReaderApi = new GoogleReaderApi('https://x', 'user', 'pass');
      const subs: GReaderSubscription[] = [
        { id: 'feed/1', title: 'Feed', categories: [{ id: 'user/-/label/A', label: 'A' }] },
      ];
      const item: GReaderItem = {
        id: 'tag:google.com,2005:reader/item/1', title: 'Title',
        origin: { streamId: 'feed/1', title: 'Feed' }, summary: { content: '<p>body</p>' },
      };
      const items: ItemsContentsResult = { items: [item], updated: 100 };
      const subscriptionsBody: FakeSubscriptions = { subscriptions: subs };
      const ref: FakeItemRef = { id: item.id };
      const itemRefsBody: FakeItemRefs = { itemRefs: [ref] };
      const contentsBody: FakeContents = { items: [item], updated: 100 };
      // get() is a private transport wrapper; stub it by exact endpoint so the
      // public parsing methods are still exercised with fake data.
      const getFn = mock.mockPrivateFunc(api, 'get');
      when(getFn)('reader/api/0/subscription/list', ArgumentMatchers.any)
        .afterReturn(Promise.resolve(subscriptionsBody));
      when(getFn)('reader/api/0/stream/items/ids', ArgumentMatchers.any)
        .afterReturn(Promise.resolve(itemRefsBody));
      // getItemsContents uses rawRequest directly rather than get().
      const authFn = mock.mockPrivateFunc(api, 'ensureAuth');
      when(authFn)().afterReturn(Promise.resolve());
      const rawFn = mock.mockPrivateFunc(api, 'rawRequest');
      when(rawFn)(
        ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any, ArgumentMatchers.any
      ).afterReturn(Promise.resolve(JSON.stringify(contentsBody)));

      const gotSubs: GReaderSubscription[] = await api.getSubscriptionList();
      const ids: ItemIdsDto = await api.getItemIds({ s: 'feed/1' });
      const gotContents: ItemsContentsResult = await api.getItemsContents([item.id]);
      expect(gotSubs.length).assertEqual(1);
      expect(gotSubs[0].categories?.[0].label).assertEqual('A');
      expect((ids.itemRefs ?? []).length).assertEqual(1);
      expect(gotContents.items[0].title).assertEqual('Title');
      expect(gotContents.updated).assertEqual(100);
      mock.clear(api);
    });

    it('sends read mark through editTag', 0, async () => {
      const mock: MockKit = new MockKit();
      const api: GoogleReaderApi = new GoogleReaderApi('https://x', 'user', 'pass');
      const authFn = mock.mockPrivateFunc(api, 'ensureAuth');
      when(authFn)().afterReturn(Promise.resolve());
      const rawFn = mock.mockPrivateFunc(api, 'rawRequest');
      let sentBody: string = '';
      when(rawFn)(
        ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any, ArgumentMatchers.any
      ).afterAction((url: Object, method: Object, body: Object): Promise<string> => {
        expect(String(url).indexOf('edit-tag') >= 0).assertTrue();
        sentBody = body === undefined ? '' : String(body);
        return Promise.resolve('OK');
      });
      const result: string = await api.editTag(['a', 'b'], 'user/-/state/com.google/read', undefined);
      expect(result).assertEqual('OK');
      expect(sentBody.indexOf('i=a') >= 0).assertTrue();
      expect(sentBody.indexOf('i=b') >= 0).assertTrue();
      expect(sentBody.indexOf('read') >= 0).assertTrue();
      mock.clear(api);
    });
  });

  describe('FeverApi with fake responses', () => {
    it('parses groups, feeds, items and status id lists', 0, async () => {
      const mock: MockKit = new MockKit();
      const api: FeverApi = new FeverApi('https://x', 'user', 'pass');
      const group: FakeFeverGroup = { id: 1, title: 'A' };
      const feed: FakeFeverFeed = { id: 10, title: 'Feed', url: 'https://f' };
      const mapping: FakeFeverMapping = { group_id: 1, feed_ids: '10' };
      const stateBody: FakeFeverState = {
        groups: [group], feeds: [feed], feeds_groups: [mapping],
      };
      const unreadIdsBody: FakeFeverIds = { unread_item_ids: '101,102' };
      const savedIdsBody: FakeFeverIds = { saved_item_ids: '102' };
      const feverItem: FakeFeverItem = {
        id: '101', feed_id: 10, title: 'Title', html: '<p>body</p>', is_read: 0,
      };
      const itemsBody: FakeFeverItems = { items: [feverItem] };
      const postFn = mock.mockPrivateFunc(api, 'post');
      when(postFn)(ArgumentMatchers.any).afterAction((query: Object): Promise<string> => {
        const q: string = String(query);
        if (q.indexOf('groups') >= 0 || q.indexOf('feeds') >= 0) {
          return Promise.resolve(JSON.stringify(stateBody));
        }
        if (q.indexOf('unread_item_ids') >= 0) {
          return Promise.resolve(JSON.stringify(unreadIdsBody));
        }
        if (q.indexOf('saved_item_ids') >= 0) {
          return Promise.resolve(JSON.stringify(savedIdsBody));
        }
        return Promise.resolve(JSON.stringify(itemsBody));
      });

      const groups = await api.getGroups();
      const feeds = await api.getFeeds();
      const items = await api.getItemsSince('');
      const unread: string[] | undefined = await api.getUnreadIds();
      const saved: string[] = await api.getSavedIds();
      expect((groups.groups ?? []).length).assertEqual(1);
      expect((feeds.feeds ?? []).length).assertEqual(1);
      expect((items.items ?? []).length).assertEqual(1);
      expect(unread?.length).assertEqual(2);
      expect(saved.length).assertEqual(1);
      mock.clear(api);
    });
  });

  describe('Account-scoped status deltas (switch fix)', () => {
    it('does not leak a pending mark from the old account', 0, () => {
      const diffs: StatusDiffs = new StatusDiffs();
      diffs.markRead(dbId('1', '101'), true, false, 'f1', 'g1');
      diffs.markRead(dbId('2', '201'), true, false, 'f2', 'g2');
      diffs.markStarred(dbId('1', '101'), true, false, 'f1');
      diffs.markStarred(dbId('2', '201'), true, false, 'f2');
      expect(diffs.unreadDeltaForAccount('1')).assertEqual(1);
      expect(diffs.unreadDeltaForAccount('2')).assertEqual(1);
      expect(diffs.starredDeltaForAccount('1')).assertEqual(1);
      expect(diffs.starredDeltaForAccount('2')).assertEqual(1);
      diffs.clearAll();
      expect(diffs.unreadDeltaForAccount('1')).assertEqual(0);
    });

    it('keeps an article row id round-trippable across accounts', 0, () => {
      const a: Account = account();
      expect(dbId(a.id, '456')).assertEqual('1$456');
      expect(dbId(a.id, '456').startsWith(`${a.id}$`)).assertTrue();
    });
  });
}
