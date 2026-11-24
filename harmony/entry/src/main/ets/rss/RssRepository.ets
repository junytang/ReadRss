import { Account } from '../account/AccountModels';
import { accountRepository } from '../account/AccountRepository';
import { database, ArticleCounts } from '../data/Database';
import { Article, ArticleNeighbors, Feed, FeedGroup } from '../model/Models';
import { FeedSyncService, SyncResult } from './SyncService';
import { syncServiceFor } from './SyncServiceFactory';
import { Logger } from '../common/Logger';
import { FullContentFetcher, FULL_CONTENT_VERSION_MARKER } from './FullContentFetcher';
import { readStatusStore } from './ReadStatusStore';

/** Facade used by the UI; always operates on the active account. */
class FeedRepository {
  // The prefetcher and the reader can both request full text for the same
  // article at once. Share one in-flight fetch per id so the origin is hit once
  // and the DB is written once; each caller still updates its own Article copy.
  private fullContentInFlight: Map<string, Promise<string>> = new Map();

  async activeAccount(): Promise<Account> {
    const account: Account | undefined = await accountRepository.active();
    if (!account) {
      throw new Error('没有可用账号');
    }
    return account;
  }

  listAccounts() {
    return accountRepository.list();
  }

  async switchAccount(id: string): Promise<void> {
    await accountRepository.switchTo(id);
  }

  validCredentials(account: Account): Promise<boolean> {
    return syncServiceFor(account).validCredentials(account);
  }

  canAddSubscription(account: Account): boolean {
    return syncServiceFor(account).canAddSubscription;
  }

  canDeleteSubscription(account: Account): boolean {
    return syncServiceFor(account).canDeleteSubscription;
  }

  /** Some servers (e.g. Miniflux) emit icon URLs pointing at "localhost". */
  private fixIconUrl(iconUrl: string, serverUrl: string): string {
    if (iconUrl.length === 0 || iconUrl.indexOf('://localhost') < 0) {
      return iconUrl;
    }
    const match: Array<string> | null = serverUrl.match(/^(https?:\/\/[^\/]+)/i);
    if (!match || match.length < 2) {
      return iconUrl;
    }
    return iconUrl.replace(/^(https?:\/\/)[^\/]+/i, match[1]);
  }

  async listFeeds(): Promise<Feed[]> {
    const account: Account = await this.activeAccount();
    const feeds: Feed[] = await database.listFeeds(account.id);
    const serverUrl: string = accountRepository.credentials(account).serverUrl;
    for (const feed of feeds) {
      feed.iconUrl = this.fixIconUrl(feed.iconUrl, serverUrl);
    }
    return feeds;
  }

  async listGroups(): Promise<FeedGroup[]> {
    const account: Account = await this.activeAccount();
    return database.listGroups(account.id);
  }

  async listArticles(
    feedId: string, filter: string, limit: number,
    groupId?: string, sortAscending?: boolean, searchContent?: string,
    lightweight: boolean = false
  ): Promise<Article[]> {
    const account: Account = await this.activeAccount();
    // Include pending local read/star changes in the WHERE clause so a just
    // starred article shows up in the starred tab before the delayed DB commit.
    return database.listArticles(
      account.id, feedId, filter, limit, groupId, sortAscending, searchContent, lightweight,
      readStatusStore.pendingFilterIds()
    );
  }

  /** Android prefetchArticleId: previous/next article in the visible list.
   *  Uses the scope captured when the article was opened (feed/group/filter/
   *  search), so "全部" spans every feed instead of staying in one source.
   *  Takes the already-loaded article so no extra full-body read is needed. */
  async neighborIds(
    article: Article,
    feedId: string = '', filter: string = '', groupId: string = '', searchText: string = ''
  ): Promise<ArticleNeighbors> {
    const empty: ArticleNeighbors = { previous: '', next: '' };
    if (!article || article.id.length === 0) {
      return empty;
    }
    const account: Account = await this.activeAccount();
    return database.neighborArticleIds(
      account.id, article.id, article.publishedAt, feedId, filter, groupId, searchText
    );
  }

  /** Source icon for one feed; avoids listing every feed to find one row. */
  async feedIconUrl(feedId: string): Promise<string> {
    const feed: Feed | undefined = await database.getFeedById(feedId);
    if (!feed) {
      return '';
    }
    const account: Account = await this.activeAccount();
    const serverUrl: string = accountRepository.credentials(account).serverUrl;
    return this.fixIconUrl(feed.iconUrl, serverUrl);
  }

