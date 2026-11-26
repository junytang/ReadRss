import {
  Account,
  AccountType,
  categoryIdFromStreamId,
  categoryStreamId,
  dbId,
  feedIdFromStreamId,
  feedStreamId,
  isValidItemId,
  remoteId,
  shortItemId,
} from '../account/AccountModels';
import { accountRepository, DEFAULT_GROUP_SUFFIX } from '../account/AccountRepository';
import { database, ArticleState } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import { Article, Feed, FeedGroup } from '../model/Models';
import {
  beginSync, notifySyncBatch, notifyContentReady, UiReadySignal,
} from './SyncProgress';
import { forEachLimited, SYNC_CONCURRENCY, UI_WINDOW_SIZE } from './SyncRuntime';
import {
  ApiParams,
  GReaderSubscription,
  GoogleReaderApi,
  ItemIdsDto,
  ItemsContentsResult,
  QuickAddDto,
} from './GoogleReaderApi';
import { XmlParser } from './XmlParser';
import { FeedSyncService, FeedNotify, SyncResult } from './SyncService';
import { Logger } from '../common/Logger';
import { NotificationHelper } from '../common/NotificationHelper';
import { pendingStatusRegistry } from './PendingStatusRegistry';

const READING_LIST_STREAM: string = 'user/-/state/com.google/reading-list';
const READ_TAG: string = 'user/-/state/com.google/read';
const STARRED_TAG: string = 'user/-/state/com.google/starred';

/**
 * Read IDs are only used for local state reconciliation, never for content fetching.
 * Capping them avoids tens of thousands of requests on a first sync. This is a
 * deliberate deviation from Android, which fetches every read-id page.
 */
/** ID streams are paged with a large page size to minimise network round-trips;
 *  the configured fetchBatchSize only governs content fetch + insert batches. */
const ID_PAGE_SIZE: string = '1000';
const READ_ID_PAGES: number = 3;
/** Unread/starred ID streams are authoritative for state. Cap them at 20 pages
 *  (20k ids) to protect self-hosted servers; if a stream is truncated we skip
 *  that direction of state reconciliation rather than marking the tail read. */
const STATE_ID_PAGES: number = 20;

interface ItemIdPage {
  ids: string[];
  truncated: boolean;
}
/** Bounded parallelism for content batches, shared with every other protocol. */

/** Port of GoogleReaderRssService.kt (also handles FreshRSS). */
export class GoogleReaderSyncService implements FeedSyncService {
  readonly canImportSubscription: boolean = false;
  readonly canAddSubscription: boolean = true;
  readonly canMoveSubscription: boolean = true;
  readonly canDeleteSubscription: boolean = true;
  readonly canUpdateSubscription: boolean = true;

  private api(account: Account): GoogleReaderApi {
    const credentials = accountRepository.credentials(account);
    return new GoogleReaderApi(credentials.serverUrl, credentials.username, credentials.password);
  }

  async validCredentials(account: Account): Promise<boolean> {
    const api: GoogleReaderApi = this.api(account);
    // Do not overwrite the user-entered display name with the remote username:
    // the header should show the chosen name, falling back to username only
    // when no name was provided.
    return await api.validCredentials();
  }

  clearAuthorization(): void {
    // Each sync creates a fresh API instance in this port.
  }

  async subscribe(account: Account, rawUrl: string): Promise<Feed> {
    const api: GoogleReaderApi = this.api(account);
    const added: QuickAddDto = await api.quickAdd(rawUrl);
    if (!added.streamId) {
      throw new Error('无法订阅该地址');
    }
    const id: string = feedIdFromStreamId(added.streamId);
    const title: string = added.streamName && added.streamName.trim().length > 0
      ? added.streamName
      : id;
    const groupId: string = dbId(account.id, DEFAULT_GROUP_SUFFIX);
    const feed: Feed = {
      id: dbId(account.id, id),
      title: title,
      url: rawUrl,
      groupId: groupId,
      iconUrl: '',
      sortOrder: Date.now(),
      unreadCount: 0,
      starredCount: 0,
    };
    await api.subscriptionEdit('edit', added.streamId, categoryStreamId(remoteId(groupId)), '', title);
    await database.upsertFeed(feed, account.id);
    return feed;
  }

