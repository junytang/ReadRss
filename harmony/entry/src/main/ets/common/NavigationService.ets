import {
  AccountEditorParam,
  ArticleScope,
  EmptyNavParam,
  FontPickerParam,
  ROUTE_ARTICLE_LIST_STYLE,
  ROUTE_FONT_PICKER,
  ROUTE_READER_STYLE,
  ROUTE_SYSTEM_STYLE,
  FlowParam,
  ReadingParam,
  ROUTE_ACCOUNTS,
  ROUTE_ACCOUNT_EDITOR,
  ROUTE_FLOW,
  ROUTE_READING,
  ROUTE_SETTINGS,
  ROUTE_SUBSCRIBE,
} from './Constants';

/** App-wide navigation stack so nested views can navigate without prop drilling. */
export const navStack: NavPathStack = new NavPathStack();

const noParam: EmptyNavParam = {};

export function openFlow(feedId: string, feedTitle: string): void {
  const param: FlowParam = {
    feedId: feedId,
    feedTitle: feedTitle,
  };
  navStack.pushPathByName(ROUTE_FLOW, param);
}

export function openArticle(articleId: string, scope?: ArticleScope): void {
  const param: ReadingParam = {
    articleId: articleId,
    scope: scope ?? { feedId: '', groupId: '', filter: '', searchText: '' },
  };
  navStack.pushPathByName(ROUTE_READING, param);
}

export function openSettings(): void {
  navStack.pushPathByName(ROUTE_SETTINGS, noParam);
}

export function openSubscribe(): void {
  navStack.pushPathByName(ROUTE_SUBSCRIBE, noParam);
}

export function openAccounts(): void {
  navStack.pushPathByName(ROUTE_ACCOUNTS, noParam);
}

export function openArticleListStyle(): void {
  navStack.pushPathByName(ROUTE_ARTICLE_LIST_STYLE, noParam);
}

export function openReaderStyle(): void {
  navStack.pushPathByName(ROUTE_READER_STYLE, noParam);
}

export function openSystemStyle(): void {
  navStack.pushPathByName(ROUTE_SYSTEM_STYLE, noParam);
}

export function openFontPicker(target: string): void {
  const param: FontPickerParam = { target: target };
  navStack.pushPathByName(ROUTE_FONT_PICKER, param);
}

/** Empty accountId means "add a new account". */
export function openAccountEditor(accountId: string): void {
  const param: AccountEditorParam = { accountId: accountId };
  navStack.pushPathByName(ROUTE_ACCOUNT_EDITOR, param);
}

export function goBack(): void {
  AppStorage.setOrCreate<number>('navBackTick', Date.now());
  navStack.pop();
}
