import { Account, AccountType, dbId, remoteId } from '../account/AccountModels';
import { accountRepository } from '../account/AccountRepository';
import { database } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import { Article, Feed, FeedGroup } from '../model/Models';
import { beginSync, notifySyncBatch, notifySyncFinal, notifyContentReady } from './SyncProgress';
import { FeverApi, FeverFeed, FeverGroupMapping, FeverItem, FeverStatus } from './FeverApi';
import { FeedSyncService, FeedNotify, SyncResult } from './SyncService';
import { Logger } from '../common/Logger';
import { NotificationHelper } from '../common/NotificationHelper';
import { pendingStatusRegistry } from './PendingStatusRegistry';

const MAX_TIMESTAMP: number = 9223372036854775; // Date(Long.MAX_VALUE).time / 1000

/** Port of FeverRssService.kt. */
export class FeverSyncService implements FeedSyncService {
  readonly canImportSubscription: boolean = false;
  readonly canAddSubscription: boolean = false;
  readonly canMoveSubscription: boolean = false;
  readonly canDeleteSubscription: boolean = false;
  readonly canUpdateSubscription: boolean = false;

  // Last unread/saved CSV signatures per account. The server sets remain
  // authoritative and are still requested every sync; this only skips the
  // local Set-building and full-table rewrite when nothing changed. Process
  // local on purpose: a restart causes one extra harmless rewrite.
  private stateSignatures: Map<string, string> = new Map<string, string>();

  private api(account: Account): FeverApi {
    const credentials = accountRepository.credentials(account);
    return new FeverApi(credentials.serverUrl, credentials.username, credentials.password);
  }

  async validCredentials(account: Account): Promise<boolean> {
    return this.api(account).validCredentials();
  }

  clearAuthorization(): void {
    // No shared token cache in this port.
  }

  async subscribe(account: Account, url: string): Promise<Feed> {
    throw new Error('Unsupported');
  }

