import { http } from '@kit.NetworkKit';
import { Logger } from '../common/Logger';
import { gReaderTokenStore } from './GReaderTokenStore';

export interface GReaderCategory { id: string; label: string }
export interface GReaderSubscription {
  id: string;
  title: string;
  categories?: GReaderCategory[];
  url?: string;
  htmlUrl?: string;
  iconUrl?: string;
}
interface SubscriptionListDto { subscriptions?: GReaderSubscription[] }
interface ItemRef { id: string }
export interface ItemIdsDto { itemRefs?: ItemRef[]; continuation?: string }
export interface GReaderSummary { content?: string }
export interface GReaderOrigin { streamId?: string; htmlUrl?: string; title?: string }
export interface GReaderLink { href?: string }
export interface GReaderItem {
  id: string;
  /** Stream ids including read/starred tags, when the server provides them. */
  categories?: string[];
  published?: number;
  updated?: number;
  crawlTimeMsec?: string;
  title?: string;
  summary?: GReaderSummary;
  author?: string;
  origin?: GReaderOrigin;
  canonical?: GReaderLink[];
  alternate?: GReaderLink[];
}
interface ItemsContentsDto { items?: GReaderItem[]; updated?: number }
export interface ItemsContentsResult { items: GReaderItem[]; updated: number | undefined }
export interface GReaderUser { userId?: string; userName?: string; userEmail?: string }
export interface QuickAddDto { streamId?: string; streamName?: string; numResults?: number }

/** Explicit parameter bag. ArkTS forbids untyped object literals / Record literals. */
export interface ApiParams {
  output?: string;
  Email?: string;
  Passwd?: string;
  client?: string;
  accountType?: string;
  service?: string;
  Auth?: string;
  auth?: string;
  s?: string;
  xt?: string;
  it?: string;
  ot?: string;
  n?: string;
  c?: string;
  quickadd?: string;
  ac?: string;
  a?: string;
  r?: string;
  t?: string;
  dest?: string;
}

interface RequestHeaders {
  'User-Agent': string;
  'Authorization'?: string;
  'Content-Type'?: string;
}

const NO_PARAMS: ApiParams = {};
const USER_AGENT: string = 'ReadYou-Harmony/0.1 (GReader)';
const FORM_CONTENT_TYPE: string = 'application/x-www-form-urlencoded';

function isUnauthorized(error: Error): boolean {
  const message: string = error.message ?? '';
  // rawRequest emits the exact 'Unauthorized' sentinel on HTTP 401; matching
  // any text containing "401" would clear tokens on arbitrary server errors.
  return message === 'Unauthorized' || message.startsWith('HTTP 401');
}

/** Two attempts with 1s/2s backoff. Only a 401 invalidates the cached token;
 *  429/5xx/timeouts keep it, otherwise a throttled server triggers a wave of
 *  ClientLogin requests from the parallel sync workers. */
async function withRetry<T>(
  action: () => Promise<T>, onUnauthorized: () => Promise<void>
): Promise<T> {
  let delay: number = 1000;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await action();
    } catch (error) {
      if (attempt === 1) {
        throw error as Error;
      }
      if (isUnauthorized(error as Error)) {
        await onUnauthorized();
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, delay));
      delay = Math.min(delay * 2, 5000);
    }
  }
  throw new Error('unreachable');
}

/** HTTP client for the Google Reader API (also used by FreshRSS). Mirrors GoogleReaderAPI.kt.
 *  Login tokens are persisted via gReaderTokenStore and loaded lazily on first use. */
export class GoogleReaderApi {
  private serverUrl: string;
  private username: string;
  private password: string;
  private loginToken: string = '';
  private actionToken: string = '';
  private tokensLoaded: boolean = false;

  constructor(serverUrl: string, username: string, password: string) {
    this.serverUrl = serverUrl;
    this.username = username;
    this.password = password;
  }

  /** Load persisted tokens once, on first auth check. */
  private async loadTokens(): Promise<void> {
    if (this.tokensLoaded) {
      return;
    }
    const cached = await gReaderTokenStore.load(this.serverUrl, this.username);
    // Set only after the await: setting it first lets concurrent callers see
    // true while the first load is still in flight and skip it entirely.
    this.tokensLoaded = true;
    if (cached) {
      this.loginToken = cached.loginToken;
      this.actionToken = cached.actionToken;
    }
  }

