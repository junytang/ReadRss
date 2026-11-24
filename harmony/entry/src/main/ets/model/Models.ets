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
  markReadOnScroll: boolean;
  keepArticleDays: number;
  fetchBatchSize: number;
  // Article list appearance.
  articleTitleFontSize: number;
  articleSummaryFontSize: number;
  articleMetaFontSize: number;
  articleFontFamily: string;
  // Article list behavior (Android FlowPageStyle / Interaction preferences).
  sortUnreadEarliest: boolean;          // false = Latest, true = Earliest
  swipeStartAction: number;             // SWIPE_NONE / SWIPE_TOGGLE_READ / SWIPE_TOGGLE_STARRED
  swipeEndAction: number;
  showFeedIcon: boolean;
  showFeedName: boolean;
  showArticleImage: boolean;            // thumbnail on the right
  articleDescLength: number;            // DESC_NONE / DESC_SHORT / DESC_LONG
  // Full-text reader appearance.
  readerBodyFontSize: number;
  readerPageMargin: number;
  readerLineSpacing: number;
  readerFontFamily: string;
  // Android readingTextLetterSpacing / readingTextAlign.
  readingTextLetterSpacing: number;
  readingTextAlign: number;
  // System-wide text scale and font family.
  systemFontScale: number;
  systemFontFamily: string;
  // Shared installed custom font file (empty = none installed).
  customFontPath: string;
  customFontName: string;
}

export function defaultSettings(): AppSettings {
  return {
    activeAccountId: '1',
    darkMode: false,
    syncOnLaunch: false,
    markReadOnOpen: true,
    markReadOnScroll: false,
    keepArticleDays: 30,
    fetchBatchSize: 100,
    articleTitleFontSize: 17,
    articleSummaryFontSize: 15,
    articleMetaFontSize: 13,
    articleFontFamily: 'sans-serif',
    sortUnreadEarliest: false,
    // Android defaults: start = ToggleStarred, end = ToggleRead.
    swipeStartAction: 2,
    swipeEndAction: 1,
    showFeedIcon: true,
    showFeedName: true,
    showArticleImage: false,
    articleDescLength: 2,
    readerBodyFontSize: 17,
    readerPageMargin: 16,
    readerLineSpacing: 1.75,
    readerFontFamily: 'sans-serif',
    readingTextLetterSpacing: 0.5,
    readingTextAlign: 0,
    systemFontScale: 1.0,
    systemFontFamily: 'sans-serif',
    customFontPath: '',
    customFontName: '',
  };
}
