import { http } from '@kit.NetworkKit';
import { Account, dbId } from '../account/AccountModels';
import { database } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import { Article, Feed } from '../model/Models';
import { beginSync, notifySyncBatch, notifySyncFinal, notifyContentReady } from './SyncProgress';
import { ParsedFeed, RssParser } from './RssParser';
import { FeedSyncService, SyncResult } from './SyncService';
import { Logger } from '../common/Logger';

/** Direct RSS/Atom fetching. Equivalent to Android's LocalRssService. */
export class LocalSyncService implements FeedSyncService {
  readonly canImportSubscription: boolean = true;
  readonly canAddSubscription: boolean = true;
  readonly canMoveSubscription: boolean = true;
  readonly canDeleteSubscription: boolean = true;
  readonly canUpdateSubscription: boolean = true;

  private parser: RssParser = new RssParser();

  async fetch(url: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 15000,
        header: {
          'User-Agent': 'ReadYou-Harmony/0.1 (+RSS reader)',
          'Accept': 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
        },
      });
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      return response.result as string;
    } finally {
      request.destroy();
    }
  }

  /** Mirrors String.formatUrl(): "//x" → https://x, other schemes untouched. */
  private normalize(url: string): string {
    if (url.startsWith('//')) {
      return `https:${url}`;
    }
    return /^(https?|ftp|file).*/.test(url) ? url : `https://${url}`;
  }

  async subscribe(account: Account, rawUrl: string): Promise<Feed> {
    const url: string = this.normalize(rawUrl);
    const existing: Feed | undefined = await database.getFeedByUrl(account.id, url);
    if (existing) {
      return existing;
    }
    const feedId: string = dbId(
      account.id,
      `${Date.now().toString()}-${Math.floor(Math.random() * 1e9).toString()}`
    );
    const parsed: ParsedFeed = this.parser.parse(await this.fetch(url), feedId, url);
    const feed: Feed = {
      id: feedId,
      title: parsed.title,
      url: url,
      groupId: '',
      iconUrl: '',
      sortOrder: Date.now(),
      unreadCount: parsed.articles.length,
      starredCount: 0,
    };
    await database.upsertFeed(feed, account.id);
    await database.insertArticles(parsed.articles, account.id);
    return feed;
  }

  async sync(account: Account): Promise<SyncResult> {
    const feeds: Feed[] = await database.listFeeds(account.id);
    const result: SyncResult = { succeeded: 0, failed: 0, newArticles: 0 };
    const batchSize: number = settingsStore.get().fetchBatchSize;
    beginSync();
    Logger.info(`SYNCDBG local sync begin feeds=${feeds.length} batchSize=${batchSize}`);
    for (const feed of feeds) {
      try {
        const parsed: ParsedFeed = this.parser.parse(await this.fetch(feed.url), feed.id, feed.title);
        if (parsed.title.length > 0 && parsed.title !== feed.title) {
          feed.title = parsed.title;
          await database.upsertFeed(feed, account.id);
        }
        for (let start: number = 0; start < parsed.articles.length; start += batchSize) {
          const chunk: Article[] = parsed.articles.slice(start, start + batchSize);
          result.newArticles += await database.insertArticles(chunk, account.id);
          Logger.info(`SYNCDBG local batch committed feed=${feed.title} size=${chunk.length} newArticles=${result.newArticles}`);
          notifySyncBatch();
        }
        result.succeeded += 1;
      } catch (error) {
        result.failed += 1;
        Logger.error(`Local sync failed for ${feed.url}: ${(error as Error).message}`);
      }
    }
    // All feed content is committed; stop the spinner here.
    notifyContentReady();
    Logger.info('SYNCDBG local sync end');
    notifySyncFinal();
    return result;
  }

  async markRead(account: Account, articleIds: string[], read: boolean, before?: number): Promise<string[]> {
    for (const id of articleIds) {
      await database.setArticleRead(id, read);
    }
    return articleIds.slice();
  }

  async markReadGroup(account: Account, groupId: string, read: boolean, before?: number): Promise<void> {
    // Local groups are not used as a sync scope in this MVP.
  }

  async markReadFeed(account: Account, feedId: string, read: boolean, before?: number): Promise<void> {
    await database.setStatesByFeed(account.id, feedId, read);
  }

  async markStarred(account: Account, article: Article, starred: boolean): Promise<void> {
    await database.setArticleStarred(article.id, starred);
  }

  async deleteFeed(account: Account, feedId: string): Promise<void> {
    await database.deleteFeedById(feedId);
  }

  async validCredentials(account: Account): Promise<boolean> {
    return true;
  }

  clearAuthorization(): void {
    // Nothing to clear for direct feeds.
  }
}
