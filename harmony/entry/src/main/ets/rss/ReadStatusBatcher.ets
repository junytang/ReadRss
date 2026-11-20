import { rssRepository } from './RssRepository';
import { Logger } from '../common/Logger';

/** Debounces and merges read-status pushes to the server (Android DiffMapHolder equivalent). */
class ReadStatusBatcher {
  private static readonly DELAY_MS: number = 10000;
  private pending: Set<string> = new Set<string>();
  private timer: number = -1;

  add(articleId: string): void {
    this.pending.add(articleId);
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flush();
    }, ReadStatusBatcher.DELAY_MS);
  }

  async flush(): Promise<void> {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const ids: string[] = [];
    this.pending.forEach((id: string) => { ids.push(id); });
    this.pending.clear();
    if (ids.length === 0) {
      return;
    }
    try {
      // markReadBatch chunks at 500 internally and pushes through the active service.
      await rssRepository.markReadBatch(ids, true);
      Logger.info(`Flushed ${ids.length} read-status changes`);
    } catch (error) {
      Logger.error(`Flush read status failed: ${(error as Error).message}`);
    }
  }
}

export const readStatusBatcher: ReadStatusBatcher = new ReadStatusBatcher();