  async addGroup(account: Account, newGroupName: string): Promise<FeedGroup> {
    const api: GoogleReaderApi = this.api(account);
    const groupId: string = dbId(account.id, categoryStreamId(newGroupName));
    const group: FeedGroup = { id: groupId, name: newGroupName, sortOrder: Date.now() };
    await api.subscriptionEdit('edit', '', categoryStreamId(newGroupName), '', '');
    await database.upsertGroup(group, account.id);
    return group;
  }

  async renameGroup(account: Account, group: FeedGroup): Promise<void> {
    const api: GoogleReaderApi = this.api(account);
    await api.renameTag(categoryStreamId(remoteId(group.id)), categoryStreamId(group.name));
    await database.upsertGroup(group, account.id);
  }

  async renameFeed(account: Account, feed: Feed): Promise<void> {
    const api: GoogleReaderApi = this.api(account);
    await api.subscriptionEdit('edit', feedStreamId(remoteId(feed.id)), '', '', feed.title);
    await database.upsertFeed(feed, account.id);
  }

  async moveFeed(account: Account, originGroupId: string, feed: Feed): Promise<void> {
    const api: GoogleReaderApi = this.api(account);
    await api.subscriptionEdit(
      'edit',
      feedStreamId(remoteId(feed.id)),
      categoryStreamId(remoteId(feed.groupId)),
      categoryStreamId(remoteId(originGroupId)),
      ''
    );
    await database.upsertFeed(feed, account.id);
  }

  async deleteGroup(account: Account, group: FeedGroup): Promise<void> {
    const api: GoogleReaderApi = this.api(account);
    for (const feed of await database.listFeeds(account.id)) {
      if (feed.groupId === group.id) {
        await this.deleteFeed(account, feed.id);
      }
    }
    await api.disableTag(categoryStreamId(remoteId(group.id)));
    // Keep every OTHER group; passing [group.id] would delete all groups but
    // the one just removed.
    const remaining: string[] = (await database.listGroups(account.id))
      .map((item: FeedGroup): string => item.id)
      .filter((id: string): boolean => id !== group.id);
    await database.deleteGroupsExcept(account.id, remaining);
  }

  // ------------------------------ ID stream helpers ------------------------

  private async allItemIds(
    api: GoogleReaderApi, base: ApiParams, maxPages: number = STATE_ID_PAGES
  ): Promise<ItemIdPage> {
    const ids: string[] = [];
    let continuation: string | undefined = undefined;
    let page: number = 0;
    for (;;) {
      if (page >= maxPages) {
        return { ids: ids, truncated: true };
      }
      page++;
      const params: ApiParams = {
        s: base.s, xt: base.xt, it: base.it, ot: base.ot, n: base.n, quickadd: base.quickadd,
      };
      if (continuation) {
        params.c = continuation;
      }
      // A partial ID set must never be treated as authoritative: reconciliation
      // marks articles read by absence from unreadSet. Fail the whole sync on a
      // page error so the user can retry instead of losing read/star states.
      const body: ItemIdsDto = await api.getItemIds(params);
      for (const ref of body.itemRefs ?? []) {
        if (ref.id) {
          ids.push(shortItemId(ref.id));
        }
      }
      continuation = body.continuation;
      if (!continuation) {
        break;
      }
    }
    return { ids: ids, truncated: false };
  }

  private async chunks<T>(items: T[], size: number): Promise<T[][]> {
    const result: T[][] = [];
    for (let i = 0; i < items.length; i += size) {
      result.push(items.slice(i, i + size));
    }
    return result;
  }

  // --------------------------------- sync ---------------------------------

