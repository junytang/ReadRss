import { describe, it, expect, MockKit } from '@ohos/hypium';
import { FontManager } from '../main/ets/common/FontManager';
import { fullContentPrefetcher } from '../main/ets/rss/FullContentPrefetcher';
import { feedIconCache } from '../main/ets/common/FeedIconCache';

// Access private prefetcher internals via named interfaces.
interface PrefetchAccess {
  done: Set<string>;
  failed: Set<string>;
  lastSeen: Map<string, number>;
  evictFarthest(tracked: Set<string>, currentIndex: number): void;
}

export default function miscModulesTest(): void {
  describe('FontManager family resolution', () => {
    it('familyFor resolves custom/system/empty', 0, () => {
      expect(FontManager.familyFor('serif')).assertEqual('serif');
      expect(FontManager.familyFor('')).assertEqual('sans-serif');
      // 'custom' without registration falls back to system default.
      expect(FontManager.familyFor('custom')).assertEqual('sans-serif');
    });

    it('setSystemFamily applies resolved family', 0, () => {
      FontManager.setSystemFamily('serif');
      expect(FontManager.family()).assertEqual('serif');
      FontManager.setSystemFamily('sans-serif');
      expect(FontManager.family()).assertEqual('sans-serif');
    });

    it('isCustomInstalled false initially', 0, () => {
      expect(FontManager.isCustomInstalled()).assertFalse();
    });
  });

  describe('FullContentPrefetcher viewport eviction', () => {
    it('evictFarthest removes id farthest from viewport', 0, () => {
      const p: PrefetchAccess = fullContentPrefetcher as object as PrefetchAccess;
      const tracked: Set<string> = new Set<string>(['near', 'far']);
      p.lastSeen.set('near', 100);
      p.lastSeen.set('far', 0); // farthest from viewport index 100
      // Inflate past MAX_TRACKED(300); give fillers a near position so 'far'
      // is the single farthest and gets evicted first.
      for (let i: number = 0; i < 301; i++) {
        const id: string = 'x' + i.toString();
        tracked.add(id);
        p.lastSeen.set(id, 99);
      }
      p.evictFarthest(tracked, 100);
      expect(tracked.size <= 300).assertTrue();
      expect(tracked.has('far')).assertFalse(); // farthest removed
      expect(tracked.has('near')).assertTrue();
      p.lastSeen.clear();
    });
  });

  describe('FeedIconCache memory cache', () => {
    it('cachedPath empty for unknown url', 0, () => {
      expect(feedIconCache.cachedPath('https://unknown-icon-url.invalid/x.png')).assertEqual('');
    });
  });
}
