import { describe, it, expect } from '@ohos/hypium';
import { ArticlePaging, AppendResult } from '../main/ets/rss/ArticlePaging';
import { Article } from '../main/ets/model/Models';

function art(id: string): Article {
  const a: Article = {
    id: id, feedId: 'f1', feedTitle: 'F', title: id, author: '', link: '',
    summary: '', content: '', fullContent: '', imageUrl: '', publishedAt: 0,
    isRead: false, isStarred: false,
  };
  return a;
}

export default function pagingTest(): void {
  describe('ArticlePaging - load guards', () => {
    it('beginLoad bumps seq, invalidates page seq, freezes order', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const s1: number = p.beginLoad(30, 'order-A', true);
      expect(s1).assertEqual(1);
      expect(p.getPageSeq()).assertEqual(1);
      expect(p.getOrderKey()).assertEqual('order-A');
      expect(p.getDisplayLimit()).assertEqual(30);
    });

    it('resetPaging=false keeps displayLimit', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      p.beginLoad(50, 'o', true);
      p.setDisplayLimit(200);
      p.beginLoad(50, 'o', false);
      expect(p.getDisplayLimit()).assertEqual(200);
    });

    it('isStale detects a newer load', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const s1: number = p.beginLoad(30, 'o', true);
      // A second load supersedes the first.
      p.beginLoad(30, 'o2', true);
      expect(p.isStale(s1, p.getPageSeq(), 'o')).assertTrue();
      expect(p.isStale(p.getLoadSeq(), p.getPageSeq(), 'o2')).assertFalse();
    });

    it('isStale detects an orderKey switch (sort/filter change)', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const s1: number = p.beginLoad(30, 'order-A', true);
      expect(p.isStale(s1, p.getPageSeq(), 'order-B')).assertTrue();
    });

    it('isPageStale detects a new loadMore page', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const s: number = p.beginLoad(30, 'o', true);
      const pg1: number = p.beginLoadMore();
      p.endLoadMore();
      const pg2: number = p.beginLoadMore();
      expect(p.isPageStale(s, pg1)).assertTrue();
      expect(p.isPageStale(s, pg2)).assertFalse();
    });
  });

  describe('ArticlePaging - loadMore guards', () => {
    it('beginLoadMore refused while loading or no more data', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      p.beginLoad(30, 'o', true);
      p.updateHasMore(10, 30); // fewer rows than limit -> exhausted
      expect(p.beginLoadMore()).assertEqual(-1);
      p.updateHasMore(30, 30); // full page -> more data
      expect(p.beginLoadMore() >= 1).assertTrue();
      // Already loading -> refused.
      expect(p.beginLoadMore()).assertEqual(-1);
    });
  });

  describe('ArticlePaging - hasMore / limits', () => {
    it('updateHasMore: full page means more, short page means end', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      p.updateHasMore(30, 30);
      expect(p.getHasMore()).assertTrue();
      p.updateHasMore(12, 30);
      expect(p.getHasMore()).assertFalse();
    });

    it('nextExpandTarget clamps to full page', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      p.beginLoad(100, 'o', true);
      expect(p.nextExpandTarget(500, 100)).assertEqual(200);
      p.setDisplayLimit(450);
      expect(p.nextExpandTarget(500, 100)).assertEqual(500);
    });
  });

  describe('ArticlePaging - append dedupe', () => {
    it('mergeAppend appends only fresh ids', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const existing: Article[] = [art('1'), art('2')];
      const rows: Article[] = [art('2'), art('3'), art('4')];
      const result: AppendResult = p.mergeAppend(existing, rows);
      expect(result.appended).assertTrue();
      expect(result.articles.length).assertEqual(4);
      expect(result.articles[2].id).assertEqual('3');
      expect(result.articles[3].id).assertEqual('4');
    });

    it('mergeAppend returns unchanged when all rows known', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const existing: Article[] = [art('1'), art('2')];
      const result: AppendResult = p.mergeAppend(existing, [art('1'), art('2')]);
      expect(result.appended).assertFalse();
      expect(result.articles.length).assertEqual(2);
    });

    it('mergeAppend handles empty query result', 0, () => {
      const p: ArticlePaging = new ArticlePaging();
      const result: AppendResult = p.mergeAppend([art('1')], []);
      expect(result.appended).assertFalse();
      expect(result.articles.length).assertEqual(1);
    });
  });
}
