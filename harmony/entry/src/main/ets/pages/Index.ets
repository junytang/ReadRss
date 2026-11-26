import {
  AccountEditorParam,
  ArticleScope,
  FlowParam,
  FontPickerParam,
  ReadingParam,
  ROUTE_ACCOUNTS,
  ROUTE_ACCOUNT_EDITOR,
  ROUTE_ARTICLE_LIST_STYLE,
  ROUTE_FLOW,
  ROUTE_FONT_PICKER,
  ROUTE_READING,
  ROUTE_READER_STYLE,
  ROUTE_SETTINGS,
  ROUTE_SYSTEM_STYLE,
  ROUTE_SUBSCRIBE,
} from '../common/Constants';
import { navStack, openSettings, openAccounts, openAccountEditor } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';
import { WindowInsets } from '../common/WindowInsets';
import { settingsStore } from '../data/SettingsStore';
import { ArticleListView } from '../components/ArticleListView';
import { ReadingView } from '../components/ReadingView';
import { SettingsView } from '../components/SettingsView';
import { SubscribeView } from '../components/SubscribeView';
import { AccountsView } from '../components/AccountsView';
import { AccountEditorView } from '../components/AccountEditorView';
import { ArticleListStyleView } from '../components/ArticleListStyleView';
import { ReaderStyleView } from '../components/ReaderStyleView';
import { FontPickerView } from '../components/FontPickerView';
import { SystemStyleView } from '../components/SystemStyleView';

/** Root page: owns the Navigation container and the route table. */
@Entry
@Component
struct Index {
  @State pathStack: NavPathStack = navStack;
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('firstRunTick') @Watch('onFirstRunTick') firstRunTick: number = 0;
  private firstRunGuided: boolean = false;
  private guideTimer: number = 0;

  @Builder
  pageMap(name: string, param: Object): void {
    if (name === ROUTE_FLOW) {
      ArticleListView({
        feedId: (param as FlowParam).feedId,
        feedTitle: (param as FlowParam).feedTitle,
      });
    } else if (name === ROUTE_READING) {
      ReadingView({
        articleId: (param as ReadingParam).articleId,
        scope: (param as ReadingParam).scope ?? {
          feedId: '', groupId: '', filter: '', searchText: '',
        } as ArticleScope,
      });
    } else if (name === ROUTE_SETTINGS) {
      SettingsView();
    } else if (name === ROUTE_SUBSCRIBE) {
      SubscribeView();
    } else if (name === ROUTE_ACCOUNTS) {
      AccountsView();
    } else if (name === ROUTE_ACCOUNT_EDITOR) {
      AccountEditorView({ accountId: (param as AccountEditorParam).accountId });
    } else if (name === ROUTE_ARTICLE_LIST_STYLE) {
      ArticleListStyleView();
    } else if (name === ROUTE_READER_STYLE) {
      ReaderStyleView();
    } else if (name === ROUTE_FONT_PICKER) {
      FontPickerView({ target: (param as FontPickerParam).target });
    } else if (name === ROUTE_SYSTEM_STYLE) {
      SystemStyleView();
    }
  }

  /** First install: guide the user to the add-account page (under Settings >
   *  Account management). The tick is published by EntryAbility before the UI
   *  loads, so aboutToAppear catches it; the watcher covers later updates. */
  private guideFirstRun(): void {
    if (this.firstRunGuided || this.firstRunTick <= 0) {
      return;
    }
    this.firstRunGuided = true;
    // Defer until the Navigation container is attached to the stack.
    this.guideTimer = setTimeout((): void => {
      this.guideTimer = 0;
      if (!this.firstRunGuided) return;
      openSettings();
      openAccounts();
      openAccountEditor('');
    }, 200);
  }

  onFirstRunTick(): void {
    // Guide is strictly first-install only. Deleting the last account does not
    // re-arm it (that would push Settings+Accounts+Editor onto an existing
    // route stack and force several back presses).
    this.guideFirstRun();
  }

  aboutToAppear(): void {
    this.guideFirstRun();
    // Publish insets one last time right before the UI tree is built.
    AppStorage.set<number>('topInset', WindowInsets.top);
    AppStorage.setOrCreate<number>('bottomInset', WindowInsets.bottom);
    AppStorage.setOrCreate<number>('windowHeightVp', WindowInsets.height);
    const settings = settingsStore.get();
    AppStorage.setOrCreate<boolean>('darkMode', settings.darkMode);
    this.darkMode = settings.darkMode;
    // Color-mode switching happens in EntryAbility BEFORE loadContent (doing it
    // here triggers a global re-layout — all text jitters once on first paint).
    // The custom font must be registered here with THIS page's UIContext; using
    // the window's context before loadContent has no bound page and is discarded.
    FontManager.register(this.getUIContext(), settings.customFontPath);
    FontManager.setSystemFamily(settings.systemFontFamily);
    AppStorage.set<number>('fontScale', settings.systemFontScale);
  }

  aboutToDisappear(): void {
    if (this.guideTimer !== 0) {
      clearTimeout(this.guideTimer);
      this.guideTimer = 0;
    }
  }

  build() {
    Column() {
      // System status-bar safe area (standard edge-to-edge layout).
      Row()
        .width('100%')
        .height(this.topInset)

      Navigation(this.pathStack) {
        ArticleListView({ feedId: '', feedTitle: '未读文章', isRoot: true })
      }
      .navDestination(this.pageMap)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')
    // Standard ArkUI way: extend only the background into the bottom safe area,
    // while the system still reserves top space for the status bar.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
