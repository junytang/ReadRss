import { Account } from '../account/AccountModels';
import { Article, Feed, FeedGroup } from '../model/Models';

export interface SyncResult {
  succeeded: number;
  failed: number;
  newArticles: number;
}

/** Pending notification for one feed, coalesced across all sync batches. */
export interface FeedNotify {
  feedTitle: string;
  firstTitle: string;
  count: number;
}

/** Contract shared by the local, Fever and Google Reader sync implementations. */
export interface FeedSyncService {
  readonly canImportSubscription: boolean;
  readonly canAddSubscription: boolean;
  readonly canMoveSubscription: boolean;
  readonly canDeleteSubscription: boolean;
  readonly canUpdateSubscription: boolean;

  sync(account: Account): Promise<SyncResult>;
  subscribe(account: Account, url: string): Promise<Feed>;
  markRead(account: Account, articleIds: string[], read: boolean, before?: number): Promise<string[]>;
  markReadGroup(account: Account, groupId: string, read: boolean, before?: number): Promise<void>;
  markReadFeed(account: Account, feedId: string, read: boolean, before?: number): Promise<void>;
  markStarred(account: Account, article: Article, starred: boolean): Promise<void>;
  deleteFeed(account: Account, feedId: string): Promise<void>;
  /** Fetch full content on demand when a stored article has no body (read-only ids). */
  fetchContent?(account: Account, article: Article): Promise<string>;
  addGroup?(account: Account, name: string): Promise<FeedGroup>;
  renameGroup?(account: Account, group: FeedGroup): Promise<void>;
  renameFeed?(account: Account, feed: Feed): Promise<void>;
  moveFeed?(account: Account, originGroupId: string, feed: Feed): Promise<void>;
  deleteGroup?(account: Account, group: FeedGroup): Promise<void>;
  validCredentials(account: Account): Promise<boolean>;
  clearAuthorization(): void;
}

export function emptySyncResult(): SyncResult {
  return { succeeded: 0, failed: 0, newArticles: 0 };
}
