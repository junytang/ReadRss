import {
  AccountEditorParam,
  EmptyNavParam,
  FlowParam,
  ReadingParam,
  ROUTE_ACCOUNTS,
  ROUTE_ACCOUNT_EDITOR,
  ROUTE_FEEDS,
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

export function openArticle(articleId: string): void {
  const param: ReadingParam = { articleId: articleId };
  navStack.pushPathByName(ROUTE_READING, param);
}

export function openSettings(): void {
  navStack.pushPathByName(ROUTE_SETTINGS, noParam);
}

export function openSubscribe(): void {
  navStack.pushPathByName(ROUTE_SUBSCRIBE, noParam);
}

export function openFeeds(): void {
  navStack.pushPathByName(ROUTE_FEEDS, noParam);
}

export function openAccounts(): void {
  navStack.pushPathByName(ROUTE_ACCOUNTS, noParam);
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
