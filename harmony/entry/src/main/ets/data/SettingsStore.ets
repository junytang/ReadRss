import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppSettings, defaultSettings } from '../model/Models';
import { PREFS_NAME } from '../common/Constants';
import { Logger } from '../common/Logger';

/** Small preferences wrapper, equivalent to the Android DataStore preference classes. */
class ReadYouSettingsStore {
  private pref?: preferences.Preferences;
  private cache: AppSettings = defaultSettings();

  async init(context: common.Context): Promise<void> {
    // getPreferences is @throws: fall back to in-memory defaults when the
    // preferences service is unavailable instead of aborting app startup.
    try {
      this.pref = await preferences.getPreferences(context, PREFS_NAME);
    } catch (error) {
      Logger.warn(`Preferences unavailable, using defaults: ${(error as Error).message}`);
    }
    this.cache = {
      activeAccountId: await this.readString('activeAccountId', this.cache.activeAccountId),
      darkMode: await this.readBool('darkMode', this.cache.darkMode),
      syncOnLaunch: await this.readBool('syncOnLaunch', this.cache.syncOnLaunch),
      markReadOnOpen: await this.readBool('markReadOnOpen', this.cache.markReadOnOpen),
      markReadOnScroll: await this.readBool('markReadOnScroll', this.cache.markReadOnScroll),
      keepArticleDays: await this.readInt('keepArticleDays', this.cache.keepArticleDays),
      fetchBatchSize: await this.readInt('fetchBatchSize', this.cache.fetchBatchSize),
      articleTitleFontSize: await this.readInt('articleTitleFontSize', this.cache.articleTitleFontSize),
      articleSummaryFontSize: await this.readInt('articleSummaryFontSize', this.cache.articleSummaryFontSize),
      articleMetaFontSize: await this.readInt('articleMetaFontSize', this.cache.articleMetaFontSize),
      articleFontFamily: await this.readString('articleFontFamily', this.cache.articleFontFamily),
      sortUnreadEarliest: await this.readBool('sortUnreadEarliest', this.cache.sortUnreadEarliest),
      swipeStartAction: await this.readInt('swipeStartAction', this.cache.swipeStartAction),
      swipeEndAction: await this.readInt('swipeEndAction', this.cache.swipeEndAction),
      showFeedIcon: await this.readBool('showFeedIcon', this.cache.showFeedIcon),
      showFeedName: await this.readBool('showFeedName', this.cache.showFeedName),
      showArticleImage: await this.readBool('showArticleImage', this.cache.showArticleImage),
      articleDescLength: await this.readInt('articleDescLength', this.cache.articleDescLength),
      readerBodyFontSize: await this.readInt('readerBodyFontSize', this.cache.readerBodyFontSize),
      readerPageMargin: await this.readInt('readerPageMargin', this.cache.readerPageMargin),
      readerLineSpacing: await this.readInt('readerLineSpacing', this.cache.readerLineSpacing),
      readerFontFamily: await this.readString('readerFontFamily', this.cache.readerFontFamily),
      systemFontScale: await this.readInt('systemFontScale', this.cache.systemFontScale),
      systemFontFamily: await this.readString('systemFontFamily', this.cache.systemFontFamily),
      customFontPath: await this.readString('customFontPath', this.cache.customFontPath),
      customFontName: await this.readString('customFontName', this.cache.customFontName),
    };
    this.publishAppearance();
  }

  private async readBool(key: string, fallback: boolean): Promise<boolean> {
    if (!this.pref) {
      return fallback;
    }
    try {
      return await this.pref.get(key, fallback) as boolean;
    } catch (error) {
      Logger.warn(`Read setting ${key} failed: ${(error as Error).message}`);
      return fallback;
    }
  }

  private async readInt(key: string, fallback: number): Promise<number> {
    if (!this.pref) {
      return fallback;
    }
    try {
      return await this.pref.get(key, fallback) as number;
    } catch (error) {
      Logger.warn(`Read setting ${key} failed: ${(error as Error).message}`);
      return fallback;
    }
  }

  private async readString(key: string, fallback: string): Promise<string> {
    if (!this.pref) {
      return fallback;
    }
    try {
      return await this.pref.get(key, fallback) as string;
    } catch (error) {
      Logger.warn(`Read setting ${key} failed: ${(error as Error).message}`);
      return fallback;
    }
  }

  get(): AppSettings {
    return this.cache;
  }

