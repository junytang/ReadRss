import { http } from '@kit.NetworkKit';
import { buffer } from '@kit.ArkTS';
import { Logger } from '../common/Logger';

/** Typed headers: ArkTS forbids untyped object literals. */
interface MinifluxHeaders {
  'User-Agent': string;
  'Content-Type'?: string;
  'X-Auth-Token'?: string;
  'Authorization'?: string;
}

export interface MinifluxCategory {
  id: number;
  title?: string;
}
export interface MinifluxFeedIcon {
  feed_id?: number;
  icon_id?: number;
}
export interface MinifluxFeed {
  id: number;
  title?: string;
  feed_url?: string;
  site_url?: string;
  category?: MinifluxCategory;
  icon?: MinifluxFeedIcon;
}
export interface MinifluxEntry {
  id: number;
  feed_id?: number;
  title?: string;
  author?: string;
  content?: string;
  url?: string;
  published_at?: string;
  status?: string;
  starred?: boolean;
}
export interface MinifluxEntries {
  total?: number;
  entries?: MinifluxEntry[];
}
export interface MinifluxEntryIds {
  total?: number;
  entry_ids?: number[];
}
export interface MinifluxIcon {
  id?: number;
  data?: string;
  mime_type?: string;
}
export interface MinifluxContent {
  content?: string;
}
interface MinifluxErrorBody {
  error_message?: string;
}
export interface MinifluxCreatedFeed {
  feed_id?: number;
}
export interface MinifluxCreatedCategory {
  id?: number;
}
export interface MinifluxUser {
  id?: number;
  username?: string;
}
export interface MinifluxEntryParams {
  status?: string;
  starred?: boolean;
  offset?: number;
  limit?: number;
  order?: string;
  direction?: string;
  after?: number;
  afterEntryId?: number;
  beforeEntryId?: number;
}

const USER_AGENT: string = 'ReadYou-Harmony/0.1 (Miniflux)';
const JSON_TYPE: string = 'application/json';
const NOT_FOUND: string = 'Not found (404)';
/** The `starred` field in PUT /v1/entries needs Miniflux >= 2.3.2; older
 *  servers answer with HTTP 400. Only that error may use the bookmark fallback. */
/** Hypium's afterThrow() may throw a plain string; normalise to text. */
export function errorText(error: Object | string): string {
  if (typeof error === 'string') {
    return error;
  }
  const message: string | undefined = (error as Error).message;
  return message ?? '';
}

export function isUnsupportedStarFieldError(message: string | undefined): boolean {
  const text: string = message ?? '';
  return text.indexOf('400') >= 0 && text.indexOf('starred') >= 0;
}

/** Miniflux returns `image/png;base64,...` (data-URI body without prefix).
 *  Keep its real MIME type so ArkWeb does not mislabel JPEG/ICO icons. */
export function iconDataUrl(data: string, mimeType?: string): string {
  if (data.startsWith('data:')) {
    return data;
  }
  // A data-URI body like "image/jpeg;base64,..." already carries its MIME.
  if (data.indexOf(';base64,') >= 0) {
    return `data:${data}`;
  }
  const mime: string = mimeType !== undefined && mimeType.length > 0 ? mimeType : 'image/png';
  return `data:${mime};base64,${data}`;
}

/** Minimal client for the official Miniflux REST API (https://miniflux.app/docs/api.html).
 *  Authentication: an API token in X-Auth-Token when no password is supplied,
 *  otherwise HTTP Basic with username/password. */
export class MinifluxApi {
  private baseUrl: string;
  private headers: MinifluxHeaders;
  private token: string;
  private basic: string;
  private lastErrorMessage: string = '';

  /** Reason of the last failed credential check, for a useful UI message. */
  lastError(): string {
    return this.lastErrorMessage;
  }

  constructor(serverUrl: string, username: string, password: string) {
    let url: string = serverUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    // The editor asks for the server root; tolerate users pasting the documented
    // /v1 API prefix, which would otherwise produce /v1/v1/me and fail auth.
    if (url.endsWith('/v1')) {
      url = url.substring(0, url.length - 3);
    }
    this.baseUrl = url;
    this.lastErrorMessage = '';
    this.token = password.length > 0 ? '' : username;
    this.basic = '';
    if (password.length > 0) {
      this.basic = buffer.from(`${username}:${password}`, 'utf-8').toString('base64');
      this.headers = { 'User-Agent': USER_AGENT, 'Authorization': `Basic ${this.basic}` };
    } else {
      // Official docs: API keys use the X-Auth-Token header.
      this.headers = { 'User-Agent': USER_AGENT, 'X-Auth-Token': username };
    }
  }

