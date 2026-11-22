import { notificationManager } from '@kit.NotificationKit';
// The contentType field of NotificationRequest uses @ohos.notification.ContentType,
// which is a different enum from notificationManager.ContentType in API 26.
import notification from '@ohos.notification';
import { Logger } from './Logger';
import { FeedNotify } from '../rss/SyncService';

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
          contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: content,
        },
      };
      await notificationManager.publish(request);
    } catch (error) {
      Logger.error(`Publish notification failed: ${(error as Error).message}`);
    }
  }

  /** Publish one notification per feed for a whole sync.
   *  Android notifies once per feed after all articles are inserted; doing it
   *  inside each batch re-notified the same feed every batch and re-read the
   *  feed table on every iteration. Fire-and-forget so publishing never delays
   *  the sync's UI completion signal. */
  static notifyAll(entries: Map<string, FeedNotify>): void {
    entries.forEach((entry: FeedNotify) => {
      NotificationHelper.notify(entry.feedTitle, entry.firstTitle, entry.count);
    });
  }
}
