import { describe, it, expect } from '@ohos/hypium';
import {
  parseEntryPublishedAt, gReaderPublishedAt,
} from '../main/ets/rss/EntryPublishedTime';

const NOW: number = 1700000000000;

/**
 * Parity tests for remote publish times. These are exactly the kind of test
 * that catches "same server, different interface, different list ordering"
 * regressions before they reach the UI: the derived timestamps and the sort
 * order they produce must be identical across GReader and Miniflux.
 */
export default function entryTimeTest(): void {
  describe('EntryPublishedTime parsing', () => {
    it('RFC3339 string parses to the same ms as GReader seconds', 0, () => {
      const iso: string = '2023-11-14T22:13:20Z'; // 1700000000 s
      expect(parseEntryPublishedAt(iso, 0, NOW))
        .assertEqual(gReaderPublishedAt(1700000000, NOW));
    });

    it('numeric seconds string is not treated as milliseconds', 0, () => {
      const parsed: number = parseEntryPublishedAt('1700000000', 0, NOW);
      expect(parsed).assertEqual(1700000000000);
    });

    it('numeric milliseconds string stays in ms', 0, () => {
      expect(parseEntryPublishedAt('1700000000000', 0, NOW)).assertEqual(NOW);
    });

    it('numeric seconds value is scaled', 0, () => {
      expect(parseEntryPublishedAt(1700000000, 0, NOW)).assertEqual(NOW);
    });

    it('missing or invalid falls back instead of pinning to now', 0, () => {
      expect(parseEntryPublishedAt(undefined, 123, NOW)).assertEqual(123);
      expect(parseEntryPublishedAt('not-a-date', 456, NOW)).assertEqual(456);
    });

    it('far-future timestamps still clamp to now', 0, () => {
      expect(parseEntryPublishedAt('1800000000000', 0, NOW)).assertEqual(NOW);
      expect(gReaderPublishedAt(1800000000, NOW)).assertEqual(NOW);
    });

    it('real entry: near-future published_at is kept, not rewritten to sync time', 0, () => {
      // Actual Miniflux entry 218877: published_at 10:37:53Z (= 18:37 UTC+8).
      // Both syncs ran BEFORE that instant (device showed 14:48 / 16:41), so
      // the old strict clamp rewrote it to each sync's time — the reported
      // 14:48 vs 16:41 discrepancy. A few hours of clock skew is normal.
      const published: number = new Date('2026-11-26T10:37:53Z').getTime();
      const earlyDevice: number = new Date('2026-11-26T06:48:00Z').getTime();
      const laterDevice: number = new Date('2026-11-26T08:41:00Z').getTime();
      expect(parseEntryPublishedAt('2026-11-26T10:37:53Z', earlyDevice, earlyDevice))
        .assertEqual(published);
      expect(parseEntryPublishedAt('2026-11-26T10:37:53Z', laterDevice, laterDevice))
        .assertEqual(published);
      expect(gReaderPublishedAt(published / 1000, laterDevice)).assertEqual(published);
    });
  });

  describe('Cross-interface ordering parity', () => {
    it('same entries sorted by derived time produce identical order', 0, () => {
      // Mimic one server's unread entries with mixed time representations.
      const ids: string[] = ['a', 'b', 'c', 'd'];
      const greaderSeconds: number[] = [1700000000, 1699990000, 1700005000, 1699980000];
      const minifluxRaw: Array<string | number> = [
        '2023-11-14T22:13:20Z', 1699990000, '1700005000000', 1699980000,
      ];
      const greaderTimes: number[] = greaderSeconds.map(
        (s: number): number => gReaderPublishedAt(s, NOW)
      );
      const minifluxTimes: number[] = minifluxRaw.map(
        (v: string | number): number => parseEntryPublishedAt(v, 0, NOW)
      );
      for (let i: number = 0; i < ids.length; i++) {
        expect(minifluxTimes[i]).assertEqual(greaderTimes[i]);
      }
      // The list sort is published_at DESC, id DESC. Same times -> same order.
      const gOrder: string[] = ids.slice().sort((x: string, y: string): number => {
        const gx: number = greaderTimes[ids.indexOf(x)];
        const gy: number = greaderTimes[ids.indexOf(y)];
        return gy - gx || y.localeCompare(x);
      });
      const mOrder: string[] = ids.slice().sort((x: string, y: string): number => {
        const mx: number = minifluxTimes[ids.indexOf(x)];
        const my: number = minifluxTimes[ids.indexOf(y)];
        return my - mx || y.localeCompare(x);
      });
      for (let i: number = 0; i < ids.length; i++) {
        expect(mOrder[i]).assertEqual(gOrder[i]);
      }
    });
  });
}
