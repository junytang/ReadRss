import { http } from '@kit.NetworkKit';
import { CredentialCodec } from '../account/AccountModels';
import { XmlParser } from './XmlParser';

export enum FeverStatus {
  READ = 'read',
  UNREAD = 'unread',
  SAVED = 'saved',
  UNSAVED = 'unsaved',
}

interface FeverCommon {
  api_version?: number;
  auth?: number;
  last_refreshed_on_time?: number;
}

export interface FeverFeed {
  id: number;
  favicon_id?: number | string;
  title?: string;
  url?: string;
  site_url?: string;
}
interface FeedsBody extends FeverCommon {
  feeds?: FeverFeed[];
  feeds_groups?: FeverGroupMapping[];
}
export interface FeverGroup {
  id: number;
  title?: string;
}
interface GroupsBody extends FeverCommon {
  groups?: FeverGroup[];
  feeds_groups?: FeverGroupMapping[];
}
export interface FeverGroupMapping {
  group_id: number;
  feed_ids: string;
}
export interface FeverFavicon { id: number | string; data?: string }
interface FaviconsBody extends FeverCommon {
  favicons?: FeverFavicon[];
}
export interface FeverItem {
  id: string;
  feed_id?: number;
  title?: string;
  author?: string;
  html?: string;
  url?: string;
  is_saved?: number;
  is_read?: number;
  created_on_time?: number;
}
interface ItemsBody extends FeverCommon {
  total_items?: number;
  items?: FeverItem[];
}
interface UnreadBody extends FeverCommon { unread_item_ids?: string; }
interface SavedBody extends FeverCommon { saved_item_ids?: string; }

/** HTTP client for the Fever API, mirroring FeverAPI.kt. */
export class FeverApi {
  private serverUrl: string;
  private apiKey: string;

  constructor(serverUrl: string, username: string, password: string) {
    // Android uses the supplied URL verbatim: "$serverUrl?api=&...".
    this.serverUrl = serverUrl;
    this.apiKey = CredentialCodec.md5Hex(`${username}:${password}`);
  }

  private async post(query: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    const url: string = query.length > 0
      ? `${this.serverUrl}?api=&${query}`
      : `${this.serverUrl}?api=&`;
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': 'ReadYou-Harmony/0.1 (Fever)',
        },
        body: `api_key=${this.apiKey}`,
        connectTimeout: 20000,
        readTimeout: 20000,
      });
      if (response.responseCode === 401) {
        throw new Error('Unauthorized');
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Forbidden (${response.responseCode})`);
      }
      const text: string = response.result as string;
      const common: FeverCommon = JSON.parse(text) as FeverCommon;
      if (!common.auth || common.auth <= 0) {
        throw new Error('Unauthorized');
      }
      return text;
    } catch (error) {
      // request() is @throws; surface a typed error to the caller (the finally
      // block still destroys the request).
      throw error as Error;
    } finally {
      request.destroy();
    }
  }

  async validCredentials(): Promise<boolean> {
    await this.post('');
    return true;
  }

  async getGroups(): Promise<GroupsBody> {
    return JSON.parse(await this.post('groups')) as GroupsBody;
  }

  async getFeeds(): Promise<FeedsBody> {
    return JSON.parse(await this.post('feeds')) as FeedsBody;
  }

  async getFavicons(): Promise<FaviconsBody> {
    return JSON.parse(await this.post('favicons')) as FaviconsBody;
  }

  async getItemsSince(sinceId: string): Promise<ItemsBody> {
    return JSON.parse(await this.post(`items&since_id=${sinceId}`)) as ItemsBody;
  }

  async getItemsWith(ids: string[]): Promise<ItemsBody> {
    if (ids.length > 50) {
      throw new Error('Too many ids');
    }
    return JSON.parse(await this.post(`items&with_ids=${ids.join(',')}`)) as ItemsBody;
  }

  async getUnreadIds(): Promise<string[] | undefined> {
    const body: UnreadBody = JSON.parse(await this.post('unread_item_ids')) as UnreadBody;
    if (body.unread_item_ids === undefined || body.unread_item_ids === null) {
      return undefined;
    }
    return this.csv(body.unread_item_ids);
  }

  async getSavedIds(): Promise<string[]> {
    const body: SavedBody = JSON.parse(await this.post('saved_item_ids')) as SavedBody;
    return this.csv(body.saved_item_ids);
  }

  private csv(value: string | undefined): string[] {
    if (!value || value.length === 0) {
      return [];
    }
    return value.split(',').filter((part: string) => part.length > 0);
  }

  /** Mark calls are retried once, matching FeverAPI.withRetries. */
  async markItem(status: FeverStatus, id: string): Promise<void> {
    await this.markWithRetry(`mark=item&as=${status}&id=${id}`);
  }

  async markFeed(status: FeverStatus, id: string, beforeSeconds: number): Promise<void> {
    await this.markWithRetry(`mark=feed&as=${status}&id=${id}&before=${beforeSeconds}`);
  }

  async markGroup(status: FeverStatus, id: string, beforeSeconds: number): Promise<void> {
    await this.markWithRetry(`mark=group&as=${status}&id=${id}&before=${beforeSeconds}`);
  }

  private async markWithRetry(query: string): Promise<void> {
    let delay: number = 1000;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await this.post(query);
        return;
      } catch (error) {
        if (attempt === 1) {
          throw error as Error;
        }
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, delay));
        delay = Math.min(delay * 2, 5000);
      }
    }
  }

  /** Equivalent of Android's String.decodeHTML (Html.fromHtml(...).toString()). */
  static decodeHtml(text: string | undefined): string {
    if (!text) {
      return '';
    }
    const stripped: string = text.replace(/<[^>]*>/g, '');
    return XmlParser.decode(stripped);
  }
}
