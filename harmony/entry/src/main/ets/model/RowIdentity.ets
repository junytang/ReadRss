import { Article } from './Models';

/**
 * ForEach key for an article row. This ArkUI build does NOT refresh a reused
 * node's @Prop when only its key is unchanged, so read/star MUST stay in the
 * key for the gray/star visuals to update immediately. An id-only key looked
 * "more stable" but made every optimistic mark appear to do nothing — a
 * regression that pure tests can now lock down.
 */
export function articleRowKey(article: Article): string {
  return `${article.id}-${article.isRead}-${article.isStarred}`;
}