  async sync(account: Account): Promise<SyncResult> {
    const result: SyncResult = { succeeded: 0, failed: 0, newArticles: 0 };
    if (account.type !== AccountType.GOOGLE_READER && account.type !== AccountType.FRESH_RSS) {
      throw new Error('account type is invalid');
    }
    const api: GoogleReaderApi = this.api(account);
    const now: number = Date.now();
    let phaseTime: number = now;
    beginSync();
    const uiReady: UiReadySignal = new UiReadySignal(now);
    try {
      // Use cached tokens for sync and let 401 recovery re-authenticate; a
      // fresh ClientLogin on every refresh is unnecessary and can be throttled
      // by FreshRSS. Credential validity is checked when the account is added.
      await api.ensureAuthIfNeeded();

      // First-screen fast path (fresh account): one unread ID page + one
      // contents request, committed before the full ID/metadata work so the
      // list appears in ~1s. The main pass reads article states from the DB
      // and will not re-fetch these ids.
      if (account.updateAt === 0) {
        const firstIds: string[] = (await this.allItemIds(
          api, { s: READING_LIST_STREAM, xt: READ_TAG, n: String(UI_WINDOW_SIZE) }, 1
        )).ids;
        if (firstIds.length > 0) {
          const contents: ItemsContentsResult = await api.getItemsContents(firstIds);
          const firstArticles: Article[] = [];
          for (const item of contents.items) {
            if (!isValidItemId(item.id)) {
              continue;
            }
            const streamId: string | undefined = item.origin?.streamId;
            if (!streamId) {
              continue;
            }
            const id: string = shortItemId(item.id);
            const localId: string = dbId(account.id, id);
            // insertArticles uses INSERT OR REPLACE: never overwrite a row whose
            // mark is still pending locally, or the DB copy would diverge.
            if (pendingStatusRegistry.has(localId)) {
              continue;
            }
            const publishedSec: number = item.published ?? Math.floor(now / 1000);
            const published: number = publishedSec * 1000;
            firstArticles.push({
              id: localId,
              feedId: dbId(account.id, feedIdFromStreamId(streamId)),
              feedTitle: XmlParser.decode(item.origin?.title),
              title: XmlParser.decode(item.title),
              author: item.author ?? '',
              link: item.canonical?.[0]?.href ?? item.alternate?.[0]?.href ?? item.origin?.htmlUrl ?? '',
              summary: this.plainText(item.summary?.content ?? '').substring(0, 280),
              content: item.summary?.content ?? '',
              imageUrl: this.firstImage(item.summary?.content ?? ''),
              publishedAt: published > now ? now : published,
              isRead: false,
              isStarred: false,
              fullContent: '',
            });
          }
          if (firstArticles.length > 0) {
            result.newArticles += await database.insertArticles(firstArticles, account.id);
            notifySyncBatch();
          }
          // No new articles is still "UI ready": the existing list is readable.
          uiReady.fire();
          Logger.info(`GReader first-screen window: ${firstArticles.length} articles`);
        }
      }

      const isFreshRss: boolean = account.type === AccountType.FRESH_RSS;
      const batchSize: number = settingsStore.get().fetchBatchSize;
      // Incremental read-ID reconciliation uses `ot=<上次同步时间>` as a lower
      // bound; on a fresh account fall back to a 30-day window. This stream is
      // only used to mark local articles READ, so a partial set is safe.
      // Unread/starred ID streams stay COMPLETE (no `ot`): they are the
      // authoritative state sets, and a partial set would wrongly revert old
      // stars/unreads during reconciliation. Their `c` continuation cursors
      // already make paging stable even when new items arrive mid-sync.
      const lastSync: number = account.updateAt ?? 0;
      const sinceSec: number = Math.floor(
        (lastSync > 0 ? lastSync : now - 30 * 24 * 3600 * 1000) / 1000
      );
      const since: string = sinceSec.toString();
      const readParams: ApiParams = isFreshRss
        ? { s: READING_LIST_STREAM, it: READ_TAG, ot: since, n: ID_PAGE_SIZE }
        : { s: READ_TAG, ot: since, n: ID_PAGE_SIZE };
      const unreadParams: ApiParams = { s: READING_LIST_STREAM, xt: READ_TAG, n: ID_PAGE_SIZE };
      const starredParams: ApiParams = { s: STARRED_TAG, n: ID_PAGE_SIZE };

      // Content IDs: unread + starred (authoritative state sets) plus recently
      // read (ot=<上次同步时间>) so an article another client read after our last
      // sync still gets its body stored. Build sets directly: keeping both id
      // arrays and sets held two full copies of every id for the whole sync
      // (tens of MB on a large account). Set iteration order equals the original
      // array order, so downstream toFetch order and dedupe are unchanged.
      // The three ID streams are independent — fetch them concurrently. On a
      // first sync this was 3 sequential round-trips before any article could
      // be shown; now it costs one (bounded by SYNC_CONCURRENCY = 3).
      const idStreams: [ItemIdPage, ItemIdPage, ItemIdPage] = await Promise.all([
        this.allItemIds(api, unreadParams, STATE_ID_PAGES),
        this.allItemIds(api, starredParams, STATE_ID_PAGES),
        // Recently-read IDs (ot=<上次同步时间>) are only for CONTENT: an
        // article that arrived after our last sync but was read by another
        // client is in neither unreadSet nor starredSet, so its body would
        // otherwise be lost. State uses the complete unreadSet instead, because
        // FreshRSS's ot filters on crawl time, not on when a mark happened.
        this.allItemIds(api, readParams, READ_ID_PAGES),
      ]);
      const unreadSet: Set<string> = new Set<string>(idStreams[0].ids);
      const starredSet: Set<string> = new Set<string>(idStreams[1].ids);
      const recentReadIds: string[] = idStreams[2].ids;
      const recentReadSet: Set<string> = new Set<string>(recentReadIds);
      // A truncated authoritative stream must not be used to mark the tail
      // read/unstarred; skip that direction of reconciliation instead.
      const reconcileReadState: boolean = !idStreams[0].truncated;
      const reconcileStarState: boolean = !idStreams[1].truncated;
      if (!reconcileReadState || !reconcileStarState) {
        Logger.warn('GReader ID stream truncated; skipping affected state reconciliation');
      }
      Logger.info(`GReader sync auth+ids: ${Date.now() - phaseTime}ms`);
      phaseTime = Date.now();

      const subscriptions: GReaderSubscription[] = await api.getSubscriptionList();
      const keepGroupIds: string[] = [];
      const keepFeedIds: string[] = [];
      const defaultGroupId: string = dbId(account.id, DEFAULT_GROUP_SUFFIX);
      const groupsByName: Map<string, FeedGroup> = new Map<string, FeedGroup>();
      const groups: FeedGroup[] = [];

      for (const subscription of subscriptions) {
        if (!subscription.id) {
          throw new Error('feed id is null');
        }
        const feedUrl: string | undefined = subscription.url ?? subscription.htmlUrl;
        if (!feedUrl) {
          throw new Error('feed url is null');
        }
        const category = subscription.categories && subscription.categories.length > 0
          ? subscription.categories[0]
          : undefined;
        const groupName: string = category
          ? String(category.label)
          : '默认';
        const groupId: string = category && category.id
          ? dbId(account.id, categoryIdFromStreamId(category.id))
          : defaultGroupId;
        if (!groupsByName.has(groupId)) {
          const group: FeedGroup = { id: groupId, name: groupName, sortOrder: 0 };
          groupsByName.set(groupId, group);
          groups.push(group);
          keepGroupIds.push(groupId);
        }
        const feed: Feed = {
          id: dbId(account.id, feedIdFromStreamId(subscription.id)),
          title: XmlParser.normalizeFullWidth(XmlParser.decode(subscription.title)),
          url: feedUrl,
          groupId: groupId,
          iconUrl: subscription.iconUrl ?? '',
          sortOrder: keepFeedIds.length,
          unreadCount: 0,
          starredCount: 0,
        };
        await database.upsertFeed(feed, account.id);
        keepFeedIds.push(feed.id);
      }
      groups.sort((a: FeedGroup, b: FeedGroup) => a.name.localeCompare(b.name));
      for (let i = 0; i < groups.length; i++) {
        groups[i].sortOrder = i;
        await database.upsertGroup(groups[i], account.id);
      }

      // One state scan replaces three full-table id queries (all / read /
      // starred) plus the per-id indexOf scans used to dedupe fetches.
      const localRemoteIds: Set<string> = new Set<string>();
      const toRead: string[] = [];
      const toUnread: string[] = [];
      const toStar: string[] = [];
      const toUnstar: string[] = [];
      {
        // Scope the full ArticleState[] so it becomes collectible before the
        // long content-fetch loop (previously it stayed alive to end of sync).
        const localStates: ArticleState[] = await database.listArticleStates(account.id);
        for (const state of localStates) {
          const id: string = remoteId(state.id);
          localRemoteIds.add(id);
          // Do not reconcile an id whose mark is still pending locally: the
          // server view is stale and would revert the user's just-changed state.
          if (pendingStatusRegistry.has(state.id)) {
            continue;
          }
          // unreadSet is COMPLETE (no ot), so it is authoritative in both
          // directions. FreshRSS's ot filters on crawl time, not read time, so
          // a read-ID stream cannot detect old articles read by another client.
          if (reconcileReadState) {
            if (state.isRead && unreadSet.has(id)) toUnread.push(state.id);
            if (!state.isRead && !unreadSet.has(id)) toRead.push(state.id);
          }
          if (reconcileStarState) {
            if (!state.isStarred && starredSet.has(id)) toStar.push(state.id);
            if (state.isStarred && !starredSet.has(id)) toUnstar.push(state.id);
          }
        }
      }
      await database.setStates(toRead, true, undefined);
      await database.setStates(toUnread, false, undefined);
      await database.setStates(toStar, undefined, true);
      await database.setStates(toUnstar, undefined, false);

      const toFetch: string[] = [];
      // Unread + starred + recently-read IDs all need content. The read IDs
      // cover the cross-client case where another client read a newly-arrived
      // article before we synced; its body must still be stored (isRead=true
      // is derived from !unreadSet.has(id) below). localRemoteIds is no longer
      // read after this block, so reuse it as the "already queued" marker.
      // Iterating the sets preserves order and dedupe.
      for (const id of unreadSet) {
        if (!localRemoteIds.has(id)) {
          localRemoteIds.add(id);
          toFetch.push(id);
        }
      }
      for (const id of starredSet) {
        if (!localRemoteIds.has(id)) {
          localRemoteIds.add(id);
          toFetch.push(id);
        }
      }
      for (const id of recentReadIds) {
        if (!localRemoteIds.has(id)) {
          localRemoteIds.add(id);
          toFetch.push(id);
        }
      }
      // Collect notification candidates per feed and publish once at the end:
      // notifying inside the batch loop sent the same feed's notification again
      // for every batch, and re-read the whole feed list each time.
      const notifyByFeed: Map<string, FeedNotify> = new Map<string, FeedNotify>();
      // Build only batch indexes, not a full 2D copy of every id: each worker
      // slices its own batch and drops it after the insert. Lower peak memory
      // on a first sync with tens of thousands of ids.
      const batchCount: number = Math.ceil(toFetch.length / batchSize);
      const batchIndexes: number[] = [];
      for (let i: number = 0; i < batchCount; i++) {
        batchIndexes.push(i);
      }
      // Shared bounded runner: at most SYNC_CONCURRENCY requests in flight.
      // Inserts are serialized by Database.withTransaction, so only network
      // work overlaps. The UI becomes ready after the FIRST committed batch;
      // every remaining batch then updates badges silently.
      await forEachLimited(batchIndexes, async (index: number): Promise<void> => {
        const batch: string[] = toFetch.slice(index * batchSize, (index + 1) * batchSize);
        let contents: ItemsContentsResult;
        try {
          contents = await api.getItemsContents(batch);
        } catch (error) {
          // A failed batch must not abort the sync, but a fully broken content
          // endpoint must not be reported as success either.
          Logger.warn(`GReader contents batch failed: ${(error as Error).message}`);
          result.failed++;
          return;
        }
        const articles: Article[] = [];
        for (const item of contents.items) {
          if (!isValidItemId(item.id)) {
            continue;
          }
          const streamId: string | undefined = item.origin?.streamId;
          if (!streamId) {
            Logger.error(`GReader item ${item.id} has no origin.streamId; skipping`);
            continue;
          }
          const id: string = shortItemId(item.id);
          const publishedSec: number = item.published ?? Math.floor(now / 1000);
          const published: number = publishedSec * 1000;
          articles.push({
            id: dbId(account.id, id),
            feedId: dbId(account.id, feedIdFromStreamId(streamId)),
            feedTitle: XmlParser.decode(item.origin?.title),
            title: XmlParser.decode(item.title),
            author: item.author ?? '',
            link: item.canonical?.[0]?.href ?? item.alternate?.[0]?.href ?? item.origin?.htmlUrl ?? '',
            summary: this.plainText(item.summary?.content ?? '').substring(0, 280),
            content: item.summary?.content ?? '',
            imageUrl: this.firstImage(item.summary?.content ?? ''),
            publishedAt: published > now ? now : published,
            // If the unread stream was truncated, absence from the partial set
            // does NOT mean read. Fall back to the ot read stream; unknown
            // entries stay unread so they are not silently hidden from the user.
            isRead: item.categories !== undefined && item.categories.length > 0
              ? item.categories.indexOf(READ_TAG) >= 0
              : (reconcileReadState ? !unreadSet.has(id) : recentReadSet.has(id)),
            isStarred: item.categories !== undefined && item.categories.length > 0
              ? item.categories.indexOf(STARRED_TAG) >= 0
              : starredSet.has(id),
            fullContent: '',
          });
        }
        if (articles.length === 0) {
          return;
        }
        result.newArticles += await database.insertArticles(articles, account.id);
        notifySyncBatch();
        uiReady.fire();
        for (const article of articles) {
          if (article.isRead) {
            continue;
          }
          const entry: FeedNotify | undefined = notifyByFeed.get(article.feedId);
          if (entry === undefined) {
            notifyByFeed.set(article.feedId, {
              feedTitle: article.feedTitle, firstTitle: article.title, count: 1,
            });
          } else {
            entry.count += 1;
          }
        }
      }, SYNC_CONCURRENCY);
      Logger.info(`GReader sync meta+db+contents: ${Date.now() - phaseTime}ms`);
      phaseTime = Date.now();
      NotificationHelper.notifyAll(notifyByFeed);

      // All readable content is committed. Stop the spinner now even if there
      // were no new articles (toFetch empty), before the slow reconciliation.
      notifyContentReady();

      // Read-state reconciliation now happens in the single state scan above
      // using the complete unread ID set; the ot-based read stream is only for
      // fetching bodies of articles another client read since our last sync.

      await database.deleteFeedsExcept(account.id, keepFeedIds);
      await database.deleteGroupsExcept(account.id, keepGroupIds);
      // Update only the sync cursor: a full REPLACE would overwrite any account
      // settings the user changed while this sync was running.
      await database.updateAccountSyncState(account.id, now, account.lastArticleId);
      Logger.info(`GReader sync reconcile+prune: ${Date.now() - phaseTime}ms; total: ${Date.now() - now}ms`);
      result.succeeded = 1;
      // Fallback when toFetch was empty: nothing was committed, so no batch
      // fired the signal. One-shot guard makes this a no-op otherwise.
      uiReady.fire();
    } catch (error) {
      Logger.error(`GReader sync failed: ${(error as Error).message}`);
      result.failed = 1;
      throw error as Error;
    }
    return result;
  }

