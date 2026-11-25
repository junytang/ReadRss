import { notificationManager } from '@kit.NotificationKit';
import { Logger } from './Logger';
import { FeedNotify } from '../rss/SyncService';

/** HarmonyOS caps how many notifications an app may publish in a short window.
 *  Android sends one per feed; spacing the publishes keeps that behaviour while
 *  staying under the system rate limit. */
const PUBLISH_INTERVAL_MS: number = 500;

/** Sends a basic-text notification for new unread articles (Android NotificationHelper equivalent). */
export class NotificationHelper {
  private static nextId: number = 1000;

  static async notify(feedTitle: string, articleTitle: string, count: number): Promise<void> {
    try {
      const content: notificationManager.NotificationBasicContent = {
        title: feedTitle,
        text: count > 1 ? `${articleTitle} 等 ${count} 篇新文章` : articleTitle,
      };
      const request: notificationManager.NotificationRequest = {
        id: NotificationHelper.nextId++,
        content: {
          // contentType is deprecated since API 11; notificationContentType is
          // the supported replacement and uses notificationManager.ContentType.
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: content,
        },
      };
      await notificationManager.publish(request);
    } catch (error) {
      Logger.warn(`Publish notification failed: ${(error as Error).message}`);
    }
  }

  /** Publish one notification per feed for a whole sync.
   *  Android notifies once per feed after all articles are inserted; doing it
   *  inside each batch re-notified the same feed every batch and re-read the
   *  feed table on every iteration. Fire-and-forget so publishing never delays
   *  the sync's UI completion signal. */
  static async notifyAll(entries: Map<string, FeedNotify>): Promise<void> {
    if (entries.size === 0) {
      return;
    }
    // Android's NotificationHelper checks areNotificationsEnabled() first.
    // Skip entirely when the user has disabled notifications: otherwise every
    // publish throws "Notification disabled" and also burns the system's
    // per-app publish quota, causing the later "frequency upper limit" errors.
    let enabled: boolean = false;
    try {
      enabled = await notificationManager.isNotificationEnabled();
    } catch (error) {
      // If the state cannot be read, stay silent rather than spamming failures.
      return;
    }
    if (!enabled) {
      return;
    }
    // Space publishes out so a sync across many feeds does not exceed the
    // notification frequency limit. Still one notification per feed, as Android.
    let delay: number = 0;
    entries.forEach((entry: FeedNotify): void => {
      const currentDelay: number = delay;
      delay += PUBLISH_INTERVAL_MS;
      setTimeout((): void => {
        NotificationHelper.notify(entry.feedTitle, entry.firstTitle, entry.count);
      }, currentDelay);
    });
  }
}
