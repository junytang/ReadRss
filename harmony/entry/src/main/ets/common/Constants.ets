/** Global constants for the HarmonyOS port. */

export const DB_NAME: string = 'readyou.db';
export const PREFS_NAME: string = 'readyou_settings';

export const ROUTE_FLOW: string = 'FlowPage';
export const ROUTE_READING: string = 'ReadingPage';
export const ROUTE_SETTINGS: string = 'SettingsPage';
export const ROUTE_SUBSCRIBE: string = 'SubscribePage';
export const ROUTE_FEEDS: string = 'FeedsPage';
export const ROUTE_ACCOUNTS: string = 'AccountsPage';
export const ROUTE_ACCOUNT_EDITOR: string = 'AccountEditorPage';

/** Empty Navigation parameter for routes that take no arguments. */
export interface EmptyNavParam {}

/** Parameters passed through Navigation when opening the article list. */
export interface FlowParam {
  feedId: string;
  feedTitle: string;
}

/** fontSizeIndex → app-wide font scale (ApplicationContext.setFontSizeScale). */
export function fontScaleForIndex(index: number): number {
  const scales: number[] = [0.85, 1.0, 1.15, 1.3];
  return index >= 0 && index < scales.length ? scales[index] : 1.0;
}

export const FILTER_UNREAD: string = 'unread';
export const FILTER_STARRED: string = 'starred';
export const FILTER_ALL: string = 'all';

/** Parameters passed through Navigation when opening the reader. */
export interface ReadingParam {
  articleId: string;
}

/** Parameters passed through Navigation when editing an account (empty id = new). */
export interface AccountEditorParam {
  accountId: string;
}

/** Default feed suggestions shown on the subscribe page. */
export interface FeedSuggestion {
  title: string;
  url: string;
}

export const SUGGESTED_FEEDS: FeedSuggestion[] = [
  { title: 'Solidot', url: 'https://www.solidot.org/index.rss' },
  { title: '少数派', url: 'https://sspai.com/feed' },
  { title: 'Android Developers Blog', url: 'https://android-developers.googleblog.com/feeds/posts/default' },
];
