/** Global constants for the HarmonyOS port. */

export const DB_NAME: string = 'readyou.db';
export const PREFS_NAME: string = 'readyou_settings';

export const ROUTE_FLOW: string = 'FlowPage';
export const ROUTE_READING: string = 'ReadingPage';
export const ROUTE_SETTINGS: string = 'SettingsPage';
export const ROUTE_SUBSCRIBE: string = 'SubscribePage';
export const ROUTE_ACCOUNTS: string = 'AccountsPage';
export const ROUTE_ACCOUNT_EDITOR: string = 'AccountEditorPage';
export const ROUTE_ARTICLE_LIST_STYLE: string = 'ArticleListStylePage';
export const ROUTE_READER_STYLE: string = 'ReaderStylePage';
export const ROUTE_FONT_PICKER: string = 'FontPickerPage';
export const ROUTE_SYSTEM_STYLE: string = 'SystemStylePage';

/** Empty Navigation parameter for routes that take no arguments. */
export interface EmptyNavParam {}

/** Parameters passed through Navigation when opening the article list. */
export interface FlowParam {
  feedId: string;
  feedTitle: string;
}

/** Font picker target: which of the two contexts is being customised. */
export interface FontPickerParam {
  target: string; // 'article' | 'reader'
}

export const FILTER_UNREAD: string = 'unread';
export const FILTER_STARRED: string = 'starred';
export const FILTER_ALL: string = 'all';

/** Swipe action values (Android SwipeGestureActions). */
export const SWIPE_NONE: number = 0;
export const SWIPE_TOGGLE_READ: number = 1;
export const SWIPE_TOGGLE_STARRED: number = 2;

/** Article summary length values (Android FlowArticleListDescPreference). */
export const DESC_NONE: number = 0;
export const DESC_SHORT: number = 1;
export const DESC_LONG: number = 2;

/** Reader body-text alignment (Android ReadingTextAlignPreference).
 *  Values are persisted as integers, so keep them stable. */
export const READ_ALIGN_START: number = 0;
export const READ_ALIGN_END: number = 1;
export const READ_ALIGN_CENTER: number = 2;
export const READ_ALIGN_JUSTIFY: number = 3;
export const READ_ALIGN_VALUES: number[] = [
  READ_ALIGN_START, READ_ALIGN_END, READ_ALIGN_CENTER, READ_ALIGN_JUSTIFY,
];

/** Default letter spacing (Android ReadingTextLetterSpacingPreference: 0.5F). */
export const READER_LETTER_SPACING_DEFAULT: number = 0.5;

/** UI label for a reader alignment value. */
export function readerAlignLabel(value: number): string {
  if (value === READ_ALIGN_END) return '右对齐';
  if (value === READ_ALIGN_CENTER) return '居中对齐';
  if (value === READ_ALIGN_JUSTIFY) return '两端对齐';
  return '左对齐';
}

/** CSS value injected into WebViewStyle's --text-align variable. */
export function readerAlignCss(value: number): string {
  if (value === READ_ALIGN_END) return 'end';
  if (value === READ_ALIGN_CENTER) return 'center';
  if (value === READ_ALIGN_JUSTIFY) return 'justify';
  return 'start';
}

/** The list scope an article was opened from. Prev/next must follow the same
 *  feed/group/filter/search as the visible list, not just the article's feed. */
export interface ArticleScope {
  feedId: string;
  groupId: string;
  filter: string;
  searchText: string;
}

/** Parameters passed through Navigation when opening the reader. */
export interface ReadingParam {
  articleId: string;
  scope: ArticleScope;
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