  /** One retry after a 1s backoff for transient network failures (timeouts,
   *  DNS hiccups). Mirrors GoogleReaderApi.withRetry; explicit HTTP status
   *  errors are surfaced immediately because retrying them cannot help. */
  private async request<T>(
    method: http.RequestMethod, path: string, body?: string, query?: string
  ): Promise<T> {
    let header: MinifluxHeaders = this.headers;
    if (body !== undefined) {
      if (this.token.length > 0) {
        header = {
          'User-Agent': USER_AGENT, 'Content-Type': JSON_TYPE, 'X-Auth-Token': this.token,
        };
      } else {
        header = {
          'User-Agent': USER_AGENT, 'Content-Type': JSON_TYPE,
          'Authorization': `Basic ${this.basic}`,
        };
      }
    }
    const url: string = `${this.baseUrl}/v1/${path}${query ?? ''}`;
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 20000,
    };
    if (body !== undefined) {
      options.body = body;
    }
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(url, options);
        if (response.responseCode < 200 || response.responseCode >= 300) {
          // Surface the server's `error_message` when present, otherwise a code.
          let detail: string = '';
          try {
            const body = JSON.parse(response.result as string) as MinifluxErrorBody;
            detail = body.error_message ?? '';
          } catch (error) {
            // Plain-text error body; use the status code instead.
          }
          if (response.responseCode === 404) {
            throw new Error(NOT_FOUND + (detail.length > 0 ? `: ${detail}` : ''));
          }
          throw new Error(`Miniflux HTTP ${response.responseCode}` +
            (detail.length > 0 ? `: ${detail}` : ''));
        }
        const text: string = response.result as string;
        if (text === undefined || text.length === 0) {
          return undefined as T;
        }
        return JSON.parse(text) as T;
      } catch (error) {
        const message: string = errorText(error as Error);
        const isStatusError: boolean = message.startsWith('Miniflux HTTP ')
          || message.startsWith(NOT_FOUND);
        if (isStatusError || attempt === 1) {
          throw error as Error;
        }
        // Transient timeout / network failure: retry once after a short pause.
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 1000);
        });
      } finally {
        request.destroy();
      }
    }
    throw new Error('Miniflux request failed');
  }

  private entryQuery(params: MinifluxEntryParams): string {
    const parts: string[] = [];
    if (params.status !== undefined && params.status.length > 0) {
      parts.push(`status=${encodeURIComponent(params.status)}`);
    }
    if (params.starred !== undefined) {
      parts.push(`starred=${params.starred ? 'true' : 'false'}`);
    }
    if (params.offset !== undefined) {
      parts.push(`offset=${params.offset}`);
    }
    if (params.limit !== undefined) {
      parts.push(`limit=${params.limit}`);
    }
    if (params.order !== undefined && params.order.length > 0) {
      parts.push(`order=${encodeURIComponent(params.order)}`);
    }
    if (params.direction !== undefined && params.direction.length > 0) {
      parts.push(`direction=${encodeURIComponent(params.direction)}`);
    }
    if (params.after !== undefined) {
      parts.push(`after=${params.after}`);
    }
    if (params.afterEntryId !== undefined) {
      parts.push(`after_entry_id=${params.afterEntryId}`);
    }
    if (params.beforeEntryId !== undefined) {
      parts.push(`before_entry_id=${params.beforeEntryId}`);
    }
    return parts.length > 0 ? `?${parts.join('&')}` : '';
  }

  async validCredentials(): Promise<boolean> {
    try {
      await this.request<MinifluxUser>(http.RequestMethod.GET, 'me');
      return true;
    } catch (error) {
      this.lastErrorMessage = (error as Error).message;
      Logger.warn(`Miniflux credential check failed: ${this.lastErrorMessage}`);
      return false;
    }
  }

  async getCategories(): Promise<MinifluxCategory[]> {
    // An empty/unexpected response must never leak `undefined` into callers
    // that immediately access `.length` (that was the pull-to-refresh crash).
    const result = await this.request<MinifluxCategory[] | undefined>(
      http.RequestMethod.GET, 'categories'
    );
    return result ?? [];
  }

  async getFeeds(): Promise<MinifluxFeed[]> {
    const result = await this.request<MinifluxFeed[] | undefined>(http.RequestMethod.GET, 'feeds');
    return result ?? [];
  }

  /** Feed-id endpoint exists in all Miniflux versions (unlike /icons/{id},
   *  which requires >= 2.0.49). Only 404 means "no icon"; other failures must
   *  propagate so a network/auth problem is not silently shown as no icon. */
  async getIcon(feedId: number): Promise<MinifluxIcon | undefined> {
    try {
      return await this.request<MinifluxIcon>(http.RequestMethod.GET, `feeds/${feedId}/icon`);
    } catch (error) {
      if ((error as Error).message.indexOf('404') >= 0) {
        Logger.info(`Miniflux feed ${feedId} has no icon`);
        return undefined;
      }
      throw error as Error;
    }
  }

  /** Read one entry's current starred state before a version-fallback toggle. */
  getEntry(id: number): Promise<MinifluxEntry> {
    return this.request<MinifluxEntry>(http.RequestMethod.GET, `entries/${id}`);
  }

  async getEntries(params: MinifluxEntryParams): Promise<MinifluxEntries> {
    const result = await this.request<MinifluxEntries | undefined>(
      http.RequestMethod.GET, 'entries', undefined, this.entryQuery(params)
    );
    return result ?? { entries: [] };
  }

  /** ID-only listing (Miniflux >= 2.3.2) — no article bodies transferred. */
  async getEntryIds(params: MinifluxEntryParams): Promise<number[]> {
    const result = await this.request<MinifluxEntryIds | undefined>(
      http.RequestMethod.GET, 'entries/ids', undefined, this.entryQuery(params)
    );
    return result?.entry_ids ?? [];
  }

  async getEntryContent(id: number): Promise<string> {
    const result = await this.request<MinifluxContent | undefined>(
      http.RequestMethod.GET, `entries/${id}/fetch-content?update_content=false`
    );
    return result?.content ?? '';
  }

  /** Update status and/or starred flag for a batch of entries (204 on success). */
  async updateEntries(ids: number[], status?: string, starred?: boolean): Promise<void> {
    const requestBody: string = `{"entry_ids":${JSON.stringify(ids)}` +
      (status !== undefined ? `,"status":"${status}"` : '') +
      (starred !== undefined ? `,"starred":${starred ? 'true' : 'false'}` : '') + '}';
    await this.request<void>(http.RequestMethod.PUT, 'entries', requestBody);
  }

  async toggleBookmark(id: number): Promise<void> {
    await this.request<void>(http.RequestMethod.PUT, `entries/${id}/bookmark`);
  }

  async createFeed(url: string, categoryId?: number): Promise<number> {
    const body: string = `{"feed_url":${JSON.stringify(url)}` +
      (categoryId !== undefined ? `,"category_id":${categoryId}` : '') + '}';
    const created = await this.request<MinifluxCreatedFeed | undefined>(
      http.RequestMethod.POST, 'feeds', body
    );
    if (created?.feed_id === undefined || created.feed_id <= 0) {
      throw new Error('Miniflux did not return a feed id');
    }
    return created.feed_id;
  }

  async deleteFeed(id: number): Promise<void> {
    await this.request<void>(http.RequestMethod.DELETE, `feeds/${id}`);
  }

  async updateFeed(id: number, title?: string, categoryId?: number): Promise<void> {
    const parts: string[] = [];
    if (title !== undefined) {
      parts.push(`"title":${JSON.stringify(title)}`);
    }
    if (categoryId !== undefined) {
      parts.push(`"category_id":${categoryId}`);
    }
    await this.request<void>(
      http.RequestMethod.PUT, `feeds/${id}`, `{${parts.join(',')}}`
    );
  }

  async createCategory(title: string): Promise<number> {
    const created = await this.request<MinifluxCreatedCategory | undefined>(
      http.RequestMethod.POST, 'categories', `{"title":${JSON.stringify(title)}}`
    );
    if (created?.id === undefined || created.id <= 0) {
      throw new Error('Miniflux did not return a category id');
    }
    return created.id;
  }

  async updateCategory(id: number, title: string): Promise<void> {
    await this.request<void>(
      http.RequestMethod.PUT, `categories/${id}`, `{"title":${JSON.stringify(title)}}`
    );
  }

  async deleteCategory(id: number): Promise<void> {
    await this.request<void>(http.RequestMethod.DELETE, `categories/${id}`);
  }
}
