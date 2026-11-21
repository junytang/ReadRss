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
    this.pref = await preferences.getPreferences(context, PREFS_NAME);
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
    return await this.pref.get(key, fallback) as boolean;
  }

  private async readInt(key: string, fallback: number): Promise<number> {
    if (!this.pref) {
      return fallback;
    }
    return await this.pref.get(key, fallback) as number;
  }

  private async readString(key: string, fallback: string): Promise<string> {
    if (!this.pref) {
      return fallback;
    }
    return await this.pref.get(key, fallback) as string;
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
    AppStorage.setOrCreate<number>('readerBodyFontSize', this.cache.readerBodyFontSize);
    AppStorage.setOrCreate<number>('readerPageMargin', this.cache.readerPageMargin);
    AppStorage.setOrCreate<number>('readerLineSpacing', this.cache.readerLineSpacing);
    AppStorage.setOrCreate<string>('readerFontFamily', this.cache.readerFontFamily);
    AppStorage.setOrCreate<number>('fontScale', this.cache.systemFontScale);
    AppStorage.setOrCreate<string>('systemFontFamily', this.cache.systemFontFamily);
  }

  private async write(key: string, value: boolean | number): Promise<void> {
    if (!this.pref) {
      return;
    }
    await this.pref.put(key, value);
    await this.pref.flush();
  }

  async setActiveAccountId(value: string): Promise<void> {
    this.cache.activeAccountId = value;
    if (this.pref) {
      await this.pref.put('activeAccountId', value);
      await this.pref.flush();
    }
  }

  async setDarkMode(value: boolean): Promise<void> {
    this.cache.darkMode = value;
    await this.write('darkMode', value);
  }

  async setSyncOnLaunch(value: boolean): Promise<void> {
    this.cache.syncOnLaunch = value;
    await this.write('syncOnLaunch', value);
  }

  async setMarkReadOnOpen(value: boolean): Promise<void> {
    this.cache.markReadOnOpen = value;
    await this.write('markReadOnOpen', value);
  }

  async setKeepArticleDays(value: number): Promise<void> {
    this.cache.keepArticleDays = value;
    await this.write('keepArticleDays', value);
  }

  async setMarkReadOnScroll(value: boolean): Promise<void> {
    this.cache.markReadOnScroll = value;
    await this.write('markReadOnScroll', value);
  }

  async setFetchBatchSize(value: number): Promise<void> {
    this.cache.fetchBatchSize = value;
    await this.write('fetchBatchSize', value);
  }

  async setCustomFontPath(value: string, name: string = ''): Promise<void> {
    this.cache.customFontPath = value;
    this.cache.customFontName = name;
    if (this.pref) {
      await this.pref.put('customFontPath', value);
      await this.pref.put('customFontName', name);
      await this.pref.flush();
    }
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
    if (this.pref) {
      await this.pref.put('articleFontFamily', value);
      await this.pref.flush();
    }
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
    if (this.pref) {
      await this.pref.put('readerFontFamily', value);
      await this.pref.flush();
    }
  }

  async setSystemFontScale(value: number): Promise<void> {
    this.cache.systemFontScale = value;
    AppStorage.setOrCreate<number>('fontScale', value);
    this.scheduleWrite('systemFontScale', value);
  }

  async setSystemFontFamily(value: string): Promise<void> {
    this.cache.systemFontFamily = value;
    AppStorage.setOrCreate<string>('systemFontFamily', value);
    if (this.pref) {
      await this.pref.put('systemFontFamily', value);
      await this.pref.flush();
    }
  }
}

export const settingsStore: ReadYouSettingsStore = new ReadYouSettingsStore();