  // ----------------------------- write operations --------------------------

  async markRead(
    account: Account, articleIds: string[], read: boolean, before?: number
  ): Promise<string[]> {
    if (articleIds.length === 0) {
      return [];
    }
    const api: GoogleReaderApi = this.api(account);
    const done: string[] = [];
    for (const batch of await this.chunks(articleIds, 500)) {
      // One batched UPDATE for the whole chunk instead of one write per id.
      await database.setStates(batch, read, undefined);
      try {
        const remote: string[] = batch.map((id: string) => remoteId(id));
        if (read) {
          await api.editTag(remote, READ_TAG, undefined);
        } else {
          await api.editTag(remote, undefined, READ_TAG);
        }
        // Only report ids whose remote tag edit actually succeeded. Failed
        // batches are kept by ReadStatusBatcher for a bounded background retry
        // (mirrors Android's pendingSyncDiffs -= synced).
        for (const id of batch) {
          done.push(id);
        }
      } catch (error) {
        Logger.error(`GReader editTag read failed: ${(error as Error).message}`);
      }
    }
    return done;
  }

  async markAllRead(
    account: Account, feedId: string, groupId: string, read: boolean, before?: number
  ): Promise<void> {
    if (!read) {
      // No bulk "mark all unread" endpoint: fall back to explicit ids.
      const ids: string[] = await database.listArticleIds(account.id, 'read', feedId, groupId, before);
      await this.markRead(account, ids, false, before);
      return;
    }
    const streamId: string = feedId.length > 0
      ? feedStreamId(remoteId(feedId))
      : groupId.length > 0 ? categoryStreamId(remoteId(groupId)) : READING_LIST_STREAM;
    const since: number | undefined = before !== undefined ? Math.floor(before / 1000) : undefined;
    await this.api(account).markAllAsRead(streamId, since);
    if (feedId.length > 0) {
      await database.setStatesByFeed(account.id, feedId, true, before);
    } else if (groupId.length > 0) {
      await database.setStatesByGroup(account.id, groupId, true, before);
    } else {
      await database.setAllRead(account.id, true, before);
    }
  }

