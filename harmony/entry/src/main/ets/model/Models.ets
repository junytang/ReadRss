/**
 * Data models for the HarmonyOS MVP.
 * These mirror the Room entities in the Android app (Account / Feed / Article / Group),
 * trimmed to the fields needed by the core reading flow.
 */

export interface Feed {
  id: string;
  title: string;
  url: string;
  groupId: string;
  iconUrl: string;
  sortOrder: number;
  unreadCount: number;
  starredCount: number;
}

/**
 * Filter feeds for the subscription drawer: unread keeps feeds with unread
 * articles, starred keeps feeds with starred articles, all keeps everything.
 */
export function filterFeedsByDrawer(feeds: Feed[], filter: string): Feed[] {
  if (filter === 'unread') {
    return feeds.filter((feed: Feed) => feed.unreadCount > 0);
  }
  if (filter === 'starred') {
    return feeds.filter((feed: Feed) => feed.starredCount > 0);
  }
  return feeds;
}

export interface Article {
  id: string;
  feedId: string;
  feedTitle: string;
  title: string;
  author: string;
  link: string;
  summary: string;
  content: string;
  fullContent: string;
  imageUrl: string;
  publishedAt: number;
  isRead: boolean;
  isStarred: boolean;
}

export interface ArticleNeighbors {
  previous: string;
  next: string;
}

export interface FeedGroup {
  id: string;
  name: string;
  sortOrder: number;
}

export interface AppSettings {
  activeAccountId: string;
  darkMode: boolean;
  syncOnLaunch: boolean;
  markReadOnOpen: boolean;
  fontSizeIndex: number;
  customFontPath: string;
  markReadOnScroll: boolean;
  keepArticleDays: number;
  fetchBatchSize: number;
}

export function defaultSettings(): AppSettings {
  return {
    activeAccountId: '1',
    darkMode: false,
    syncOnLaunch: false,
    markReadOnOpen: true,
    fontSizeIndex: 1,
    customFontPath: '',
    markReadOnScroll: false,
    keepArticleDays: 30,
    fetchBatchSize: 100,
  };
}
