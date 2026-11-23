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
import { beginSync, notifySyncBatch, notifySyncFinal, notifyContentReady } from './SyncProgress';
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
    await database.deleteGroupsExcept(account.id, [group.id]);
  }

  // ------------------------------ ID stream helpers ------------------------

  private async allItemIds(
    api: GoogleReaderApi, base: ApiParams, maxPages: number = Number.MAX_SAFE_INTEGER
  ): Promise<string[]> {
    const ids: string[] = [];
    let continuation: string | undefined = undefined;
    let page: number = 0;
    for (;;) {
      if (page >= maxPages) {
        break;
      }
      page++;
      const params: ApiParams = {
        s: base.s, xt: base.xt, it: base.it, ot: base.ot, n: base.n, quickadd: base.quickadd,
      };
      if (continuation) {
        params.c = continuation;
      }
      let body: ItemIdsDto;
      try {
        body = await api.getItemIds(params);
      } catch (error) {
        Logger.error(`GReader ids page failed: ${(error as Error).message}`);
        break;
      }
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
    return ids;
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
    beginSync();
    try {
      const ok: boolean = await api.validCredentials();
      if (!ok) {
        throw new Error('Invalid credentials');
      }

      const isFreshRss: boolean = account.type === AccountType.FRESH_RSS;
      const since: number = Math.floor((now - 30 * 24 * 3600 * 1000) / 1000);
      const batchSize: number = settingsStore.get().fetchBatchSize;
      const readParams: ApiParams = isFreshRss
        ? { s: READING_LIST_STREAM, it: READ_TAG, ot: since.toString(), n: ID_PAGE_SIZE }
        : { s: READ_TAG, ot: since.toString(), n: ID_PAGE_SIZE };
      const unreadParams: ApiParams = { s: READING_LIST_STREAM, xt: READ_TAG, n: ID_PAGE_SIZE };
      const starredParams: ApiParams = { s: STARRED_TAG, n: ID_PAGE_SIZE };

      // Only unread + starred IDs are needed to fetch and render content. Fetch
      // these first so the first article batch can be shown quickly. The slow
      // read-ID reconciliation is deferred until after content is committed.
      // Build the sets directly: keeping both the id arrays and the sets held
      // two full copies of every id for the whole sync (tens of MB on a large
      // account). Set iteration order equals the original array order, so the
      // downstream toFetch order and dedupe behaviour are unchanged.
      const unreadSet: Set<string> = new Set<string>(await this.allItemIds(api, unreadParams));
      const starredSet: Set<string> = new Set<string>(await this.allItemIds(api, starredParams));

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
          title: XmlParser.decode(subscription.title),
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
          if (state.isRead && unreadSet.has(id)) toUnread.push(state.id);
          if (!state.isStarred && starredSet.has(id)) toStar.push(state.id);
          if (state.isStarred && !starredSet.has(id)) toUnstar.push(state.id);
        }
      }
      await database.setStates(toUnread, false, undefined);
      await database.setStates(toStar, undefined, true);
      await database.setStates(toUnstar, undefined, false);

      const toFetch: string[] = [];
      // Only unread + starred need content. Read ids are used purely for state
      // reconciliation. localRemoteIds is no longer read after this block, so
      // reuse it as the "already queued" marker and drop the duplicate `queued`
      // set. Iterating the sets preserves the original order and dedupe.
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
      // Collect notification candidates per feed and publish once at the end:
      // notifying inside the batch loop sent the same feed's notification again
      // for every batch, and re-read the whole feed list each time.
      const notifyByFeed: Map<string, FeedNotify> = new Map<string, FeedNotify>();
      for (const batch of await this.chunks(toFetch, batchSize)) {
        const contents: ItemsContentsResult = await api.getItemsContents(batch);
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
            isRead: !unreadSet.has(id),
            isStarred: starredSet.has(id),
            fullContent: '',
          });
        }
        result.newArticles += await database.insertArticles(articles, account.id);
        // Let the UI refresh unread badges after this batch, without waiting
        // for the remaining batches to finish.
        notifySyncBatch();
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
      }
      NotificationHelper.notifyAll(notifyByFeed);

      // All readable content is committed. Stop the spinner now even if there
      // were no new articles (toFetch empty), before the slow reconciliation.
      notifyContentReady();

      // Deferred, slow part: read-ID pages are only used to mark locally-unread
      // articles that the server considers read. By now content is committed and
      // the user can already read, so this runs silently in the background.
      // Convert the (at most 3000) remote read ids to dbId form once, instead
      // of allocating a short-id substring for every local unread row (100k
      // allocations on a large account). dbId/remoteId are inverse operations,
      // so membership results are identical.
      const readSet: Set<string> = new Set<string>(
        (await this.allItemIds(api, readParams, READ_ID_PAGES))
          .map((id: string): string => dbId(account.id, id))
      );
      const localUnread: string[] = await database.listRemoteIds(account.id, false);
      const toRead: string[] = [];
      for (const dbIdValue of localUnread) {
        if (!pendingStatusRegistry.has(dbIdValue) && readSet.has(dbIdValue)) {
          toRead.push(dbIdValue);
        }
      }
      if (toRead.length > 0) {
        await database.setStates(toRead, true, undefined);
      }

      await database.deleteFeedsExcept(account.id, keepFeedIds);
      await database.deleteGroupsExcept(account.id, keepGroupIds);
      account.updateAt = now;
      await database.updateAccount(account);
      result.succeeded = 1;
      notifySyncFinal();
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
