import { describe, it, expect } from '@ohos/hypium';
import { settingsStore } from '../main/ets/data/SettingsStore';
import { defaultSettings } from '../main/ets/model/Models';

interface PrefField { pref: Object | undefined; }

/** In-memory preferences stand-in: get/put/delete/flush backed by a Map. */
class FakePref {
  data: Map<string, Object> = new Map<string, Object>();
  writes: number = 0;
  get(key: string, def: Object): Promise<Object> {
    return Promise.resolve(this.data.has(key) ? this.data.get(key) as Object : def);
  }
  put(key: string, value: Object): Promise<void> {
    this.data.set(key, value);
    return Promise.resolve();
  }
  flush(): Promise<void> { this.writes++; return Promise.resolve(); }
  delete(key: string): Promise<void> { this.data.delete(key); return Promise.resolve(); }
}

export default function settingsStoreTest(): void {
  describe('SettingsStore setters (no pref / cache+AppStorage)', () => {
    it('default cache matches defaultSettings', 0, () => {
      const s = settingsStore.get();
      expect(s.fetchBatchSize).assertEqual(defaultSettings().fetchBatchSize);
    });

    it('setDarkMode updates cache and AppStorage', 0, async () => {
      await settingsStore.setDarkMode(true);
      expect(settingsStore.get().darkMode).assertTrue();
      expect(AppStorage.get<boolean>('darkMode') ?? false).assertTrue();
      await settingsStore.setDarkMode(false);
      expect(settingsStore.get().darkMode).assertFalse();
    });

    it('setFetchBatchSize updates cache and AppStorage', 0, async () => {
      await settingsStore.setFetchBatchSize(250);
      expect(settingsStore.get().fetchBatchSize).assertEqual(250);
      expect(AppStorage.get<number>('fetchBatchSize') ?? 0).assertEqual(250);
      await settingsStore.setFetchBatchSize(100);
    });

    it('setMarkReadOnScroll publishes to AppStorage', 0, async () => {
      await settingsStore.setMarkReadOnScroll(true);
      expect(AppStorage.get<boolean>('markReadOnScroll') ?? false).assertTrue();
      await settingsStore.setMarkReadOnScroll(false);
    });

    it('behavior setters bump listSettingsTick', 0, async () => {
      AppStorage.setOrCreate<number>('listSettingsTick', 0);
      await settingsStore.setSortUnreadEarliest(true);
      expect((AppStorage.get<number>('listSettingsTick') ?? 0) > 0).assertTrue();
      expect(settingsStore.get().sortUnreadEarliest).assertTrue();
      await settingsStore.setSortUnreadEarliest(false);
    });

    it('setSwipeStartAction updates cache and AppStorage', 0, async () => {
      await settingsStore.setSwipeStartAction(2);
      expect(settingsStore.get().swipeStartAction).assertEqual(2);
      expect(AppStorage.get<number>('swipeStartAction') ?? 0).assertEqual(2);
      await settingsStore.setSwipeStartAction(1);
    });

    it('number setters apply to cache and AppStorage immediately', 0, async () => {
      await settingsStore.setArticleTitleFontSize(22);
      expect(settingsStore.get().articleTitleFontSize).assertEqual(22);
      expect(AppStorage.get<number>('articleTitleFontSize') ?? 0).assertEqual(22);
      await settingsStore.setArticleTitleFontSize(17);
    });

    it('setReaderFontFamily updates cache and AppStorage', 0, async () => {
      await settingsStore.setReaderFontFamily('serif');
      expect(settingsStore.get().readerFontFamily).assertEqual('serif');
      expect(AppStorage.get<string>('readerFontFamily') ?? '').assertEqual('serif');
      await settingsStore.setReaderFontFamily('sans-serif');
    });
  });

  describe('SettingsStore persistence with injected prefs', () => {
    it('setDarkMode persists to preferences (put+flush)', 0, async () => {
      const fake: FakePref = new FakePref();
      (settingsStore as object as PrefField).pref = fake as object;
      await settingsStore.setDarkMode(true);
      expect(fake.data.has('darkMode')).assertTrue();
      expect(fake.writes >= 1).assertTrue();
      (settingsStore as object as PrefField).pref = undefined;
    });

    it('setCustomFontPath persists path and name', 0, async () => {
      const fake: FakePref = new FakePref();
      (settingsStore as object as PrefField).pref = fake as object;
      await settingsStore.setCustomFontPath('/tmp/font.ttf', 'MyFont');
      expect(fake.data.get('customFontPath') as string).assertEqual('/tmp/font.ttf');
      expect(fake.data.get('customFontName') as string).assertEqual('MyFont');
      (settingsStore as object as PrefField).pref = undefined;
    });
  });
}