  async sync(account: Account): Promise<SyncResult> {
    if (account.type !== AccountType.FEVER) {
      throw new Error('account type is invalid');
    }
    const preTime: number = Date.now();
    const api: FeverApi = this.api(account);
    const result: SyncResult = { succeeded: 0, failed: 0, newArticles: 0 };
    beginSync();

    try {
      const groupsBody = await api.getGroups();
      const feedsBody = await api.getFeeds();
      const faviconsBody = await api.getFavicons();

      const mappings: FeverGroupMapping[] = [];
      if (groupsBody.feeds_groups) {
        mappings.push(...groupsBody.feeds_groups);
      }
      if (feedsBody.feeds_groups) {
        mappings.push(...feedsBody.feeds_groups);
      }
      const feedToGroup: Map<number, number> = new Map<number, number>();
      for (const mapping of mappings) {
        for (const rawId of (mapping.feed_ids ?? '').split(',')) {
          // Android does not trim CSV entries.
          const id: number = Number.parseInt(rawId, 10);
          if (!Number.isNaN(id)) {
            feedToGroup.set(id, mapping.group_id);
          }
        }
      }

      const keepGroupIds: string[] = [];
      const remoteGroups = groupsBody.groups ?? [];
      for (let i = 0; i < remoteGroups.length; i++) {
        const group = remoteGroups[i];
        if (group.id === undefined || group.id === null) {
          throw new Error('Fever group missing id');
        }
        const groupId: string = dbId(account.id, group.id.toString());
        const item: FeedGroup = {
          id: groupId,
          name: group.title ?? 'Empty',
          sortOrder: i,
        };
        await database.upsertGroup(item, account.id);
        keepGroupIds.push(groupId);
      }

      // Fever JSON may encode ids as numbers or strings; use string keys so
      // favicon_id lookups never miss because of a type mismatch.
      const iconMap: Map<string, string> = new Map<string, string>();
      for (const icon of faviconsBody.favicons ?? []) {
        if (icon.data !== undefined && icon.data !== null) {
          iconMap.set(String(icon.id), icon.data);
        }
      }
      const feedTitles: Map<string, string> = new Map<string, string>();
      // Read current rows once so an unchanged feed (including its favicon) is
      // not rewritten. INSERT OR REPLACE is destructive and would overwrite
      // locally-held feed flags; Android's FeedDao.insertOrUpdate also skips
      // writes when the row is unchanged.
      const existingFeeds: Map<string, Feed> = new Map<string, Feed>();
      for (const feed of await database.listFeeds(account.id)) {
        existingFeeds.set(feed.id, feed);
      }

      const remoteFeeds: FeverFeed[] = feedsBody.feeds ?? [];
      for (let i = 0; i < remoteFeeds.length; i++) {
        const feed: FeverFeed = remoteFeeds[i];
        if (feed.id === undefined || feed.id === null || !feed.url) {
          throw new Error('Fever feed missing required field');
        }
        const remoteGroup: number | undefined = feedToGroup.get(feed.id);
        if (remoteGroup === undefined) {
          throw new Error(`Missing Fever group mapping for feed ${feed.id}`);
        }
        const groupId: string = dbId(account.id, remoteGroup.toString());
        const title: string = FeverApi.decodeHtml(feed.title) || 'Empty';
        const favicon: string = feed.favicon_id !== undefined && feed.favicon_id !== null
          ? iconMap.get(String(feed.favicon_id)) ?? ''
          : '';
        const local: Feed = {
          id: dbId(account.id, feed.id.toString()),
          title: title,
          url: feed.url,
          groupId: groupId,
          iconUrl: favicon,
          sortOrder: i,
          unreadCount: 0,
          starredCount: 0,
        };
        const old: Feed | undefined = existingFeeds.get(local.id);
        if (!old || old.title !== local.title || old.url !== local.url
          || old.groupId !== local.groupId || old.iconUrl !== local.iconUrl
          || old.sortOrder !== local.sortOrder) {
          await database.upsertFeed(local, account.id);
        }
        feedTitles.set(local.id, local.title);
      }

      let lastSeenId: string = account.lastArticleId ?? '';
      let newArticles: number = 0;
      const batchSize: number = settingsStore.get().fetchBatchSize;
      // One notification per feed for the whole sync (Android behaviour), instead
      // of re-notifying and re-reading the feed table on every batch.
      const notifyByFeed: Map<string, FeedNotify> = new Map<string, FeedNotify>();
      for (;;) {
        const body = await api.getItemsSince(lastSeenId);
        const items: FeverItem[] = body.items ?? [];
        const articles: Article[] = [];
        for (const item of items) {
          const id: string = String(item.id ?? '');
          if (item.id === undefined || item.id === null || item.feed_id === undefined || item.feed_id === null) {
            throw new Error('Fever item missing required field');
          }
          const feedKey: string = dbId(account.id, item.feed_id.toString());
          const published: number = item.created_on_time ? item.created_on_time * 1000 : preTime;
          const html: string = item.html ?? '';
          articles.push({
            id: dbId(account.id, id),
            feedId: feedKey,
            feedTitle: feedTitles.get(feedKey) ?? '',
            title: FeverApi.decodeHtml(item.title) || 'Empty',
            author: item.author ?? '',
            link: item.url ?? '',
            summary: this.plainText(html).substring(0, 280),
            content: html,
            imageUrl: this.firstImage(html),
            publishedAt: published > preTime ? preTime : published,
            isRead: (item.is_read ?? 0) > 0,
            isStarred: (item.is_saved ?? 0) > 0,
            fullContent: '',
          });
        }
        // Insert in configured batches and notify the UI after each one so
        // unread counts update while the rest of the sync continues in background.
        for (let start: number = 0; start < articles.length; start += batchSize) {
          const chunk: Article[] = articles.slice(start, start + batchSize);
          newArticles += await database.insertArticles(chunk, account.id);
          notifySyncBatch();
          for (const article of chunk) {
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
        if (items.length === 0) {
          break;
        }
        lastSeenId = String(items[items.length - 1].id);
        if (items.length < 50) {
          break;
        }
      }
      result.newArticles = newArticles;
      NotificationHelper.notifyAll(notifyByFeed);
      // Content is committed; stop the spinner before the slower state reconciliation.
      notifyContentReady();

      // Requests stay unconditional (the server CSV is authoritative and other
      // clients may change it). Only the local Set-building and full-table
      // rewrite are skipped when the signature is unchanged. Newly inserted
      // articles force one reconciliation even with an unchanged signature.
      const unread: string[] | undefined = await api.getUnreadIds();
      const savedRaw: string[] = await api.getSavedIds();
      const unreadSig: string = unread === undefined ? '__undef__' : unread.join(',');
      const signature: string = unreadSig + '||' + savedRaw.join(',');
      if (this.stateSignatures.get(account.id) !== signature || result.newArticles > 0) {
        const unreadSet: Set<string> | undefined = unread === undefined ? undefined : new Set<string>(unread);
        const saved: Set<string> = new Set<string>(savedRaw);
        const localIds: string[] = await database.listRemoteIds(account.id);
        const toRead: string[] = [];
        const toUnread: string[] = [];
        const toStar: string[] = [];
        const toUnstar: string[] = [];
        for (const rawId of localIds) {
          // Skip ids with a locally-pending mark: the server CSV is stale and
          // would revert what the user just changed (pendingSyncDiffs semantics).
          if (pendingStatusRegistry.has(rawId)) {
            continue;
          }
          const id: string = remoteId(rawId);
          const shouldBeUnread: boolean = unreadSet === undefined ? true : unreadSet.has(id);
          if (shouldBeUnread) toUnread.push(rawId); else toRead.push(rawId);
          if (saved.has(id)) toStar.push(rawId); else toUnstar.push(rawId);
        }
        await database.setStates(toRead, true, undefined);
        await database.setStates(toUnread, false, undefined);
        await database.setStates(toStar, undefined, true);
        await database.setStates(toUnstar, undefined, false);
        this.stateSignatures.set(account.id, signature);
      }

      // Android keeps feeds that have a group mapping, not merely feeds present in /feeds.
      const mappedIds: Set<number> = new Set<number>();
      feedToGroup.forEach((value: number, key: number) => {
        mappedIds.add(key);
      });
      for (const feed of await database.listFeeds(account.id)) {
        const remoteFeedId: number = Number.parseInt(remoteId(feed.id), 10);
        if (!mappedIds.has(remoteFeedId)) {
          await database.deleteFeedPreservingStarred(feed.id);
        }
      }
      await database.deleteGroupsExcept(account.id, keepGroupIds);

      account.updateAt = preTime;
      account.lastArticleId = lastSeenId.length > 0 ? dbId(account.id, lastSeenId) : null;
      await database.updateAccount(account);
      result.succeeded = 1;
      notifySyncFinal();
    } catch (error) {
      Logger.error(`Fever sync failed: ${(error as Error).message}`);
      result.failed = 1;
      throw error as Error;
    }
    return result;
  }

  async markRead(
    account: Account, articleIds: string[], read: boolean,
    before: number = MAX_TIMESTAMP
  ): Promise<string[]> {
    const api: FeverApi = this.api(account);
    const status: FeverStatus = read ? FeverStatus.READ : FeverStatus.UNREAD;
    if (articleIds.length === 0) {
      for (const feed of await database.listFeeds(account.id)) {
        // Android marks each local feed via markFeed, then updates locally.
        await database.setStatesByFeed(account.id, feed.id, read);
        await api.markFeed(status, remoteId(feed.id), before);
      }
      await database.setAllRead(account.id, read);
      return [];
    }
    // One batched UPDATE instead of one write per id. The per-item POST is kept:
    // Fever's documented API only accepts a single item id.
    await database.setStates(articleIds, read, undefined);
    const done: string[] = [];
    for (const id of articleIds) {
      // Report only ids whose per-item POST succeeded. A failed item must stay
      // in the batcher's pending set for a bounded retry; one failure must not
      // abort the remaining items or be mistaken for overall success.
      try {
        await api.markItem(status, remoteId(id));
        done.push(id);
      } catch (error) {
        Logger.error(`Fever markItem failed: ${(error as Error).message} id=${id}`);
      }
    }
    return done;
  }

  async markReadGroup(account: Account, groupId: string, read: boolean, before: number = MAX_TIMESTAMP): Promise<void> {
    const api: FeverApi = this.api(account);
    await api.markGroup(read ? FeverStatus.READ : FeverStatus.UNREAD, remoteId(groupId), before);
  }

  async markReadFeed(account: Account, feedId: string, read: boolean, before: number = MAX_TIMESTAMP): Promise<void> {
    const api: FeverApi = this.api(account);
    await database.setStatesByFeed(account.id, feedId, read);
    await api.markFeed(read ? FeverStatus.READ : FeverStatus.UNREAD, remoteId(feedId), before);
  }

  async markStarred(account: Account, article: Article, starred: boolean): Promise<void> {
    await this.markStarredBatch(account, [article.id], starred);
  }

  async markStarredBatch(account: Account, articleIds: string[], starred: boolean): Promise<string[]> {
    if (articleIds.length === 0) {
      return [];
    }
    // One batched DB UPDATE. Fever's API only accepts a single item id per call,
    // so the network requests stay per-item (unavoidable), but return only the
    // ids whose POST succeeded so the store can retry the rest.
    await database.setStates(articleIds, undefined, starred);
    const api: FeverApi = this.api(account);
    const status: FeverStatus = starred ? FeverStatus.SAVED : FeverStatus.UNSAVED;
    const done: string[] = [];
    for (const id of articleIds) {
      try {
        await api.markItem(status, remoteId(id));
        done.push(id);
      } catch (error) {
        Logger.error(`Fever star failed: ${(error as Error).message} id=${id}`);
      }
    }
    return done;
  }

  async fetchContent(account: Account, article: Article): Promise<string> {
    const body = await this.api(account).getItemsWith([remoteId(article.id)]);
    for (const item of body.items ?? []) {
      if (String(item.id ?? '') === remoteId(article.id)) {
        return item.html ?? '';
      }
    }
    return '';
  }

  async deleteFeed(account: Account, feedId: string): Promise<void> {
    throw new Error('Unsupported');
  }

  private plainText(html: string): string {
    const cleaned: string = html.replace(/<(script|style|noscript)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ');
    const withBreaks: string = cleaned
      .replace(/<\/(p|div|br|li|h[1-6])>/gi, '\n')
      .replace(/<br\s*\/?>/gi, '\n');
    return FeverApi.decodeHtml(withBreaks).replace(/[^\S\n]+/g, ' ').trim();
  }

  private firstImage(html: string): string {
    const enclosure: Array<string> | null = html.match(/<enclosure\s+url="([^"]+)"\s+type="[^"]*"\s*\/>/);
    if (enclosure && enclosure.length > 1 && enclosure[1].trim().length > 0) {
      return enclosure[1];
    }
    const match: Array<string> | null = html.match(/img.*?src=(["'])((?!data)[\s\S]*?)\1/);
    return match && match.length > 2 && !match[2].startsWith('data:') ? match[2] : '';
  }
}
