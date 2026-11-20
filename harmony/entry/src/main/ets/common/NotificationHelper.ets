import { notificationManager } from '@kit.NotificationKit';
// The contentType field of NotificationRequest uses @ohos.notification.ContentType,
// which is a different enum from notificationManager.ContentType in API 26.
import notification from '@ohos.notification';
import { Logger } from './Logger';

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
}
