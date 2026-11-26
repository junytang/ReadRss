import { describe, it, expect } from '@ohos/hypium';
import { NOTIFY_INTERVAL_MS } from '../main/ets/rss/SyncProgress';
import { UI_WINDOW_SIZE, SYNC_CONCURRENCY } from '../main/ets/rss/SyncRuntime';
import {
  ID_PAGE_SIZE, READ_ID_PAGES, STATE_ID_PAGES,
} from '../main/ets/rss/GoogleReaderSyncService';
import {
  ENTRY_PAGE_SIZE, MAX_FRESH_BODY_PAGES,
} from '../main/ets/rss/MinifluxSyncService';
import { selectContentFetchIds } from '../main/ets/rss/RemoteStateResolver';
import { articleRowKey } from '../main/ets/model/RowIdentity';
import { parseEntryPublishedAt, gReaderPublishedAt } from '../main/ets/rss/EntryPublishedTime';
import { remapSelectionToAccount } from '../main/ets/model/AccountSelection';
import { normalizeFeedText } from '../main/ets/model/FeedDisplay';
import { Article } from '../main/ets/model/Models';

function art(id: string, read: boolean, starred: boolean): Article {
  return {
    id: id, feedId: 'f', feedTitle: 'F', title: id, author: '', link: '',
    summary: '', content: '', fullContent: '', imageUrl: '', publishedAt: 0,
    isRead: read, isStarred: starred,
  };
}

/**
 * Executable form of the design constraints documented in README / AGENTS.md.
 * Several regressions (read-body fetch on fresh sync, id-only ForEach key,
 * id-based first-screen order, full-width feed names) slipped through because
 * the rule existed only in prose. These assertions make it fail in CI instead.
 */
export default function designInvariantsTest(): void {
  describe('Sync cost ceilings', () => {
    it('GReader read ids stay capped and are never used for content', 0, () => {
      expect(Number(ID_PAGE_SIZE)).assertEqual(1000);
      expect(READ_ID_PAGES).assertEqual(3);
      expect(READ_ID_PAGES * Number(ID_PAGE_SIZE) <= 3000).assertTrue();
      expect(STATE_ID_PAGES).assertEqual(20);
      const readIds: string[] = [];
      for (let i: number = 0; i < 3000; i++) {
        readIds.push(`r${i}`);
      }
      const fetched: string[] = selectContentFetchIds(
        new Set<string>(), ['u1'], ['s1'], readIds
      );
      expect(fetched.length).assertEqual(2);
      expect(fetched.indexOf('r0') < 0).assertTrue();
    });

    it('Miniflux fresh-sync history stays bounded', 0, () => {
      expect(ENTRY_PAGE_SIZE).assertEqual(300);
      expect(MAX_FRESH_BODY_PAGES).assertEqual(30);
      expect(ENTRY_PAGE_SIZE * MAX_FRESH_BODY_PAGES <= 9000).assertTrue();
    });

    it('progress ticks and concurrency are throttled', 0, () => {
      expect(UI_WINDOW_SIZE).assertEqual(20);
      expect(NOTIFY_INTERVAL_MS).assertEqual(800);
      expect(SYNC_CONCURRENCY).assertEqual(3);
    });
  });

  describe('UI identity / optimistic marks', () => {
    it('row key includes read and star state so marks refresh immediately', 0, () => {
      const base: string = articleRowKey(art('a1', false, false));
      expect(articleRowKey(art('a1', true, false)) === base).assertFalse();
      expect(articleRowKey(art('a1', false, true)) === base).assertFalse();
      expect(articleRowKey(art('a1', false, false))).assertEqual(base);
      expect(articleRowKey(art('a2', false, false)) === base).assertFalse();
    });
  });

  describe('Cross-protocol consistency', () => {
    it('remote time follows one rule across protocols', 0, () => {
      const now: number = new Date('2026-11-26T12:00:00Z').getTime();
      const published: number = new Date('2026-11-26T10:37:53Z').getTime();
      expect(parseEntryPublishedAt('2026-11-26T10:37:53Z', now, now)).assertEqual(published);
      expect(gReaderPublishedAt(published / 1000, now)).assertEqual(published);
    });

    it('selection survives an account switch by stable identity', 0, () => {
      const result = remapSelectionToAccount(
        '1|gr', '', [{ id: '1|gr', url: 'https://a/feed', title: 'F' }], [],
        [{ id: '2|42', url: 'https://b/feed', title: 'F' }], []
      );
      expect(result.feedId).assertEqual('2|42');
    });

    it('full-width feed urls render as half-width; ordinary titles untouched', 0, () => {
      expect(normalizeFeedText('https：／／a.example／rss'))
        .assertEqual('https://a.example/rss');
      expect(normalizeFeedText('科学网，博客')).assertEqual('科学网，博客');
    });
  });
}
