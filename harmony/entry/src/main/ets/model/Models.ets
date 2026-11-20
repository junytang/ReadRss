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
  showFullContent: boolean;
  fontSizeIndex: number;
  customFontPath: string;
  markReadOnScroll: boolean;
  keepArticleDays: number;
  onlyUnreadFeeds: boolean;
}

export function defaultSettings(): AppSettings {
  return {
    activeAccountId: '1',
    darkMode: false,
    syncOnLaunch: false,
    markReadOnOpen: true,
    showFullContent: true,
    fontSizeIndex: 1,
    customFontPath: '',
    markReadOnScroll: false,
    keepArticleDays: 30,
    onlyUnreadFeeds: false,
  };
}
