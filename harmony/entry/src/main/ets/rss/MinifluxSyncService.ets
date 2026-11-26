import { Account, AccountType, dbId, remoteId } from '../account/AccountModels';
import { accountRepository } from '../account/AccountRepository';
import { database } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import { Article, Feed, FeedGroup } from '../model/Models';
import {
  beginSync, notifySyncBatch, notifyContentReady, UiReadySignal,
} from './SyncProgress';
import { forEachLimited, SYNC_CONCURRENCY, UI_WINDOW_SIZE } from './SyncRuntime';
import {
  MinifluxApi, MinifluxCategory, MinifluxEntry, MinifluxEntryParams, MinifluxFeed, MinifluxFeedIcon,
  iconDataUrl, isUnsupportedStarFieldError, isNotFoundError, errorText,
} from './MinifluxApi';
import { FeedNotify, FeedSyncService, SyncResult } from './SyncService';
import { Logger } from '../common/Logger';
import { NotificationHelper } from '../common/NotificationHelper';
import { pendingStatusRegistry } from './PendingStatusRegistry';
import { XmlParser } from './XmlParser';
import { parseEntryPublishedAt } from './EntryPublishedTime';
import { normalizeFeedText } from '../model/FeedDisplay';

const DEFAULT_GROUP_TITLE: string = 'Defaults';
/** Miniflux caps /v1/entries at 1000; 100 keeps responses small and is stable
 *  across versions. Decoupled from the UI's fetchBatchSize. */
export const ENTRY_PAGE_SIZE: number = 300;
/** Fresh-sync first-screen budget: at most 9000 newest entries per stream.
 *  Older history beyond this is intentionally NOT imported: the cursor is a
 *  high-water mark, so incremental syncs only see ids above it and will not
 *  revisit the skipped tail. Keeping the bound avoids a multi-hundred-MB first
 *  sync; raise it if full-history import is required. */
export const MAX_FRESH_BODY_PAGES: number = 30;
/** Miniflux allows up to 10,000 ids per response. Using the maximum turns a
 *  large unread stream into ONE request instead of ten sequential OFFSET pages
 *  (OFFSET paging gets progressively slower on a big entries table). */
const ID_LIST_PAGE_SIZE: number = 10000;
const WRITE_CHUNK_SIZE: number = 500;

interface IconFetch {
  iconId: number;
  feedId: number;
}

/** Sync service for Miniflux's native REST API (not the GReader-compatible
 *  endpoint). Uses API tokens or HTTP Basic auth; see MinifluxApi. */
export class MinifluxSyncService implements FeedSyncService {
  readonly canImportSubscription: boolean = false;
  readonly canAddSubscription: boolean = true;
  readonly canMoveSubscription: boolean = true;
  readonly canDeleteSubscription: boolean = true;
  readonly canUpdateSubscription: boolean = true;

  private api(account: Account): MinifluxApi {
    const credentials = accountRepository.credentials(account);
    return new MinifluxApi(credentials.serverUrl, credentials.username, credentials.password);
  }

  private lastCredentialError: string = '';

  /** Detailed reason of the last failed credential check, for the add-account UI. */
  lastError(): string {
    return this.lastCredentialError;
  }

  async validCredentials(account: Account): Promise<boolean> {
    const api: MinifluxApi = this.api(account);
    const ok: boolean = await api.validCredentials();
    this.lastCredentialError = api.lastError();
    return ok;
  }

  clearAuthorization(): void {
    // Each call builds a fresh API instance; no shared token cache.
  }

  /** Sync must never mutate the server. If the account has no categories,
   *  place uncategorised feeds in a purely local group (id 0). */
  private defaultCategoryId(categories: MinifluxCategory[]): number {
    return categories.length > 0 ? categories[0].id : 0;
  }