  getArticle(id: string): Promise<Article | undefined> {
    return database.getArticle(id);
  }

  /** Metadata without the HTML bodies, for actions that only need title/link. */
  getArticleMeta(id: string): Promise<Article | undefined> {
    return database.getArticleMeta(id);
  }

  /** Lazily fetch the body for articles that were only stored as read-state ids. */
  async ensureArticleContent(articleId: string): Promise<Article | undefined> {
    let article: Article | undefined = await database.getArticle(articleId);
    if (!article || article.content.length > 0) {
      return article;
    }
    const account: Account = await this.activeAccount();
    const service: FeedSyncService = syncServiceFor(account);
    if (!service.fetchContent) {
      return article;
    }
    try {
      const content: string = await service.fetchContent(account, article);
      if (content.length > 0) {
        await database.updateArticleContent(articleId, content);
        article.content = content;
      }
    } catch (error) {
      Logger.error(`Fetch content failed: ${(error as Error).message}`);
    }
    return article;
  }

  /** Android's renderFullContent: fetch original page and cache extracted body. */
  /** Startup cleanup so the database does not grow without bound. */
  async cleanExpiredArticles(keepDays: number): Promise<number> {
    if (keepDays <= 0) {
      return 0;
    }
    const cutoff: number = Date.now() - keepDays * 24 * 3600 * 1000;
    const removed: number = await database.deleteArticlesBefore(cutoff);
    if (removed > 0) {
      Logger.info(`Cleaned ${removed} expired articles (older than ${keepDays} days)`);
      AppStorage.set<number>('feedDataTick', Date.now());
    }
    return removed;
  }

  async clearFullContentCache(): Promise<void> {
    await database.clearFullContent();
  }

  /** True only for a body produced by the current extraction algorithm. */
  hasCurrentFullContent(article: Article): boolean {
    return article.fullContent.startsWith(FULL_CONTENT_VERSION_MARKER);
  }

  async ensureFullContent(articleId: string): Promise<Article | undefined> {
    const article: Article | undefined = await database.getArticle(articleId);
    return this.ensureFullContentFor(article);
  }

  /** Fetch + persist full text once per article id, shared across concurrent
   *  callers (prefetch window and the opened reader). */
  private fetchAndStoreFullContent(article: Article): Promise<string> {
    let task: Promise<string> | undefined = this.fullContentInFlight.get(article.id);
    if (task === undefined) {
      const id: string = article.id;
      task = (async (): Promise<string> => {
        const content: string = await FullContentFetcher.fetch(article.link, article.title);
        if (content.length > 0) {
          await database.updateArticleFullContent(id, content);
        }
        return content;
      })();
      this.fullContentInFlight.set(id, task);
      // Drop from the in-flight table on both success and failure; a later
      // explicit re-fetch (e.g. version bump) can start a fresh task.
      task.then(
        (): void => { this.fullContentInFlight.delete(id); },
        (): void => { this.fullContentInFlight.delete(id); }
      );
    }
    return task;
  }

  /** Ensure full text for an already-loaded article, avoiding a second DB read.
   *  Used by the prefetcher, whose list rows carry only summary fields. */
  async ensureFullContentFor(article?: Article): Promise<Article | undefined> {
    // Re-fetch when the cached body came from an older extraction algorithm.
    if (!article || article.link.length === 0 || this.hasCurrentFullContent(article)) {
      return article;
    }
    const content: string = await this.fetchAndStoreFullContent(article);
    if (content.length > 0) {
      article.fullContent = content;
    }
    return article;
  }

  async unreadCount(feedId?: string, groupId?: string): Promise<number> {
    const account: Account = await this.activeAccount();
    return database.countUnread(account.id, feedId, groupId);
  }

  async articleCount(filter: string, feedId?: string, groupId?: string): Promise<number> {
    const account: Account = await this.activeAccount();
    return database.countArticles(account.id, filter, feedId, groupId);
  }

  /** Unread + starred + total in one query (three COUNT queries before). */
  async articleCounts(feedId?: string, groupId?: string): Promise<ArticleCounts> {
    const account: Account = await this.activeAccount();
    return database.articleCounts(account.id, feedId, groupId);
  }

