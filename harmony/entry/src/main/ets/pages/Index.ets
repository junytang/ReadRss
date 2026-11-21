import { common, ConfigurationConstant } from '@kit.AbilityKit';
import {
  AccountEditorParam,
  FlowParam,
  FontPickerParam,
  ReadingParam,
  ROUTE_ACCOUNTS,
  ROUTE_ACCOUNT_EDITOR,
  ROUTE_ARTICLE_LIST_STYLE,
  ROUTE_FEEDS,
  ROUTE_FLOW,
  ROUTE_FONT_PICKER,
  ROUTE_READING,
  ROUTE_READER_STYLE,
  ROUTE_SETTINGS,
  ROUTE_SYSTEM_STYLE,
  ROUTE_SUBSCRIBE,
} from '../common/Constants';
import { navStack } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';
import { WindowInsets } from '../common/WindowInsets';
import { settingsStore } from '../data/SettingsStore';
import { FeedListView } from '../components/FeedListView';
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

  @Builder
  pageMap(name: string, param: Object): void {
    if (name === ROUTE_FLOW) {
      ArticleListView({
        feedId: (param as FlowParam).feedId,
        feedTitle: (param as FlowParam).feedTitle,
      });
    } else if (name === ROUTE_READING) {
      ReadingView({ articleId: (param as ReadingParam).articleId });
    } else if (name === ROUTE_SETTINGS) {
      SettingsView();
    } else if (name === ROUTE_SUBSCRIBE) {
      SubscribeView();
    } else if (name === ROUTE_FEEDS) {
      NavDestination() {
        FeedListView({ asDestination: true })
      }
      .hideTitleBar(true);
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

  aboutToAppear(): void {
    // Publish insets one last time right before the UI tree is built.
    AppStorage.set<number>('topInset', WindowInsets.top);
    AppStorage.set<number>('bottomInset', WindowInsets.bottom);
    AppStorage.set<number>('windowHeightVp', WindowInsets.height);
    const settings = settingsStore.get();
    AppStorage.setOrCreate<boolean>('darkMode', settings.darkMode);
    this.darkMode = settings.darkMode;
    FontManager.register(this.getUIContext(), settings.customFontPath);
    FontManager.setSystemFamily(settings.systemFontFamily);
    AppStorage.set<number>('fontScale', settings.systemFontScale);
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext) {
        const context = hostContext as common.UIAbilityContext;
        context.getApplicationContext().setColorMode(
          settings.darkMode
            ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
            : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        );
      }
    } catch (error) {
      // Color mode API may be unavailable on some form factors; ignore for MVP.
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
