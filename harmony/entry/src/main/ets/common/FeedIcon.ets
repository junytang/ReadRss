import { feedIconCache } from './FeedIconCache';
import { common } from '@kit.AbilityKit';
import { Feed } from '../model/Models';

/** Normalizes a feed icon and prefers the on-disk cached copy. */
export class FeedIcon {
  static src(iconUrl: string): string {
    if (iconUrl.length === 0) {
      return '';
    }
    if (iconUrl.startsWith('http://') || iconUrl.startsWith('https://')) {
      const cached: string = feedIconCache.cachedPath(iconUrl);
      return cached.length > 0 ? `file://${cached}` : iconUrl;
    }
    if (iconUrl.startsWith('data:')) {
      return iconUrl;
    }
    // Fever returns a data-URI body WITHOUT the "data:" prefix, e.g.
    // "image/png;base64,R0lGODlh..." (Android matches ^image/.*;base64,.*).
    // Keep its real MIME type instead of forcing PNG on every icon.
    const mimeMatch: Array<string> | null = iconUrl.match(/^image\/[^;,]+;base64,/i);
    if (mimeMatch !== null) {
      return `data:${iconUrl}`;
    }
    // Fallback for a raw base64 payload without a MIME header.
    return `data:image/png;base64,${iconUrl}`;
  }

  /** Kick off background downloads for all remote icons in the given feeds. */
  static prefetch(context: common.Context | undefined, feeds: Feed[]): void {
    if (!context) {
      return;
    }
    for (const feed of feeds) {
      if (feed.iconUrl.startsWith('http')) {
        feedIconCache.ensure(context, feed.iconUrl).catch(() => {});
      }
    }
  }
}
