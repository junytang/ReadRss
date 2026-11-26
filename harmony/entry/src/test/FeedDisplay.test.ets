import { describe, it, expect } from '@ohos/hypium';
import { normalizeFeedText } from '../main/ets/model/FeedDisplay';

export default function feedDisplayTest(): void {
  describe('Feed name / URL display normalization', () => {
    it('full-width slashes and colon in a FreshRSS feed-url name become half-width', 0, () => {
      expect(normalizeFeedText('https：／／www.sciencenet.cn／xml／blog.aspx?di=20'))
        .assertEqual('https://www.sciencenet.cn/xml/blog.aspx?di=20');
    });

    it('an ordinary Chinese title keeps its full-width punctuation', 0, () => {
      expect(normalizeFeedText('科学网，博客')).assertEqual('科学网，博客');
    });

    it('a normal URL is unchanged', 0, () => {
      expect(normalizeFeedText('https://sspai.com/feed')).assertEqual('https://sspai.com/feed');
    });

    it('empty value stays empty', 0, () => {
      expect(normalizeFeedText('')).assertEqual('');
    });
  });
}