  /** Publish the appearance values so the list and reader update live. */
  private publishAppearance(): void {
    AppStorage.setOrCreate<number>('articleTitleFontSize', this.cache.articleTitleFontSize);
    AppStorage.setOrCreate<number>('articleSummaryFontSize', this.cache.articleSummaryFontSize);
    AppStorage.setOrCreate<number>('articleMetaFontSize', this.cache.articleMetaFontSize);
    AppStorage.setOrCreate<string>('articleFontFamily', this.cache.articleFontFamily);
    AppStorage.setOrCreate<boolean>('sortUnreadEarliest', this.cache.sortUnreadEarliest);
    AppStorage.setOrCreate<number>('swipeStartAction', this.cache.swipeStartAction);
    AppStorage.setOrCreate<number>('swipeEndAction', this.cache.swipeEndAction);
    AppStorage.setOrCreate<boolean>('showFeedIcon', this.cache.showFeedIcon);
    AppStorage.setOrCreate<boolean>('showFeedName', this.cache.showFeedName);
    AppStorage.setOrCreate<boolean>('showArticleImage', this.cache.showArticleImage);
    AppStorage.setOrCreate<number>('articleDescLength', this.cache.articleDescLength);
    AppStorage.setOrCreate<number>('readerBodyFontSize', this.cache.readerBodyFontSize);
    AppStorage.setOrCreate<number>('readerPageMargin', this.cache.readerPageMargin);
    AppStorage.setOrCreate<number>('readerLineSpacing', this.cache.readerLineSpacing);
    AppStorage.setOrCreate<string>('readerFontFamily', this.cache.readerFontFamily);
    AppStorage.setOrCreate<number>('fontScale', this.cache.systemFontScale);
    AppStorage.setOrCreate<string>('systemFontFamily', this.cache.systemFontFamily);
    // Publish every setting that any page binds to, so AppStorage is always the
    // single source of truth and a change in one page updates all listeners.
    AppStorage.setOrCreate<boolean>('darkMode', this.cache.darkMode);
    AppStorage.setOrCreate<string>('activeAccountId', this.cache.activeAccountId);
    AppStorage.setOrCreate<boolean>('syncOnLaunch', this.cache.syncOnLaunch);
    AppStorage.setOrCreate<boolean>('markReadOnOpen', this.cache.markReadOnOpen);
    AppStorage.setOrCreate<boolean>('markReadOnScroll', this.cache.markReadOnScroll);
    AppStorage.setOrCreate<number>('keepArticleDays', this.cache.keepArticleDays);
    AppStorage.setOrCreate<number>('fetchBatchSize', this.cache.fetchBatchSize);
    AppStorage.setOrCreate<string>('customFontName', this.cache.customFontName);
  }