  // ------------------------------- auth -----------------------------------

  private reauthInFlight?: Promise<void>;

  /** All parallel workers share one ClientLogin while a token is being renewed. */
  private async reAuthenticate(): Promise<void> {
    if (this.reauthInFlight !== undefined) {
      return this.reauthInFlight;
    }
    this.reauthInFlight = this.doReAuthenticate();
    try {
      await this.reauthInFlight;
    } finally {
      this.reauthInFlight = undefined;
    }
  }

  private async doReAuthenticate(): Promise<void> {
    const url: string = `${this.serverUrl}accounts/ClientLogin`;
    const form: ApiParams = {
      output: 'json',
      Email: this.username,
      Passwd: this.password,
      client: 'ReadYou',
      accountType: 'HOSTED_OR_GOOGLE',
      service: 'reader',
    };
    let text: string = '';
    try {
      text = await this.rawRequest(
        url, http.RequestMethod.POST, this.formBody(form, false), FORM_CONTENT_TYPE
      );
    } catch (error) {
      Logger.error(`ClientLogin failed for ${this.serverUrl}: ${(error as Error).message}`);
      throw error as Error;
    }
    let token: string = '';
    try {
      const json: ApiParams = JSON.parse(text) as ApiParams;
      token = json.Auth ?? json.auth ?? '';
    } catch (error) {
      for (const line of text.split('\n')) {
        if (line.startsWith('Auth=')) {
          token = line.substring(5).trim();
          break;
        }
      }
    }
    if (token.length === 0) {
      throw new Error('Unable to obtain ClientLogin token');
    }
    this.loginToken = token;
    // The action token is optional. Android deliberately ignores failures from
    // this endpoint (GoogleReaderAPI.kt:144-150) and still sends T= empty;
    // FreshRSS greader.php can reject it. Treating it as fatal made otherwise
    // valid credentials fail on refresh with "Invalid credentials".
    let actionToken: string = '';
    try {
      const tokenText: string = await this.rawRequest(
        `${this.serverUrl}reader/api/0/token`, http.RequestMethod.GET, '', '',
        `GoogleLogin auth=${this.loginToken}`
      );
      actionToken = tokenText.trim();
    } catch (error) {
      Logger.warn(`Action token unavailable, continuing with empty T: ${(error as Error).message}`);
      // rawRequest clears auth on 401; the ClientLogin token itself is still
      // valid, so restore it for the real API requests.
      this.loginToken = token;
    }
    this.actionToken = actionToken;
    await gReaderTokenStore.save(this.serverUrl, this.username, this.loginToken, this.actionToken);
  }

  private async ensureAuth(): Promise<void> {
    await this.loadTokens();
    if (this.loginToken.length === 0) {
      await this.reAuthenticate();
    }
  }

  private async clearAuth(): Promise<void> {
    this.loginToken = '';
    this.actionToken = '';
    await gReaderTokenStore.clear(this.serverUrl, this.username);
  }

  /** True when a persisted login token has been loaded. */
  hasAuth(): boolean {
    return this.loginToken.length > 0;
  }

  /** Like Android's GoogleReaderAPI.validCredentials(): always perform a real
   *  ClientLogin. Trusting a cached token here made adding an account appear to
   *  succeed with a stale/wrong token, but the first real request (refresh)
   *  then failed with "Invalid credentials". */
  async validCredentials(): Promise<boolean> {
    try {
      await this.reAuthenticate();
      return true;
    } catch (error) {
      Logger.error(`validCredentials failed for ${this.serverUrl}: ${(error as Error).message}`);
      return false;
    }
  }

  /** Sync uses the cached token when present and re-authenticates on 401 via
   *  withRetry, matching Android's refreshCredentialsIfNeeded(). */
  async ensureAuthIfNeeded(): Promise<void> {
    await this.ensureAuth();
  }

  // ---------------------------- HTTP plumbing -----------------------------

