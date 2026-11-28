import { describe, it, expect } from '@ohos/hypium';
import {
  shouldKeepFeverFirstSyncItem, FEVER_FRESH_MAX_PAGES,
} from '../main/ets/rss/FeverFirstSync';

export default function feverFirstSyncTest(): void {
  describe('Fever first-install scope', () => {
    it('only unread/starred ids are stored', 0, () => {
      const unread: Set<string> = new Set<string>(['u1', 'u2']);
      const starred: Set<string> = new Set<string>(['s1']);
      expect(shouldKeepFeverFirstSyncItem('u1', unread, starred)).assertTrue();
      expect(shouldKeepFeverFirstSyncItem('s1', unread, starred)).assertTrue();
      expect(shouldKeepFeverFirstSyncItem('r1', unread, starred)).assertFalse();
    });

    it('page budget bounds the fresh sync scan', 0, () => {
      expect(FEVER_FRESH_MAX_PAGES).assertEqual(30);
      // Fever returns at most 50 items per page.
      expect(FEVER_FRESH_MAX_PAGES * 50 <= 1500).assertTrue();
    });
  });
}
