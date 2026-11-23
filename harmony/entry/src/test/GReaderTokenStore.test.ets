import { describe, it, expect } from '@ohos/hypium';
import { gReaderTokenStore, CachedAuth } from '../main/ets/rss/GReaderTokenStore';

interface PrefField { pref: Object | undefined; }
interface KeyAccess { key(serverUrl: string, username: string): string; }

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

export default function gReaderTokenStoreTest(): void {
  describe('GReaderTokenStore without prefs', () => {
    it('load returns undefined when not initialized', 0, async () => {
      const r = await gReaderTokenStore.load('https://x', 'u');
      expect(r === undefined).assertTrue();
    });

    it('save/clear are no-ops without prefs', 0, async () => {
      await gReaderTokenStore.save('https://x', 'u', 'lt', 'at');
      await gReaderTokenStore.clear('https://x', 'u');
      expect(true).assertTrue();
    });
  });

  describe('GReaderTokenStore key sanitization', () => {
    it('key sanitizes non-word chars', 0, () => {
      const access = gReaderTokenStore as object as KeyAccess;
      const k: string = access.key('https://freshrss.example.com/', 'user@example.com');
      expect(k.indexOf('https') >= 0).assertTrue();
      expect(k.indexOf('/') >= 0).assertFalse();
      expect(k.indexOf('@') >= 0).assertFalse();
      expect(k.indexOf('.') >= 0).assertFalse();
    });
  });

  describe('GReaderTokenStore with injected prefs', () => {
    it('save then load returns cached auth', 0, async () => {
      const fake: FakePref = new FakePref();
      (gReaderTokenStore as object as PrefField).pref = fake as object;
      await gReaderTokenStore.save('https://x', 'u', 'login123', 'action456');
      const auth: CachedAuth | undefined = await gReaderTokenStore.load('https://x', 'u');
      expect(auth !== undefined).assertTrue();
      expect(auth!.loginToken).assertEqual('login123');
      expect(auth!.actionToken).assertEqual('action456');
      expect((auth!.expiresAt > Date.now())).assertTrue();
      (gReaderTokenStore as object as PrefField).pref = undefined;
    });

    it('load clears expired token', 0, async () => {
      const fake: FakePref = new FakePref();
      (gReaderTokenStore as object as PrefField).pref = fake as object;
      const access = gReaderTokenStore as object as KeyAccess;
      const key: string = access.key('https://x', 'u');
      const expired: CachedAuth = { loginToken: 'l', actionToken: 'a', expiresAt: Date.now() - 1000 };
      fake.data.set(key, JSON.stringify(expired) as Object);
      const auth: CachedAuth | undefined = await gReaderTokenStore.load('https://x', 'u');
      expect(auth === undefined).assertTrue();
      expect(fake.data.has(key)).assertFalse(); // cleared
      (gReaderTokenStore as object as PrefField).pref = undefined;
    });

    it('load returns undefined on corrupt JSON', 0, async () => {
      const fake: FakePref = new FakePref();
      (gReaderTokenStore as object as PrefField).pref = fake as object;
      const access = gReaderTokenStore as object as KeyAccess;
      fake.data.set(access.key('https://x', 'u'), 'not-json' as Object);
      const auth: CachedAuth | undefined = await gReaderTokenStore.load('https://x', 'u');
      expect(auth === undefined).assertTrue();
      (gReaderTokenStore as object as PrefField).pref = undefined;
    });

    it('clear removes the stored token', 0, async () => {
      const fake: FakePref = new FakePref();
      (gReaderTokenStore as object as PrefField).pref = fake as object;
      await gReaderTokenStore.save('https://x', 'u', 'l', 'a');
      await gReaderTokenStore.clear('https://x', 'u');
      const access = gReaderTokenStore as object as KeyAccess;
      expect(fake.data.has(access.key('https://x', 'u'))).assertFalse();
      (gReaderTokenStore as object as PrefField).pref = undefined;
    });
  });
}