  private async rawRequest(
    url: string,
    method: http.RequestMethod,
    body: string,
    contentType: string,
    authorization?: string
  ): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    // ArkTS forbids indexed access on fields, so build the header object explicitly.
    let header: RequestHeaders = { 'User-Agent': USER_AGENT };
    if (authorization && contentType.length > 0) {
      header = { 'User-Agent': USER_AGENT, 'Authorization': authorization, 'Content-Type': contentType };
    } else if (authorization) {
      header = { 'User-Agent': USER_AGENT, 'Authorization': authorization };
    } else if (contentType.length > 0) {
      header = { 'User-Agent': USER_AGENT, 'Content-Type': contentType };
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 10000,
    };
    if (body.length > 0) {
      options.body = body;
    }
    try {
      const response: http.HttpResponse = await request.request(url, options);
      if (response.responseCode === 401) {
        await this.clearAuth();
        throw new Error('Unauthorized');
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}: ${response.result as string}`);
      }
      return response.result as string;
    } catch (error) {
      // request() is @throws; rethrow so callers can distinguish HTTP/auth
      // failures from transport errors.
      throw error as Error;
    } finally {
      request.destroy();
    }
  }

  private addParam(parts: string[], key: string, value: string | undefined): void {
    if (value !== undefined && value.length > 0) {
      parts.push(`${key}=${encodeURIComponent(value)}`);
    }
  }

  private queryString(params: ApiParams): string {
    const parts: string[] = ['output=json'];
    this.addParam(parts, 's', params.s);
    this.addParam(parts, 'xt', params.xt);
    this.addParam(parts, 'it', params.it);
    this.addParam(parts, 'ot', params.ot);
    this.addParam(parts, 'n', params.n);
    this.addParam(parts, 'c', params.c);
    this.addParam(parts, 'quickadd', params.quickadd);
    return parts.join('&');
  }

  private formBody(params: ApiParams, withToken: boolean): string {
    const parts: string[] = [];
    this.addParam(parts, 'output', params.output);
    this.addParam(parts, 'Email', params.Email);
    this.addParam(parts, 'Passwd', params.Passwd);
    this.addParam(parts, 'client', params.client);
    this.addParam(parts, 'accountType', params.accountType);
    this.addParam(parts, 'service', params.service);
    this.addParam(parts, 'ac', params.ac);
    this.addParam(parts, 's', params.s);
    this.addParam(parts, 'a', params.a);
    this.addParam(parts, 'r', params.r);
    this.addParam(parts, 't', params.t);
    this.addParam(parts, 'dest', params.dest);
    if (withToken) {
      parts.push(`T=${encodeURIComponent(this.actionToken)}`);
    }
    return parts.join('&');
  }

  private async get<T>(endpoint: string, params: ApiParams): Promise<T> {
    return withRetry<T>(async (): Promise<T> => {
      await this.ensureAuth();
      const url: string = `${this.serverUrl}${endpoint}?${this.queryString(params)}`;
      const text: string = await this.rawRequest(
        url, http.RequestMethod.GET, '', '', `GoogleLogin auth=${this.loginToken}`
      );
      return JSON.parse(text) as T;
    }, async () => this.clearAuth());
  }

  private async post(endpoint: string, form: ApiParams): Promise<string> {
    return withRetry<string>(async (): Promise<string> => {
      await this.ensureAuth();
      const url: string = `${this.serverUrl}${endpoint}?output=json`;
      return this.rawRequest(
        url, http.RequestMethod.POST, this.formBody(form, true), FORM_CONTENT_TYPE,
        `GoogleLogin auth=${this.loginToken}`
      );
    }, async () => this.clearAuth());
  }

  // ------------------------------ endpoints -------------------------------

  getUserInfo(): Promise<GReaderUser> {
    return this.get<GReaderUser>('reader/api/0/user-info', NO_PARAMS);
  }

  async getSubscriptionList(): Promise<GReaderSubscription[]> {
    const body: SubscriptionListDto = await this.get<SubscriptionListDto>(
      'reader/api/0/subscription/list', NO_PARAMS
    );
    return body.subscriptions ?? [];
  }

  getItemIds(params: ApiParams): Promise<ItemIdsDto> {
    return this.get<ItemIdsDto>('reader/api/0/stream/items/ids', params);
  }

  async getItemsContents(ids: string[]): Promise<ItemsContentsResult> {
    return withRetry<ItemsContentsResult>(async (): Promise<ItemsContentsResult> => {
      await this.ensureAuth();
      const bodyParts: string[] = ids.map((id: string) => `i=${encodeURIComponent(id)}`);
      bodyParts.push(`T=${encodeURIComponent(this.actionToken)}`);
      const url: string = `${this.serverUrl}reader/api/0/stream/items/contents?output=json`;
      const text: string = await this.rawRequest(
        url, http.RequestMethod.POST, bodyParts.join('&'), FORM_CONTENT_TYPE,
        `GoogleLogin auth=${this.loginToken}`
      );
      let dto: ItemsContentsDto;
      try {
        dto = JSON.parse(text) as ItemsContentsDto;
      } catch (error) {
        Logger.error(`GReader contents JSON parse failed, response: ${text.substring(0, 300)}`);
        throw error as Error;
      }
      return { items: dto.items ?? [], updated: dto.updated };
    }, async () => this.clearAuth());
  }

  /** Android sends quickadd in BOTH the query string and the POST form. */
  async quickAdd(url: string): Promise<QuickAddDto> {
    return withRetry<QuickAddDto>(async (): Promise<QuickAddDto> => {
      await this.ensureAuth();
      const endpoint: string = 'reader/api/0/subscription/quickadd';
      const query: string = `quickadd=${url}&output=json`;
      const parts: string[] = [`quickadd=${encodeURIComponent(url)}`, `T=${encodeURIComponent(this.actionToken)}`];
      const text: string = await this.rawRequest(
        `${this.serverUrl}${endpoint}?${query}`, http.RequestMethod.POST,
        parts.join('&'), FORM_CONTENT_TYPE, `GoogleLogin auth=${this.loginToken}`
      );
      return JSON.parse(text) as QuickAddDto;
    }, async () => this.clearAuth());
  }

  subscriptionEdit(
    action: string,
    feedStreamId: string,
    categoryStreamId: string,
    originStreamId: string,
    title: string
  ): Promise<string> {
    const form: ApiParams = { ac: action, s: feedStreamId };
    if (categoryStreamId.length > 0) {
      form.a = categoryStreamId;
    }
    if (originStreamId.length > 0) {
      form.r = originStreamId;
    }
    if (title.length > 0) {
      form.t = title;
    }
    return this.post('reader/api/0/subscription/edit', form);
  }

  editTag(ids: string[], mark?: string, unmark?: string): Promise<string> {
    const parts: string[] = ids.map((id: string) => `i=${encodeURIComponent(id)}`);
    if (mark) {
      parts.push(`a=${encodeURIComponent(mark)}`);
    }
    if (unmark) {
      parts.push(`r=${encodeURIComponent(unmark)}`);
    }
    return this.postForm('reader/api/0/edit-tag', parts);
  }

  private async postForm(endpoint: string, parts: string[]): Promise<string> {
    await this.ensureAuth();
    parts.push(`T=${encodeURIComponent(this.actionToken)}`);
    return this.rawRequest(
      `${this.serverUrl}${endpoint}?output=json`, http.RequestMethod.POST,
      parts.join('&'), FORM_CONTENT_TYPE, `GoogleLogin auth=${this.loginToken}`
    );
  }

  markAllAsRead(streamId: string, since?: number): Promise<string> {
    const parts: string[] = [`s=${encodeURIComponent(streamId)}`];
    if (since !== undefined) {
      parts.push(`ts=${since}`);
    }
    return this.postForm('reader/api/0/mark-all-as-read', parts);
  }

  renameTag(oldStreamId: string, newStreamId: string): Promise<string> {
    const form: ApiParams = { s: oldStreamId, dest: newStreamId };
    return this.post('reader/api/0/rename-tag', form);
  }

  disableTag(streamId: string): Promise<string> {
    const form: ApiParams = { s: streamId };
    return this.post('reader/api/0/disable-tag', form);
  }
}