  async markReadGroup(account: Account, groupId: string, read: boolean, before?: number): Promise<void> {
    const api: GoogleReaderApi = this.api(account);
    try {
      await api.markAllAsRead(categoryStreamId(remoteId(groupId)), before);
    } catch (error) {
      Logger.error(`GReader markGroup failed: ${(error as Error).message}`);
    }
  }

  async markReadFeed(account: Account, feedId: string, read: boolean, before?: number): Promise<void> {
    await database.setStatesByFeed(account.id, feedId, read);
    const api: GoogleReaderApi = this.api(account);
    try {
      await api.markAllAsRead(feedStreamId(remoteId(feedId)), before);
    } catch (error) {
      Logger.error(`GReader markFeed failed: ${(error as Error).message}`);
    }
  }

  async markStarred(account: Account, article: Article, starred: boolean): Promise<void> {
    await this.markStarredBatch(account, [article.id], starred);
  }

  async markStarredBatch(account: Account, articleIds: string[], starred: boolean): Promise<string[]> {
    if (articleIds.length === 0) {
      return [];
    }
    // One batched DB UPDATE and one batched tag edit (GReader accepts many ids).
    await database.setStates(articleIds, undefined, starred);
    const api: GoogleReaderApi = this.api(account);
    const remote: string[] = articleIds.map((id: string): string => remoteId(id));
    try {
      if (starred) {
        await api.editTag(remote, STARRED_TAG, undefined);
      } else {
        await api.editTag(remote, undefined, STARRED_TAG);
      }
      return articleIds;
    } catch (error) {
      Logger.error(`GReader batch star failed: ${(error as Error).message}`);
      return [];
    }
  }

