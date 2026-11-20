import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppSettings, defaultSettings } from '../model/Models';
import { PREFS_NAME } from '../common/Constants';

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
      fontSizeIndex: await this.readInt('fontSizeIndex', this.cache.fontSizeIndex),
      customFontPath: await this.readString('customFontPath', this.cache.customFontPath),
      markReadOnScroll: await this.readBool('markReadOnScroll', this.cache.markReadOnScroll),
      keepArticleDays: await this.readInt('keepArticleDays', this.cache.keepArticleDays),
      fetchBatchSize: await this.readInt('fetchBatchSize', this.cache.fetchBatchSize),
    };
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

  private async write(key: string, value: boolean | number): Promise<void> {
    if (!this.pref) {
      return;
    }
    if (typeof value === 'boolean') {
      await this.pref.put(key, value);
    } else {
      await this.pref.put(key, value);
    }
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

  async setCustomFontPath(value: string): Promise<void> {
    this.cache.customFontPath = value;
    if (this.pref) {
      await this.pref.put('customFontPath', value);
      await this.pref.flush();
    }
  }

  async setFontSizeIndex(value: number): Promise<void> {
    this.cache.fontSizeIndex = value;
    await this.write('fontSizeIndex', value);
  }

  async setFetchBatchSize(value: number): Promise<void> {
    this.cache.fetchBatchSize = value;
    await this.write('fetchBatchSize', value);
  }
}

export const settingsStore: ReadYouSettingsStore = new ReadYouSettingsStore();