  async subscribe(account: Account, url: string): Promise<Feed> {
    const api: MinifluxApi = this.api(account);
    const categories: MinifluxCategory[] = await api.getCategories();
    let categoryId: number = this.defaultCategoryId(categories);
    if (categoryId === 0) {
      // A real category is required by POST /v1/feeds; only a user-initiated
      // subscribe may create one (sync itself never mutates the server).
      categoryId = await api.createCategory(DEFAULT_GROUP_TITLE);
    }
    const remoteFeedId: number = await api.createFeed(url, categoryId);
    const groupId: string = dbId(account.id, String(categoryId));
    const feed: Feed = {
      id: dbId(account.id, String(remoteFeedId)),
      title: url,
      url: url,
      groupId: groupId,
      iconUrl: '',
      sortOrder: 0,
      unreadCount: 0,
      starredCount: 0,
    };
    await database.upsertFeed(feed, account.id);
    return feed;
  }

  async addGroup(account: Account, name: string): Promise<FeedGroup> {
    const id: number = await this.api(account).createCategory(name);
    const group: FeedGroup = { id: dbId(account.id, String(id)), name: name, sortOrder: 0 };
    await database.upsertGroup(group, account.id);
    return group;
  }

  async renameGroup(account: Account, group: FeedGroup): Promise<void> {
    await this.api(account).updateCategory(this.remoteNumber(group.id), group.name);
    await database.upsertGroup(group, account.id);
  }

  async renameFeed(account: Account, feed: Feed): Promise<void> {
    await this.api(account).updateFeed(this.remoteNumber(feed.id), feed.title);
    await database.upsertFeed(feed, account.id);
  }

  async moveFeed(account: Account, originGroupId: string, feed: Feed): Promise<void> {
    await this.api(account).updateFeed(this.remoteNumber(feed.id), undefined, this.remoteNumber(feed.groupId));
    await database.upsertFeed(feed, account.id);
  }

  async deleteGroup(account: Account, group: FeedGroup): Promise<void> {
    const feeds: Feed[] = (await database.listFeeds(account.id)).filter(
      (feed: Feed): boolean => feed.groupId === group.id
    );
    for (const feed of feeds) {
      await this.deleteFeed(account, feed.id);
    }
    await this.api(account).deleteCategory(this.remoteNumber(group.id));
    const remaining: string[] = (await database.listGroups(account.id))
      .map((item: FeedGroup): string => item.id).filter((id: string): boolean => id !== group.id);
    await database.deleteGroupsExcept(account.id, remaining);
  }

  private remoteNumber(id: string): number {
    const value: number = Number.parseInt(remoteId(id), 10);
    if (Number.isNaN(value)) {
      throw new Error(`Invalid Miniflux id: ${id}`);
    }
    return value;
  }

  private remoteNumbers(ids: string[]): number[] {
    return ids.map((id: string): number => this.remoteNumber(id));
  }

