import { describe, it, expect } from '@ohos/hypium';
import { ArticleImageConverter } from '../main/ets/common/ArticleImageConverter';
import { pendingStatusRegistry } from '../main/ets/rss/PendingStatusRegistry';

export default function converterTest(): void {
  describe('ArticleImageConverter', () => {
    it('isVirtualUrl detects the AVIF marker', 0, () => {
      expect(ArticleImageConverter.isVirtualUrl('https://x/__ry_avif__/abc.jpg')).assertTrue();
      expect(ArticleImageConverter.isVirtualUrl('https://x/normal.jpg')).assertFalse();
    });

    it('keyFromUrl extracts the key after the marker', 0, () => {
      expect(ArticleImageConverter.keyFromUrl('https://x/__ry_avif__/abc.jpg')).assertEqual('abc.jpg');
    });

    it('getBytes returns undefined for unknown key', 0, () => {
      expect(ArticleImageConverter.getBytes('nonexistent-key-xyz')).assertUndefined();
    });
  });

  describe('PendingStatusRegistry', () => {
    it('add / has / remove semantics with unique ids', 0, () => {
      const id: string = 'probe-registry-' + Date.now().toString();
      expect(pendingStatusRegistry.has(id)).assertFalse();
      pendingStatusRegistry.add(id);
      expect(pendingStatusRegistry.has(id)).assertTrue();
      pendingStatusRegistry.remove(id);
      expect(pendingStatusRegistry.has(id)).assertFalse();
    });
  });
}