  // A single in-flight sync serves all callers. Multiple pages (and the
  // first-launch sync) can request a sync at once; sharing the promise avoids
  // duplicate network requests against the server.
  private syncInFlight: Promise<SyncResult> | undefined = undefined;

  async syncAll(): Promise<SyncResult> {
    if (this.syncInFlight !== undefined) {
      return this.syncInFlight;
    }
    this.syncInFlight = this.doSync();
    try {
      return await this.syncInFlight;
    } finally {
      this.syncInFlight = undefined;
    }
  }

  private async doSync(): Promise<SyncResult> {
    const account: Account = await this.activeAccount();
    try {
      // Push optimistic marks BEFORE reconciliation. Without this, the 10s
      // batcher debounce leaves a window where the server still has the old
      // state and sync's toUnread/toUnstar/toRead overwrite what the user just
      // changed (README known issue). flush() never throws (it retries).
      await readStatusStore.flush();
      const result: SyncResult = await syncServiceFor(account).sync(account);
      // Each service emits feedDataTick per batch and notifySyncFinal at the end;
      // no extra tick here to avoid a redundant full UI reload.
      return result;
    } catch (error) {
      Logger.error(`Sync failed: ${(error as Error).message}`);
      throw error as Error;
    }
  }

  async subscribe(url: string): Promise<Feed> {
    const account: Account = await this.activeAccount();
    const service: FeedSyncService = syncServiceFor(account);
    if (!service.canAddSubscription) {
      throw new Error('Unsupported');
    }
    return service.subscribe(account, url);
  }

  async removeFeed(id: string): Promise<void> {
    const account: Account = await this.activeAccount();
    const service: FeedSyncService = syncServiceFor(account);
    if (!service.canDeleteSubscription) {
      throw new Error('Unsupported');
    }
    await service.deleteFeed(account, id);
  }

  async markRead(id: string, read: boolean, before?: number): Promise<string[]> {
    const account: Account = await this.activeAccount();
    // Return the ids the server actually confirmed so the caller can queue a
    // retry for failures instead of silently trusting the optimistic UI.
    return syncServiceFor(account).markRead(account, [id], read, before);
  }

  async markReadBatch(ids: string[], read: boolean, before?: number): Promise<string[]> {
    if (ids.length === 0) {
      return [];
    }
    const account: Account = await this.activeAccount();
    return syncServiceFor(account).markRead(account, ids, read, before);
  }

  async markReadGroup(groupId: string, read: boolean, before?: number): Promise<void> {
    const account: Account = await this.activeAccount();
    await syncServiceFor(account).markReadGroup(account, groupId, read, before);
  }

  async markStarred(articleId: string, starred: boolean): Promise<void> {
    const account: Account = await this.activeAccount();
    // Only the remote id is needed for the tag edit; avoid loading the body.
    const article: Article | undefined = await database.getArticleMeta(articleId);
    if (!article) {
      return;
    }
    await syncServiceFor(account).markStarred(account, article, starred);
  }

  async markStarredBatch(ids: string[], starred: boolean): Promise<string[]> {
    if (ids.length === 0) {
      return [];
    }
    const account: Account = await this.activeAccount();
    return syncServiceFor(account).markStarredBatch(account, ids, starred);
  }

  /** Mark all unread articles in the current scope (feed / group / all) as read.
   *  Only ids are read from the database: loading every unread article body just
   *  to collect ids could pull 100k full HTML documents into memory. */
  async markAllRead(feedId: string, groupId?: string): Promise<void> {
    const account: Account = await this.activeAccount();
    const service: FeedSyncService = syncServiceFor(account);
    const ids: string[] = await database.listArticleIds(account.id, 'unread', feedId, groupId);
    if (ids.length === 0) {
      return;
    }
    await service.markRead(account, ids, true);
  }

  /** Mark unread articles in scope that were published before `before` (ms).
   *  Mirrors Android's markAsReadFromListByDate for the 1/3/7-day bar options. */
  async markAllReadBefore(feedId: string, groupId: string | undefined, before: number): Promise<void> {
    const account: Account = await this.activeAccount();
    const service: FeedSyncService = syncServiceFor(account);
    const ids: string[] = await database.listArticleIds(account.id, 'unread', feedId, groupId, before);
    if (ids.length === 0) {
      return;
    }
    await service.markRead(account, ids, true, before);
  }
}

export const rssRepository: FeedRepository = new FeedRepository();
