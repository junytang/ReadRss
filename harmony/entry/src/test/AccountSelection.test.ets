import { describe, it, expect } from '@ohos/hypium';
import {
  remapSelectionToAccount, SelectionFeed, SelectionGroup, SelectionResult,
} from '../main/ets/model/AccountSelection';

const url: string = 'https://www.sciencenet.cn/xml/blog.aspx?di=20';

export default function accountSelectionTest(): void {
  describe('Selection carries across accounts by stable identity', () => {
    it('same feed URL maps to the new account id', 0, () => {
      const oldFeeds: SelectionFeed[] = [{ id: '1|greader-feed', url: url, title: '科学网博客' }];
      const newFeeds: SelectionFeed[] = [{ id: '2|42', url: url, title: '科学网博客' }];
      const result: SelectionResult = remapSelectionToAccount(
        '1|greader-feed', '', oldFeeds, [], newFeeds, []
      );
      expect(result.feedId).assertEqual('2|42');
      expect(result.groupId).assertEqual('');
    });

    it('missing feed falls back to 全部 (no ids)', 0, () => {
      const result: SelectionResult = remapSelectionToAccount(
        '1|old', '', [{ id: '1|old', url: 'https://old', title: 'A' }], [],
        [{ id: '2|x', url: 'https://other', title: 'B' }], []
      );
      expect(result.feedId).assertEqual('');
      expect(result.groupId).assertEqual('');
    });

    it('group maps by name', 0, () => {
      const oldGroups: SelectionGroup[] = [{ id: '1|g5', name: '科技' }];
      const newGroups: SelectionGroup[] = [{ id: '2|g9', name: '科技' }];
      const result: SelectionResult = remapSelectionToAccount(
        '', '1|g5', [], oldGroups, [], newGroups
      );
      expect(result.groupId).assertEqual('2|g9');
      expect(result.feedId).assertEqual('');
    });

    it('full-width slash and spaces in FreshRSS/GReader values match', 0, () => {
      const result: SelectionResult = remapSelectionToAccount(
        '1|greader', '',
        [{ id: '1|greader', url: 'https：／／a.example／rss?di=20', title: '科学网　博客' }], [],
        [{ id: '2|42', url: 'https://a.example/rss?di=20', title: '科学网博客' }], []
      );
      expect(result.feedId).assertEqual('2|42');
    });

    it('group name with full-width characters matches', 0, () => {
      const result: SelectionResult = remapSelectionToAccount(
        '', '1|g5', [], [{ id: '1|g5', name: '科　技' }], [],
        [{ id: '2|g9', name: '科技' }]
      );
      expect(result.groupId).assertEqual('2|g9');
    });

    it('different protocol URLs still match by normalized title', 0, () => {
      const result: SelectionResult = remapSelectionToAccount(
        '1|greader', '',
        [{ id: '1|greader', url: 'feed/https://a.example/rss?di=20', title: ' 科学网博客 ' }], [],
        [{ id: '2|42', url: 'https://b.example/rss?di=20', title: '科学网博客' }], []
      );
      expect(result.feedId).assertEqual('2|42');
    });

    it('different hosts with same path/query match by URL suffix', 0, () => {
      const result: SelectionResult = remapSelectionToAccount(
        '1|greader', '',
        [{ id: '1|greader', url: 'https://a.example/rss?di=20', title: 'X' }], [],
        [{ id: '2|42', url: 'https://b.example/rss?di=20', title: 'Y' }], []
      );
      expect(result.feedId).assertEqual('2|42');
    });

    it('missing group falls back to 全部', 0, () => {
      const result: SelectionResult = remapSelectionToAccount(
        '', '1|g5', [], [{ id: '1|g5', name: '科技' }], [],
        [{ id: '2|g9', name: '其他' }]
      );
      expect(result.feedId).assertEqual('');
      expect(result.groupId).assertEqual('');
    });

    it('global selection stays global', 0, () => {
      const result: SelectionResult = remapSelectionToAccount('', '', [], [], [], []);
      expect(result.feedId).assertEqual('');
      expect(result.groupId).assertEqual('');
    });
  });
}
