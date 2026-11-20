import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * Persists GReader/FreshRSS ClientLogin tokens so a restart does not force a
 * fresh login (which costs a couple of network round-trips). Tokens live for
 * 30 days and are keyed by server+username. A 401 clears them so the client
 * re-authenticates.
 */
export interface CachedAuth {
  loginToken: string;
  actionToken: string;
  expiresAt: number;
}

const PREFS_NAME: string = 'readyou_greader_tokens';
const TOKEN_TTL_MS: number = 30 * 24 * 3600 * 1000;

class GReaderTokenStoreImpl {
  private pref?: preferences.Preferences;

  async init(context: common.Context): Promise<void> {
    if (this.pref) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(context, PREFS_NAME);
    } catch (error) {
      // Token cache is an optimisation only; ignore storage failures.
    }
  }

  private key(serverUrl: string, username: string): string {
    return `${serverUrl}|${username}`.replace(/[^\w-]/g, '_');
  }

  async load(serverUrl: string, username: string): Promise<CachedAuth | undefined> {
    if (!this.pref) {
      return undefined;
    }
    try {
      const raw: string = await this.pref.get(this.key(serverUrl, username), '') as string;
      if (raw.length === 0) {
        return undefined;
      }
      const auth: CachedAuth = JSON.parse(raw) as CachedAuth;
      if (!auth.expiresAt || auth.expiresAt <= Date.now()) {
        await this.clear(serverUrl, username);
        return undefined;
      }
      return auth;
    } catch (error) {
      return undefined;
    }
  }

  async save(serverUrl: string, username: string, loginToken: string, actionToken: string): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      const auth: CachedAuth = {
        loginToken: loginToken,
        actionToken: actionToken,
        expiresAt: Date.now() + TOKEN_TTL_MS,
      };
      await this.pref.put(this.key(serverUrl, username), JSON.stringify(auth));
      await this.pref.flush();
    } catch (error) {
      // Ignore storage failures.
    }
  }

  async clear(serverUrl: string, username: string): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      await this.pref.delete(this.key(serverUrl, username));
      await this.pref.flush();
    } catch (error) {
      // Ignore storage failures.
    }
  }
}

export const gReaderTokenStore: GReaderTokenStoreImpl = new GReaderTokenStoreImpl();