  private async write(key: string, value: boolean | number | string): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      await this.pref.put(key, value);
      await this.pref.flush();
    } catch (error) {
      Logger.warn(`Persist setting ${key} failed: ${(error as Error).message}`);
    }
  }

  /** String variant kept separate so ArkTS keeps the value type precise at
   *  each call site while sharing the @throws handling with write(). */
  private async writeString(key: string, value: string): Promise<void> {
    await this.write(key, value);
  }

  async setActiveAccountId(value: string): Promise<void> {
    this.cache.activeAccountId = value;
    AppStorage.setOrCreate<string>('activeAccountId', value);
    AppStorage.setOrCreate<number>('accountSwitchTick', Date.now());
    await this.writeString('activeAccountId', value);
  }

  async setDarkMode(value: boolean): Promise<void> {
    this.cache.darkMode = value;
    AppStorage.setOrCreate<boolean>('darkMode', value);
    await this.write('darkMode', value);
  }

  async setSyncOnLaunch(value: boolean): Promise<void> {
    this.cache.syncOnLaunch = value;
    AppStorage.setOrCreate<boolean>('syncOnLaunch', value);
    await this.write('syncOnLaunch', value);
  }

  async setMarkReadOnOpen(value: boolean): Promise<void> {
    this.cache.markReadOnOpen = value;
    AppStorage.setOrCreate<boolean>('markReadOnOpen', value);
    await this.write('markReadOnOpen', value);
  }

  async setKeepArticleDays(value: number): Promise<void> {
    this.cache.keepArticleDays = value;
    AppStorage.setOrCreate<number>('keepArticleDays', value);
    await this.write('keepArticleDays', value);
  }

  async setMarkReadOnScroll(value: boolean): Promise<void> {
    this.cache.markReadOnScroll = value;
    // Publish so the always-mounted ArticleListView reacts immediately. A plain
    // @State there only refreshed via load()/onShown, which may not fire when
    // returning from the settings page — leaving the old value in effect.
    AppStorage.setOrCreate<boolean>('markReadOnScroll', value);
    await this.write('markReadOnScroll', value);
  }

  async setFetchBatchSize(value: number): Promise<void> {
    this.cache.fetchBatchSize = value;
    AppStorage.setOrCreate<number>('fetchBatchSize', value);
    await this.write('fetchBatchSize', value);
  }

  async setCustomFontPath(value: string, name: string = ''): Promise<void> {
    this.cache.customFontPath = value;
    this.cache.customFontName = name;
    AppStorage.setOrCreate<string>('customFontName', name);
    AppStorage.setOrCreate<number>('fontDataTick', Date.now());
    await this.writeString('customFontPath', value);
    await this.writeString('customFontName', name);
  }

  // Debounced disk writes for slider-backed settings. onChange fires every
  // frame while dragging; updating cache + AppStorage is cheap (live preview),
  // but flushing preferences on every frame is expensive. Coalesce to one
  // write after the user stops moving the slider.
  private persistTimers: Map<string, number> = new Map<string, number>();

  private scheduleWrite(key: string, value: number): void {
    const existing: number | undefined = this.persistTimers.get(key);
    if (existing !== undefined) {
      clearTimeout(existing);
    }
    const timer: number = setTimeout(() => {
      this.persistTimers.delete(key);
      this.write(key, value).catch((error: Error) => {
        Logger.error(`Persist ${key} failed: ${error.message}`);
      });
    }, 200);
    this.persistTimers.set(key, timer);
  }

  private async setNumber(key: string, value: number, apply: (v: number) => void): Promise<void> {
    apply(value);
    this.scheduleWrite(key, value);
  }

  async setArticleTitleFontSize(value: number): Promise<void> {
    await this.setNumber('articleTitleFontSize', value, (v: number) => {
      this.cache.articleTitleFontSize = v;
      AppStorage.setOrCreate<number>('articleTitleFontSize', v);
    });
  }

  async setArticleSummaryFontSize(value: number): Promise<void> {
    await this.setNumber('articleSummaryFontSize', value, (v: number) => {
      this.cache.articleSummaryFontSize = v;
      AppStorage.setOrCreate<number>('articleSummaryFontSize', v);
    });
  }

  async setArticleMetaFontSize(value: number): Promise<void> {
    await this.setNumber('articleMetaFontSize', value, (v: number) => {
      this.cache.articleMetaFontSize = v;
      AppStorage.setOrCreate<number>('articleMetaFontSize', v);
    });
  }

  async setArticleFontFamily(value: string): Promise<void> {
    this.cache.articleFontFamily = value;
    AppStorage.setOrCreate<string>('articleFontFamily', value);
    await this.writeString('articleFontFamily', value);
  }

  /** Generic boolean setter for article-list behavior toggles. */
  private async setBool(key: string, value: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(key, value);
    await this.write(key, value);
  }

  /** Generic number setter for article-list behavior choices. */
  private async setInt(key: string, value: number): Promise<void> {
    AppStorage.setOrCreate<number>(key, value);
    await this.write(key, value);
  }

  /** Bump a tick so the visible article list reloads after a behavior change. */
  private bumpListSettings(): void {
    AppStorage.setOrCreate<number>('listSettingsTick', Date.now());
  }

  async setSortUnreadEarliest(value: boolean): Promise<void> {
    this.cache.sortUnreadEarliest = value;
    await this.setBool('sortUnreadEarliest', value);
    this.bumpListSettings();
  }

  async setSwipeStartAction(value: number): Promise<void> {
    this.cache.swipeStartAction = value;
    await this.setInt('swipeStartAction', value);
    this.bumpListSettings();
  }

  async setSwipeEndAction(value: number): Promise<void> {
    this.cache.swipeEndAction = value;
    await this.setInt('swipeEndAction', value);
    this.bumpListSettings();
  }

  async setShowFeedIcon(value: boolean): Promise<void> {
    this.cache.showFeedIcon = value;
    await this.setBool('showFeedIcon', value);
    this.bumpListSettings();
  }

  async setShowFeedName(value: boolean): Promise<void> {
    this.cache.showFeedName = value;
    await this.setBool('showFeedName', value);
    this.bumpListSettings();
  }

  async setShowArticleImage(value: boolean): Promise<void> {
    this.cache.showArticleImage = value;
    await this.setBool('showArticleImage', value);
    this.bumpListSettings();
  }

  async setArticleDescLength(value: number): Promise<void> {
    this.cache.articleDescLength = value;
    await this.setInt('articleDescLength', value);
    this.bumpListSettings();
  }

  async setReaderBodyFontSize(value: number): Promise<void> {
    await this.setNumber('readerBodyFontSize', value, (v: number) => {
      this.cache.readerBodyFontSize = v;
      AppStorage.setOrCreate<number>('readerBodyFontSize', v);
    });
  }

  async setReaderPageMargin(value: number): Promise<void> {
    await this.setNumber('readerPageMargin', value, (v: number) => {
      this.cache.readerPageMargin = v;
      AppStorage.setOrCreate<number>('readerPageMargin', v);
    });
  }

  async setReaderLineSpacing(value: number): Promise<void> {
    await this.setNumber('readerLineSpacing', value, (v: number) => {
      this.cache.readerLineSpacing = v;
      AppStorage.setOrCreate<number>('readerLineSpacing', v);
    });
  }

  async setReaderFontFamily(value: string): Promise<void> {
    this.cache.readerFontFamily = value;
    AppStorage.setOrCreate<string>('readerFontFamily', value);
    await this.writeString('readerFontFamily', value);
  }

  async setSystemFontScale(value: number): Promise<void> {
    this.cache.systemFontScale = value;
    AppStorage.setOrCreate<number>('fontScale', value);
    this.scheduleWrite('systemFontScale', value);
  }

  async setSystemFontFamily(value: string): Promise<void> {
    this.cache.systemFontFamily = value;
    AppStorage.setOrCreate<string>('systemFontFamily', value);
    await this.writeString('systemFontFamily', value);
  }
}

export const settingsStore: ReadYouSettingsStore = new ReadYouSettingsStore();