  /** High-water mark persisted in Account.lastArticleId (dbId form). */
  private lastMaxEntryId(account: Account): number {
    if (!account.lastArticleId) return 0;
    const value: number = Number.parseInt(remoteId(account.lastArticleId), 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /** The first visible batch must be ordered like the list itself
   *  (published_at DESC, id DESC), NOT by entry id. Some feeds publish entries
   *  whose id order disagrees with their date; fetching by id made the first
   *  batch miss articles that later appeared on top during the full sync
   *  (abcd -> 1234abcd). The cursor still filters by id; only sort changes. */
  firstScreenParams(freshSync: boolean, lastMaxId: number): MinifluxEntryParams {
    if (freshSync) {
      return {
        status: 'unread', limit: UI_WINDOW_SIZE, order: 'published_at', direction: 'desc',
      };
    }
    return {
      afterEntryId: lastMaxId, limit: UI_WINDOW_SIZE, order: 'published_at', direction: 'desc',
    };
  }

  /**
   * Streams used for the body fetch.
   * - Fresh sync (no cursor): only unread + starred bodies are fetched. An
   *   unfiltered fetch of the entire history would transfer every read entry's
   *   HTML and time out on a large account; read+unstarred bodies are fetched
   *   on demand by FullContentFetcher when the article is opened.
   * - Incremental sync: a single UNFILTERED stream from the cursor. An entry
   *   that arrived after our last sync but was read (and not starred) by
   *   another client is in neither the unread nor the starred stream, so
   *   filtering by status would silently drop its body.
   * - Legacy server (no /entries/ids): full unread + starred streams rebuild
   *   the authoritative state sets, then the same unfiltered incremental stream.
   */
  private bodyFetchStreams(
    idsAvailable: boolean, lastMaxId: number, freshSync: boolean
  ): MinifluxEntryParams[] {
    if (freshSync) {
      return [
        { status: 'unread', afterEntryId: 0 },
        { starred: true, afterEntryId: 0 },
      ];
    }
    if (idsAvailable) {
      return [{ afterEntryId: lastMaxId }];
    }
    return [
      { status: 'unread', afterEntryId: 0 },
      { starred: true, afterEntryId: 0 },
      { afterEntryId: lastMaxId },
    ];
  }

  /** Fetch a complete id-only stream straight into the target Set. Keeping one
   *  Set instead of an array + Set copy halves peak memory on large accounts.
   *  Returns the highest id seen for the sync cursor. */
  private async collectEntryIds(
    api: MinifluxApi, into: Set<string>, status?: string, starred?: boolean
  ): Promise<number> {
    let max: number = 0;
    for (let offset: number = 0; ; offset += ID_LIST_PAGE_SIZE) {
      const page: number[] = await api.getEntryIds({
        status: status, starred: starred, offset: offset, limit: ID_LIST_PAGE_SIZE,
      });
      for (const id of page) {
        into.add(String(id));
        if (id > max) {
          max = id;
        }
      }
      if (page.length < ID_LIST_PAGE_SIZE) {
        break;
      }
    }
    return max;
  }

  async sync(account: Account): Promise<SyncResult> {
    if (account.type !== AccountType.MINIFLUX) {
      throw new Error('account type is invalid');
    }
    const preTime: number = Date.now();
    let phaseTime: number = preTime;
    const api: MinifluxApi = this.api(account);
    const result: SyncResult = { succeeded: 0, failed: 0, newArticles: 0 };
    beginSync();
    const uiReady: UiReadySignal = new UiReadySignal(preTime);
    try {
      const lastMaxId: number = this.lastMaxEntryId(account);
      const freshSync: boolean = lastMaxId === 0;
      // First-screen fast path (BOTH fresh and incremental): one small window
      // of bodies is committed BEFORE any metadata/ID work, so the list appears
      // immediately. Fresh syncs take the newest unread; incremental syncs take
      // an unfiltered window after the cursor so a cross-client-read entry is
      // still shown. The normal sync below reads knownIds from the DB and will
      // not re-insert these rows.
      {
        const cachedFeeds: Feed[] = await database.listFeeds(account.id);
        const firstTitles: Map<string, string> = new Map<string, string>();
        for (const feed of cachedFeeds) {
          firstTitles.set(feed.id, feed.title);
        }
        const firstOptions: MinifluxEntryParams =
          this.firstScreenParams(freshSync, lastMaxId);
        const firstPage = await api.getEntries(firstOptions);
        const firstArticles: Article[] = [];
        for (const entry of firstPage.entries ?? []) {
          // INSERT OR REPLACE would wipe a locally pending mark's DB copy.
          if (pendingStatusRegistry.has(dbId(account.id, String(entry.id)))) {
            continue;
          }
          const article: Article | undefined = this.buildArticle(
            account, entry, firstTitles, preTime
          );
          if (article !== undefined) {
            firstArticles.push(article);
          }
        }
        if (firstArticles.length > 0) {
          result.newArticles += await database.insertArticles(firstArticles, account.id);
          notifySyncBatch();
        }
        // Fire even when there is nothing new: the existing list is already
        // readable, so the UI must not wait for the full sync to stop spinning.
        uiReady.fire();
        Logger.info(`Miniflux first-screen window: ${firstArticles.length} articles`);
      }

      // Everything needed to build an article is read from the local DB up
      // front. Remote categories/feeds/icons are fetched AFTER the UI is ready
      // so they never delay the first screen.
      const batchSize: number = Math.max(1, settingsStore.get().fetchBatchSize);
      const pageSize: number = ENTRY_PAGE_SIZE;
      let maxEntryId: number = lastMaxId;
      // listRemoteIds returns DB primary keys (account$id), but everywhere in
      // this service ids are RAW server ids. Normalise here: without this,
      // dedupe fails and reconciliation builds double-prefixed ids that match
      // no row, so pre-existing articles never pick up cross-client marks.
      const knownIds: Set<string> = new Set<string>();
      for (const storedId of await database.listRemoteIds(account.id)) {
        knownIds.add(remoteId(storedId));
      }
      const feedTitles: Map<string, string> = new Map<string, string>();
      for (const feed of await database.listFeeds(account.id)) {
        feedTitles.set(feed.id, feed.title);
      }
      const unreadIds: Set<string> = new Set<string>();
      const starredIds: Set<string> = new Set<string>();
      // False when a transient ID fetch failed: keep the previous server state
      // instead of reconciling against empty sets (which would mark all read).
      let stateIdsAvailable: boolean = true;
      const notifyByFeed: Map<string, FeedNotify> = new Map<string, FeedNotify>();
      let pendingArticles: Article[] = [];

      const insertPending = async (): Promise<void> => {
        for (let i = 0; i < pendingArticles.length; i += batchSize) {
          const chunk: Article[] = pendingArticles.slice(i, i + batchSize);
          result.newArticles += await database.insertArticles(chunk, account.id);
          notifySyncBatch();
          // First committed batch fills the visible window + buffer: the UI is
          // usable now, remaining bodies are fetched silently.
          uiReady.fire();
        }
        pendingArticles = [];
      };
      const addNew = (entry: MinifluxEntry): void => {
        const id: string = String(entry.id);
        if (knownIds.has(id) || pendingStatusRegistry.has(dbId(account.id, id))
          || entry.feed_id === undefined || entry.feed_id === null) {
          return;
        }
        const article: Article | undefined = this.buildArticle(
          account, entry, feedTitles, preTime
        );
        if (article === undefined) {
          return;
        }
        pendingArticles.push(article);
        knownIds.add(id);
        if (!article.isRead) {
          const existing: FeedNotify | undefined = notifyByFeed.get(article.feedId);
          if (existing === undefined) {
            notifyByFeed.set(article.feedId, {
              feedTitle: article.feedTitle, firstTitle: article.title, count: 1,
            });
          } else {
            existing.count += 1;
          }
        }
      };

      // State-ID streams are deliberately NOT in the first-screen path. On a
      // fresh sync the unread/starred body streams collect state themselves; on
      // incremental syncs the ID-only sets are fetched after the UI is ready.
      // The modern /entries/ids endpoint is assumed below; old servers fall
      // back to full streams in the catch block.

      // Body fetch: only entries newer than the last sync cursor, using the
      // stable `after_entry_id` cursor instead of offset paging so items added
      // mid-sync cannot shift the window and be skipped. Streams are chosen by
      // bodyFetchStreams(); the unfiltered one is essential so a cross-client
      // read entry is not silently dropped (addNew dedupes any overlap).
      const fetchBodies = async (
        status: string | undefined, starred: boolean | undefined,
        startCursor: number, collectState: boolean
      ): Promise<void> => {
        // Descending cursor paging: the FIRST page holds the newest entries, so
        // the first committed batch (which stops the spinner and reloads the
        // list) shows what the user expects. `after_entry_id` stays fixed at the
        // high-water mark while `before_entry_id` walks down for later pages —
        // stable even if new entries arrive mid-sync (unlike offset paging).
        let before: number | undefined = undefined;
        let pages: number = 0;
        for (;;) {
          pages++;
          const options: MinifluxEntryParams = {
            status: status, starred: starred, afterEntryId: startCursor,
            beforeEntryId: before, limit: pageSize, order: 'id', direction: 'desc',
          };
          const page = await api.getEntries(options);
          const items: MinifluxEntry[] = page.entries ?? [];
          for (const entry of items) {
            if (entry.id > maxEntryId) maxEntryId = entry.id;
            if (collectState) {
              if (entry.status === 'unread') unreadIds.add(String(entry.id));
              if (entry.starred === true) starredIds.add(String(entry.id));
            }
            addNew(entry);
          }
          await insertPending();
          if (items.length < pageSize) break;
          if (freshSync && pages >= MAX_FRESH_BODY_PAGES) break;
          before = items[items.length - 1].id;
        }
      };
      for (const stream of this.bodyFetchStreams(true, lastMaxId, lastMaxId === 0)) {
        await fetchBodies(
          stream.status, stream.starred, stream.afterEntryId ?? 0,
          stream.status !== undefined || stream.starred !== undefined
        );
      }
      if (lastMaxId === 0) {
        // Fresh sync also stores a small UNFILTERED window so an entry that
        // arrived and was read (not starred) by another client is not skipped.
        // Never advance the cursor from a probe: only entries we actually store
        // may move it, otherwise that entry's body is lost forever.
        const window = await api.getEntries({
          limit: UI_WINDOW_SIZE, order: 'id', direction: 'desc',
        });
        for (const entry of window.entries ?? []) {
          if (entry.id > maxEntryId) maxEntryId = entry.id;
          addNew(entry);
        }
        await insertPending();
      }
      // Deferred state-ID fetch (incremental only). It used to run before the
      // body fetch and delayed the first screen; now it happens after the UI
      // is ready. Fresh syncs already collected state from the body streams.
      if (lastMaxId > 0) {
        try {
          const maxima: [number, number] = await Promise.all([
            this.collectEntryIds(api, unreadIds, 'unread', undefined),
            this.collectEntryIds(api, starredIds, undefined, true),
          ]);
          if (maxima[0] > maxEntryId) maxEntryId = maxima[0];
          if (maxima[1] > maxEntryId) maxEntryId = maxima[1];
        } catch (error) {
          unreadIds.clear();
          starredIds.clear();
          if (isNotFoundError(error as Error)) {
            Logger.warn(`Miniflux entries/ids unsupported, using full streams: ${(error as Error).message}`);
            // /v1/entries/ids needs Miniflux >= 2.3.2: rebuild state from full
            // streams. Bodies from the cursor are already stored; addNew skips
            // rows we have.
            await fetchBodies('unread', undefined, 0, true);
            await fetchBodies(undefined, true, 0, true);
          } else {
            // 5xx / timeout / malformed body: never fall back to a full-history
            // fetch or reconcile against empty sets. Skip this round's state
            // update and retry on the next sync.
            stateIdsAvailable = false;
            // State could not be verified: never report a clean success.
            result.failed++;
            Logger.warn(`Miniflux entries/ids unavailable, skipping state sync: ${(error as Error).message}`);
          }
        }
      }
      Logger.info(`Miniflux sync ids+bodies: ${Date.now() - phaseTime}ms`);
      phaseTime = Date.now();
      NotificationHelper.notifyAll(notifyByFeed);
      notifyContentReady();

      // REMOTE METADATA — deliberately after the UI is ready. Categories and
      // feeds only drive group/feed upserts and pruning; they are not needed to
      // render articles, so they must not sit in the first-screen path.
      const metadata: [MinifluxCategory[], MinifluxFeed[]] = await Promise.all([
        api.getCategories(), api.getFeeds(),
      ]);
      const categories: MinifluxCategory[] = metadata[0];
      const remoteFeeds: MinifluxFeed[] = metadata[1];
      if (categories.length === 0) {
        // Miniflux always has at least the "All" category. An empty response is
        // a transport/server problem — continuing would move every feed into a
        // fake group and then prune the real ones.
        throw new Error('Miniflux returned no categories');
      }
      const defaultCategoryId: number = this.defaultCategoryId(categories);

      const keepGroupIds: string[] = [];
      for (let i = 0; i < categories.length; i++) {
        const group: FeedGroup = {
          id: dbId(account.id, String(categories[i].id)),
          name: categories[i].title ?? 'Empty',
          sortOrder: i,
        };
        await database.upsertGroup(group, account.id);
        keepGroupIds.push(group.id);
      }
      const defaultGroupId: string = dbId(account.id, String(defaultCategoryId));
      if (keepGroupIds.indexOf(defaultGroupId) < 0) {
        const group: FeedGroup = { id: defaultGroupId, name: DEFAULT_GROUP_TITLE, sortOrder: 0 };
        await database.upsertGroup(group, account.id);
        keepGroupIds.push(defaultGroupId);
      }

      const existingFeeds: Map<string, Feed> = new Map<string, Feed>();
      for (const feed of await database.listFeeds(account.id)) {
        existingFeeds.set(feed.id, feed);
      }
      // Icons change rarely: reuse stored data URIs and fetch only missing ones
      // with the same bounded concurrency as the rest of the sync.
      const iconById: Map<number, string> = new Map<number, string>();
      const iconFetches: IconFetch[] = [];
      for (const remote of remoteFeeds) {
        const old: Feed | undefined = existingFeeds.get(dbId(account.id, String(remote.id)));
        const iconId: number | undefined = remote.icon?.icon_id;
        if ((old?.iconUrl ?? '').length === 0 && iconId !== undefined && iconId > 0
          && !iconById.has(iconId)) {
          iconById.set(iconId, '');
          iconFetches.push({ iconId: iconId, feedId: remote.id });
        }
      }
      if (iconFetches.length > 0) {
        await forEachLimited(iconFetches, async (item: IconFetch): Promise<void> => {
          try {
            const body = await api.getIcon(item.feedId);
            iconById.set(item.iconId, body !== undefined && body.data !== undefined
              ? iconDataUrl(body.data, body.mime_type) : '');
          } catch (error) {
            // A single broken icon must not fail the whole sync.
            iconById.set(item.iconId, '');
          }
        }, SYNC_CONCURRENCY);
      }

      const keepFeedIds: string[] = [];
      for (let i = 0; i < remoteFeeds.length; i++) {
        const remote: MinifluxFeed = remoteFeeds[i];
        const categoryId: number = remote.category?.id ?? defaultCategoryId;
        const groupId: string = dbId(account.id, String(categoryId));
        const feedId: string = dbId(account.id, String(remote.id));
        const old: Feed | undefined = existingFeeds.get(feedId);
        let icon: string = old?.iconUrl ?? '';
        if (icon.length === 0) {
          const iconId: number | undefined = remote.icon?.icon_id;
          if (iconId !== undefined) {
            icon = iconById.get(iconId) ?? '';
          }
        }
        const local: Feed = {
          id: feedId,
          title: normalizeFeedText(XmlParser.decode(remote.title)) || 'Empty',
          url: normalizeFeedText(remote.feed_url ?? ''),
          groupId: groupId,
          iconUrl: icon,
          sortOrder: i,
          unreadCount: 0,
          starredCount: 0,
        };
        if (!old || old.title !== local.title || old.url !== local.url
          || old.groupId !== local.groupId || old.iconUrl !== local.iconUrl
          || old.sortOrder !== local.sortOrder) {
          await database.upsertFeed(local, account.id);
        }
        keepFeedIds.push(feedId);
        feedTitles.set(feedId, local.title);
      }
      // First-screen articles were built before remote feed titles existed.
      await database.fillMissingFeedTitles();
      Logger.info(`Miniflux sync remote metadata: ${Date.now() - phaseTime}ms`);
      phaseTime = Date.now();

      // Server state is authoritative; skip ids with locally pending marks so
      // reconciliation cannot revert the user's just-changed state.
      // Iterate the existing set directly — Array.from(knownIds) would allocate
      // a second full copy of every id just before the heaviest DB writes.
      if (stateIdsAvailable) {
        const toRead: string[] = [];
        const toUnread: string[] = [];
        const toStar: string[] = [];
        const toUnstar: string[] = [];
        for (const id of knownIds) {
          const localId: string = dbId(account.id, id);
          if (pendingStatusRegistry.has(localId)) {
            continue;
          }
          if (unreadIds.has(id)) {
            toUnread.push(localId);
          } else {
            toRead.push(localId);
          }
          if (starredIds.has(id)) {
            toStar.push(localId);
          } else {
            toUnstar.push(localId);
          }
        }
        await database.setStates(toRead, true, undefined);
        await database.setStates(toUnread, false, undefined);
        await database.setStates(toStar, undefined, true);
        await database.setStates(toUnstar, undefined, false);
      }

      // Prune one by one with deleteFeedPreservingStarred; deleteFeedsExcept
      // would also delete starred articles of removed feeds.
      for (const feed of await database.listFeeds(account.id)) {
        if (keepFeedIds.indexOf(feed.id) < 0) {
          await database.deleteFeedPreservingStarred(feed.id);
        }
      }
      await database.deleteGroupsExcept(account.id, keepGroupIds);

      // Persist only the sync cursor; avoid REPLACE-ing concurrent edits.
      const nextCursor: string | null = maxEntryId > lastMaxId
        ? dbId(account.id, String(maxEntryId)) : account.lastArticleId;
      await database.updateAccountSyncState(account.id, preTime, nextCursor);
      Logger.info(`Miniflux sync reconcile+prune: ${Date.now() - phaseTime}ms; total: ${Date.now() - preTime}ms`);
      result.succeeded = 1;
      // Fallback when no article was committed (nothing new on the server).
      uiReady.fire();
    } catch (error) {
      // Include a stack trace: a bare "cannot read property length" is not
      // enough to locate a malformed API response on a real device.
      const err: Error = error as Error;
      Logger.error(`Miniflux sync failed: ${err.message ?? String(error)}`);
      if (err.stack !== undefined) {
        Logger.error(`Miniflux sync stack: ${err.stack}`);
      }
      result.failed = 1;
      // Stop the spinner without claiming success; the UI shows the failure
      // toast from the repository's catch.
      notifyContentReady();
      throw err;
    }
    return result;
  }

  async markRead(
    account: Account, articleIds: string[], read: boolean, before?: number
  ): Promise<string[]> {
    void before; // Miniflux's batch endpoint has no date filter.
    if (articleIds.length === 0) {
      return [];
    }
    await database.setStates(articleIds, read, undefined);
    const api: MinifluxApi = this.api(account);
    const confirmed: string[] = [];
    const status: string = read ? 'read' : 'unread';
    // Chunk so one huge "mark all read" cannot exceed server limits or force
    // the retry queue to resend tens of thousands of ids on a single failure.
    for (let i = 0; i < articleIds.length; i += WRITE_CHUNK_SIZE) {
      const chunk: string[] = articleIds.slice(i, i + WRITE_CHUNK_SIZE);
      try {
        await api.updateEntries(this.remoteNumbers(chunk), status, undefined);
        confirmed.push(...chunk);
      } catch (error) {
        Logger.error(`Miniflux markRead failed for chunk ${i}: ${(error as Error).message}`);
      }
    }
    return confirmed;
  }

  async markReadGroup(
    account: Account, groupId: string, read: boolean, before?: number
  ): Promise<void> {
    const feeds: Feed[] = (await database.listFeeds(account.id)).filter(
      (feed: Feed): boolean => feed.groupId === groupId
    );
    for (const feed of feeds) {
      await this.markReadFeed(account, feed.id, read, before);
    }
  }

  async markReadFeed(
    account: Account, feedId: string, read: boolean, before?: number
  ): Promise<void> {
    const ids: string[] = await database.listArticleIds(account.id, 'all', feedId, undefined, before);
    if (ids.length === 0) {
      return;
    }
    await this.markRead(account, ids, read, before);
  }

  async markStarred(account: Account, article: Article, starred: boolean): Promise<void> {
    await this.markStarredBatch(account, [article.id], starred);
  }

  async markStarredBatch(
    account: Account, articleIds: string[], starred: boolean
  ): Promise<string[]> {
    if (articleIds.length === 0) {
      return [];
    }
    await database.setStates(articleIds, undefined, starred);
    const api: MinifluxApi = this.api(account);
    const confirmed: string[] = [];
    let fallback: boolean = false;
    for (let i = 0; i < articleIds.length; i += WRITE_CHUNK_SIZE) {
      const chunk: string[] = articleIds.slice(i, i + WRITE_CHUNK_SIZE);
      try {
        await api.updateEntries(this.remoteNumbers(chunk), undefined, starred);
        confirmed.push(...chunk);
      } catch (error) {
        const message: string = errorText(error as Object);
        // Only pre-2.3.2 servers that reject the `starred` field may use the
        // bookmark fallback. Auth/network/5xx errors must NOT toggle blindly:
        // a toggle that succeeded remotely but failed in transit would be
        // flipped back on retry.
        if (isUnsupportedStarFieldError(message)) {
          fallback = true;
          break;
        }
        Logger.error(`Miniflux star failed for chunk ${i}: ${message}`);
      }
    }
    if (fallback) {
      for (const id of articleIds) {
        try {
          const current = await api.getEntry(this.remoteNumber(id));
          if ((current.starred === true) !== starred) {
            await api.toggleBookmark(this.remoteNumber(id));
          }
          confirmed.push(id);
        } catch (error) {
          Logger.warn(`Miniflux bookmark fallback failed for ${id}: ${(error as Error).message}`);
        }
      }
    }
    return confirmed;
  }

  async deleteFeed(account: Account, feedId: string): Promise<void> {
    await this.api(account).deleteFeed(this.remoteNumber(feedId));
    await database.deleteFeedPreservingStarred(feedId);
  }

  async fetchContent(account: Account, article: Article): Promise<string> {
    // The RSS body, matching GReader/Fever semantics. Previously this used
    // /entries/{id}/fetch-content (the original-page scraper), which fetched
    // the same origin page again that fullContent already fetches locally.
    const entry: MinifluxEntry = await this.api(account).getEntry(this.remoteNumber(article.id));
    return entry.content ?? '';
  }

  /** Map one API entry to a local Article. The API already returns the full
   *  HTML body, so it is stored in `content` (and no extra body request is
   *  needed); `fullContent` is left for the optional original-page extractor. */
  private buildArticle(
    account: Account, entry: MinifluxEntry, feedTitles: Map<string, string>, preTime: number
  ): Article | undefined {
    if (entry.feed_id === undefined || entry.feed_id === null) {
      return undefined;
    }
    const feedKey: string = dbId(account.id, String(entry.feed_id));
    const html: string = XmlParser.decode(entry.content) || '';
    // GReader compatibility maps its `published` from Miniflux's published_at
    // (the feed pubDate), so use the same field here to keep ordering parity.
    // created_at is only a fallback for servers that omit published_at.
    // Parsing also tolerates numeric seconds/ms.
    const published: number = parseEntryPublishedAt(
      entry.published_at ?? entry.created_at, preTime, preTime
    );
    return {
      id: dbId(account.id, String(entry.id)),
      feedId: feedKey,
      feedTitle: normalizeFeedText(feedTitles.get(feedKey) ?? ''),
      title: XmlParser.decode(entry.title) || 'Empty',
      author: XmlParser.decode(entry.author) || '',
      link: entry.url ?? '',
      summary: this.plainText(html).substring(0, 280),
      content: html,
      imageUrl: this.firstImage(html),
      publishedAt: published,
      isRead: entry.status !== 'unread',
      isStarred: entry.starred === true,
      fullContent: '',
    };
  }

  private plainText(html: string): string {
    return html
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  private firstImage(html: string): string {
    const match: Array<string> | null = html.match(/<img\b[^>]*\bsrc\s*=\s*(["'])([^"']+)\1/i);
    return match !== null && match.length > 2 ? match[2] : '';
  }
}