  async fetchContent(account: Account, article: Article): Promise<string> {
    const api: GoogleReaderApi = this.api(account);
    const contents: ItemsContentsResult = await api.getItemsContents([remoteId(article.id)]);
    for (const item of contents.items) {
      if (isValidItemId(item.id) && shortItemId(item.id) === remoteId(article.id)) {
        return item.summary?.content ?? '';
      }
    }
    return '';
  }

  async deleteFeed(account: Account, feedId: string): Promise<void> {
    const api: GoogleReaderApi = this.api(account);
    await api.subscriptionEdit('unsubscribe', feedStreamId(remoteId(feedId)), '', '', '');
    await database.deleteFeedPreservingStarred(feedId);
  }

  // -------------------------------- helpers --------------------------------

  private plainText(html: string): string {
    const cleaned: string = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ');
    return XmlParser.decode(cleaned.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ')).trim();
  }

  private firstImage(html: string): string {
    const enclosure: Array<string> | null = html.match(/<enclosure\s+url="([^"]+)"\s+type="[^"]*"\s*\/>/);
    if (enclosure && enclosure.length > 1 && enclosure[1]) return enclosure[1];
    const match: Array<string> | null = html.match(/img.*?src=(["'])((?!data)[\s\S]*?)\1/i);
    return match && match.length > 2 && !match[2].startsWith('data:') ? match[2] : '';
  }
}
