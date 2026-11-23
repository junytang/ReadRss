import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DB_NAME } from '../common/Constants';
import { Account, AccountType, EMPTY_SECURITY_KEY, isValidAccountType } from '../account/AccountModels';
import { Article, ArticleNeighbors, Feed, FeedGroup } from '../model/Models';
import { Logger } from '../common/Logger';

/** Unread / starred / total counts for one scope, read in a single query. */
export interface ArticleCounts {
  unread: number;
  starred: number;
  total: number;
}

/** Minimal read/star state of an article, used for remote reconciliation. */
export interface ArticleState {
  id: string;
  isRead: boolean;
  isStarred: boolean;
}

/** Column offsets resolved once per ResultSet instead of once per row. */
interface ArticleColumns {
  id: number;
  feedId: number;
  feedTitle: number;
  title: number;
  author: number;
  link: number;
  summary: number;
  content: number;
  fullContent: number;
  imageUrl: number;
  publishedAt: number;
  isRead: number;
  isStarred: number;
}

/** Max ids per `UPDATE ... WHERE id IN (...)`; SQLite's variable limit is 999. */
const STATE_UPDATE_CHUNK: number = 500;

/**
 * RDB-backed local store. Counterpart of Room's `Reader` database, extended
 * with accounts and groups for Fever / Google Reader sync.
 */
class ReadYouDatabase {
  private store?: relationalStore.RdbStore;
  private initTask?: Promise<void>;
  // Explicit transactions (beginTransaction) hold the store's single write
  // connection until commit. Serialize them so a user mark-read cannot overlap
  // a sync's batch insert (which would throw "already in transaction" or time
  // out waiting for the connection).
  private txChain: Promise<void> = Promise.resolve();

  /** Run `body` inside a serialized transaction. commit() runs outside the
   *  body's catch so a commit failure is never masked by rollBack(). */
  private async withTransaction<T>(body: () => Promise<T>): Promise<T> {
    const job: Promise<T> = this.txChain.then(async () => {
      const store: relationalStore.RdbStore = this.db();
      store.beginTransaction();
      let result: T;
      try {
        result = await body();
      } catch (error) {
        try { store.rollBack(); } catch (rbError) { /* keep original error */ }
        throw error as Error;
      }
      try {
        store.commit();
      } catch (error) {
        try { store.rollBack(); } catch (rbError) { /* keep commit error */ }
        throw error as Error;
      }
      return result;
    });
    // Keep the chain alive regardless of this job's outcome so later writes
    // still run; swallow the error here (the caller gets it from `job`).
    this.txChain = new Promise<void>((resolve: () => void) => {
      job.then(() => resolve(), () => resolve());
    });
    return job;
  }

  async init(context: common.Context): Promise<void> {
    if (this.store) {
      return;
    }
    if (!this.initTask) {
      this.initTask = this.create(context);
    }
    return this.initTask;
  }

  private async create(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    // getRdbStore is @throws; surface a clear failure instead of leaking a raw
    // platform exception from init().
    try {
      this.store = await relationalStore.getRdbStore(context, config);
    } catch (error) {
      Logger.error(`Open database failed: ${(error as Error).message}`);
      throw new Error(`Open database failed: ${(error as Error).message}`);
    }

    // exec() wraps relationalStore's @throws executeSql API with logging and
    // rethrow, keeping schema setup consistent with all other DB writes.
    await this.exec(
      `CREATE TABLE IF NOT EXISTS account (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type INTEGER NOT NULL,
        security_key TEXT NOT NULL DEFAULT '${EMPTY_SECURITY_KEY}',
        update_at INTEGER DEFAULT NULL,
        last_article_id TEXT DEFAULT NULL,
        sync_interval INTEGER NOT NULL DEFAULT 30,
        sync_on_start INTEGER NOT NULL DEFAULT 0,
        sync_only_on_wifi INTEGER NOT NULL DEFAULT 0,
        sync_only_when_charging INTEGER NOT NULL DEFAULT 0,
        keep_archived INTEGER NOT NULL DEFAULT 2592000000,
        sync_block_list TEXT NOT NULL DEFAULT ''
      )`
    );
    await this.exec(
      `CREATE TABLE IF NOT EXISTS feed_group (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )`
    );
    await this.exec(
      `CREATE TABLE IF NOT EXISTS feed (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL DEFAULT '1',
        title TEXT NOT NULL,
        url TEXT NOT NULL,
        group_id TEXT NOT NULL DEFAULT '',
        icon_url TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0
      )`
    );
    await this.exec(
      `CREATE TABLE IF NOT EXISTS article (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL DEFAULT '1',
        feed_id TEXT NOT NULL,
        feed_title TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL,
        author TEXT NOT NULL DEFAULT '',
        link TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        full_content TEXT NOT NULL DEFAULT '',
        image_url TEXT NOT NULL DEFAULT '',
        published_at INTEGER NOT NULL DEFAULT 0,
        is_read INTEGER NOT NULL DEFAULT 0,
        is_starred INTEGER NOT NULL DEFAULT 0
      )`
    );
    await this.exec(
      'CREATE INDEX IF NOT EXISTS idx_article_feed ON article(feed_id, published_at DESC)'
    );

    // Forward-compatible upgrades from earlier MVP schemas.
    await this.tryExecute('ALTER TABLE feed ADD COLUMN account_id TEXT NOT NULL DEFAULT \'1\'');
    await this.tryExecute('ALTER TABLE article ADD COLUMN account_id TEXT NOT NULL DEFAULT \'1\'');
    await this.tryExecute('ALTER TABLE article ADD COLUMN full_content TEXT NOT NULL DEFAULT \'\'');
    await this.tryExecute('ALTER TABLE account ADD COLUMN sync_interval INTEGER NOT NULL DEFAULT 30');
    await this.tryExecute('ALTER TABLE account ADD COLUMN sync_on_start INTEGER NOT NULL DEFAULT 0');
    await this.tryExecute('ALTER TABLE account ADD COLUMN sync_only_on_wifi INTEGER NOT NULL DEFAULT 0');
    await this.tryExecute('ALTER TABLE account ADD COLUMN sync_only_when_charging INTEGER NOT NULL DEFAULT 0');
    await this.tryExecute('ALTER TABLE account ADD COLUMN keep_archived INTEGER NOT NULL DEFAULT 2592000000');
    await this.tryExecute('ALTER TABLE account ADD COLUMN sync_block_list TEXT NOT NULL DEFAULT \'\'');
    await this.exec('CREATE INDEX IF NOT EXISTS idx_feed_account ON feed(account_id)');
    await this.exec('CREATE INDEX IF NOT EXISTS idx_article_account ON article(account_id)');
    await this.exec('CREATE INDEX IF NOT EXISTS idx_group_account ON feed_group(account_id)');
    // Composite indexes covering the list queries: account scope + the
    // filter column + the secondary-sorted ORDER BY (published_at, id). Without
    // these, unread/starred listings and per-feed counts do a full scan + temp
    // sort on every badge refresh during sync.
    await this.exec(
      'CREATE INDEX IF NOT EXISTS idx_article_account_feed_pub ON article(account_id, feed_id, published_at DESC, id DESC)'
    );
    await this.exec(
      'CREATE INDEX IF NOT EXISTS idx_article_account_read_pub ON article(account_id, is_read, published_at DESC, id DESC)'
    );
    await this.exec(
      'CREATE INDEX IF NOT EXISTS idx_article_account_star_pub ON article(account_id, is_starred, published_at DESC, id DESC)'
    );
    // Covers listFeeds' per-feed unread/star sums without touching full text.
    await this.exec(
      'CREATE INDEX IF NOT EXISTS idx_article_feed_state ON article(feed_id, is_read, is_starred)'
    );
    Logger.info('Database schema ready (multi-account)');
  }


  // Wrappers that contain the exceptions thrown by relationalStore's sync / async APIs.
  private colIndex(rs: relationalStore.ResultSet, column: string): number {
    try { return rs.getColumnIndex(column); }
    catch (error) { Logger.error(`DB getColumnIndex failed: ${(error as Error).message}`); return -1; }
  }

  private str(rs: relationalStore.ResultSet, index: number): string {
    try { return rs.getString(index); }
    catch (error) { Logger.error(`DB getString failed: ${(error as Error).message}`); return ''; }
  }

  private lng(rs: relationalStore.ResultSet, index: number): number {
    try { return rs.getLong(index); }
    catch (error) { Logger.error(`DB getLong failed: ${(error as Error).message}`); return 0; }
  }

  private nextRow(rs: relationalStore.ResultSet): boolean {
    try { return rs.goToNextRow(); }
    catch (error) { Logger.error(`DB goToNextRow failed: ${(error as Error).message}`); return false; }
  }

  private closeRs(rs: relationalStore.ResultSet): void {
    try { rs.close(); }
    catch (error) { Logger.error(`DB ResultSet.close failed: ${(error as Error).message}`); }
  }

  private async exec(
    sql: string, args: Array<relationalStore.ValueType> = [], silent: boolean = false
  ): Promise<void> {
    try { await this.db().executeSql(sql, args); }
    catch (error) {
      if (!silent) {
        Logger.error(`DB executeSql failed: ${(error as Error).message}`);
      }
      throw error as Error;
    }
  }

  private async query(sql: string, args: Array<relationalStore.ValueType> = []): Promise<relationalStore.ResultSet> {
    try { return await this.db().querySql(sql, args); }
    catch (error) { Logger.error(`DB querySql failed: ${(error as Error).message}`); throw error as Error; }
  }

  private async tryExecute(sql: string): Promise<void> {
    try {
      await this.exec(sql, [], true);
    } catch (error) {
      // Duplicate-column errors are expected when upgrading from the MVP schema.
    }
  }

  private db(): relationalStore.RdbStore {
    if (!this.store) {
      throw new Error('Database not initialised');
    }
    return this.store as relationalStore.RdbStore;
  }

  // ------------------------------ accounts --------------------------------

  async listAccounts(): Promise<Account[]> {
    const result: Account[] = [];
    const rs = await this.query('SELECT * FROM account ORDER BY CAST(id AS INTEGER) ASC');
    try {
      while (this.nextRow(rs)) {
        result.push(this.readAccount(rs));
      }
    } finally {
      this.closeRs(rs);
    }
    return result;
  }

  async getAccount(id: string): Promise<Account | undefined> {
    const rs = await this.query('SELECT * FROM account WHERE id = ? LIMIT 1', [id]);
    try {
      if (this.nextRow(rs)) {
        return this.readAccount(rs);
      }
    } finally {
      this.closeRs(rs);
    }
    return undefined;
  }

  private readLong(rs: relationalStore.ResultSet, column: string, fallback: number): number {
    const index: number = this.colIndex(rs, column);
    return index >= 0 ? this.lng(rs, index) : fallback;
  }

  private readText(rs: relationalStore.ResultSet, column: string, fallback: string): string {
    const index: number = this.colIndex(rs, column);
    return index >= 0 ? this.str(rs, index) : fallback;
  }

  private readAccount(rs: relationalStore.ResultSet): Account {
    const rawType: number = this.readLong(rs, 'type', AccountType.LOCAL);
    if (!isValidAccountType(rawType)) {
      throw new Error(`Invalid AccountType id: ${rawType}`);
    }
    return {
      id: this.readText(rs, 'id', ''),
      name: this.readText(rs, 'name', ''),
      type: rawType as AccountType,
      securityKey: this.readText(rs, 'security_key', EMPTY_SECURITY_KEY),
      updateAt: this.readLong(rs, 'update_at', 0),
      lastArticleId: this.readText(rs, 'last_article_id', ''),
      syncInterval: this.readLong(rs, 'sync_interval', 30),
      syncOnStart: this.readLong(rs, 'sync_on_start', 0) === 1,
      syncOnlyOnWiFi: this.readLong(rs, 'sync_only_on_wifi', 0) === 1,
      syncOnlyWhenCharging: this.readLong(rs, 'sync_only_when_charging', 0) === 1,
      keepArchived: this.readLong(rs, 'keep_archived', 2592000000),
      syncBlockList: this.readText(rs, 'sync_block_list', ''),
    };
  }

  async insertAccount(account: Account): Promise<void> {
    await this.exec(
      `INSERT OR REPLACE INTO account
       (id, name, type, security_key, update_at, last_article_id,
        sync_interval, sync_on_start, sync_only_on_wifi, sync_only_when_charging,
        keep_archived, sync_block_list)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        account.id, account.name, account.type, account.securityKey,
        account.updateAt, account.lastArticleId,
        account.syncInterval, account.syncOnStart ? 1 : 0,
        account.syncOnlyOnWiFi ? 1 : 0, account.syncOnlyWhenCharging ? 1 : 0,
        account.keepArchived, account.syncBlockList,
      ]
    );
  }

  async updateAccount(account: Account): Promise<void> {
    await this.insertAccount(account);
  }

  async updateAccountSyncState(id: string, updateAt: number, lastArticleId: string): Promise<void> {
    await this.exec(
      'UPDATE account SET update_at = ?, last_article_id = ? WHERE id = ?',
      [updateAt, lastArticleId, id]
    );
  }

  async deleteAccount(id: string): Promise<void> {
    await this.exec('DELETE FROM article WHERE account_id = ?', [id]);
    await this.exec('DELETE FROM feed WHERE account_id = ?', [id]);
    await this.exec('DELETE FROM feed_group WHERE account_id = ?', [id]);
    await this.exec('DELETE FROM account WHERE id = ?', [id]);
  }

  // ------------------------------- groups ---------------------------------

  async listGroups(accountId: string): Promise<FeedGroup[]> {
    const result: FeedGroup[] = [];
    const rs = await this.query(
      `SELECT id, name, sort_order FROM feed_group WHERE account_id = ?
       ORDER BY (SELECT MAX(a.published_at) FROM article a, feed f
                 WHERE a.feed_id = f.id AND f.group_id = feed_group.id) DESC,
                sort_order, name`,
      [accountId]
    );
    try {
      const idCol: number = this.colIndex(rs, 'id');
      const nameCol: number = this.colIndex(rs, 'name');
      const sortCol: number = this.colIndex(rs, 'sort_order');
      while (this.nextRow(rs)) {
        result.push({
          id: this.str(rs, idCol),
          name: this.str(rs, nameCol),
          sortOrder: this.lng(rs, sortCol),
        });
      }
    } finally {
      this.closeRs(rs);
    }
    return result;
  }

  async upsertGroup(group: FeedGroup, accountId: string): Promise<void> {
    await this.exec(
      `INSERT OR REPLACE INTO feed_group (id, account_id, name, sort_order) VALUES (?, ?, ?, ?)`,
      [group.id, accountId, group.name, group.sortOrder]
    );
  }

  async deleteGroupsExcept(accountId: string, keepIds: string[]): Promise<void> {
    for (const group of await this.listGroups(accountId)) {
      if (keepIds.indexOf(group.id) < 0) {
        await this.exec('DELETE FROM feed_group WHERE id = ?', [group.id]);
      }
    }
  }

  // -------------------------------- feeds ---------------------------------

  async listFeeds(accountId: string): Promise<Feed[]> {
    // One grouped scan of `article` instead of three correlated subqueries per
    // feed: this runs on every sync batch tick, so the per-feed subqueries made
    // badge refreshes cost O(feeds × articles).
    const sql: string =
      `SELECT f.id, f.title, f.url, f.group_id, f.icon_url, f.sort_order,
              COALESCE(a.unread_count, 0) AS unread_count,
              COALESCE(a.starred_count, 0) AS starred_count
       FROM feed f
       LEFT JOIN (
         SELECT feed_id,
                SUM(CASE WHEN is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                SUM(CASE WHEN is_starred = 1 THEN 1 ELSE 0 END) AS starred_count,
                MAX(published_at) AS latest_at
         FROM article GROUP BY feed_id
       ) a ON a.feed_id = f.id
       WHERE f.account_id = ?
       ORDER BY a.latest_at DESC, f.sort_order ASC, f.title ASC`;
    const result: Feed[] = [];
    const rs = await this.query(sql, [accountId]);
    try {
      const idCol: number = this.colIndex(rs, 'id');
      const titleCol: number = this.colIndex(rs, 'title');
      const urlCol: number = this.colIndex(rs, 'url');
      const groupCol: number = this.colIndex(rs, 'group_id');
      const iconCol: number = this.colIndex(rs, 'icon_url');
      const sortCol: number = this.colIndex(rs, 'sort_order');
      const unreadCol: number = this.colIndex(rs, 'unread_count');
      const starredCol: number = this.colIndex(rs, 'starred_count');
      while (this.nextRow(rs)) {
        result.push({
          id: this.str(rs, idCol),
          title: this.str(rs, titleCol),
          url: this.str(rs, urlCol),
          groupId: this.str(rs, groupCol),
          iconUrl: this.str(rs, iconCol),
          sortOrder: this.lng(rs, sortCol),
          unreadCount: this.lng(rs, unreadCol),
          starredCount: this.lng(rs, starredCol),
        });
      }
    } finally {
      this.closeRs(rs);
    }
    return result;
  }

  /** Single feed row; used by the reader to resolve its source icon. */
  async getFeedById(id: string): Promise<Feed | undefined> {
    const rs = await this.query(
      `SELECT id, title, url, group_id, icon_url, sort_order
       FROM feed WHERE id = ? LIMIT 1`,
      [id]
    );
    try {
      if (this.nextRow(rs)) {
        return {
          id: this.str(rs, this.colIndex(rs, 'id')),
          title: this.str(rs, this.colIndex(rs, 'title')),
          url: this.str(rs, this.colIndex(rs, 'url')),
          groupId: this.str(rs, this.colIndex(rs, 'group_id')),
          iconUrl: this.str(rs, this.colIndex(rs, 'icon_url')),
          sortOrder: this.lng(rs, this.colIndex(rs, 'sort_order')),
          unreadCount: 0,
          starredCount: 0,
        };
      }
    } finally {
      this.closeRs(rs);
    }
    return undefined;
  }

  async getFeedByUrl(accountId: string, url: string): Promise<Feed | undefined> {
    const rs = await this.query(
      `SELECT id, title, url, group_id, icon_url, sort_order, 0 AS unread_count
       FROM feed WHERE account_id = ? AND url = ? LIMIT 1`,
      [accountId, url]
    );
    try {
      if (this.nextRow(rs)) {
        return {
          id: this.str(rs, this.colIndex(rs, 'id')),
          title: this.str(rs, this.colIndex(rs, 'title')),
          url: this.str(rs, this.colIndex(rs, 'url')),
          groupId: this.str(rs, this.colIndex(rs, 'group_id')),
          iconUrl: this.str(rs, this.colIndex(rs, 'icon_url')),
          sortOrder: this.lng(rs, this.colIndex(rs, 'sort_order')),
          unreadCount: 0,
          starredCount: 0,
        };
      }
    } finally {
      this.closeRs(rs);
    }
    return undefined;
  }

  async upsertFeed(feed: Feed, accountId: string): Promise<void> {
    await this.exec(
      `INSERT OR REPLACE INTO feed (id, account_id, title, url, group_id, icon_url, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [feed.id, accountId, feed.title, feed.url, feed.groupId, feed.iconUrl, feed.sortOrder]
    );
  }

  async deleteFeedById(id: string): Promise<void> {
    await this.exec('DELETE FROM article WHERE feed_id = ?', [id]);
    await this.exec('DELETE FROM feed WHERE id = ?', [id]);
  }

  async deleteFeedsExcept(accountId: string, keepIds: string[]): Promise<void> {
    for (const feed of await this.listFeeds(accountId)) {
      if (keepIds.indexOf(feed.id) < 0) {
        await this.deleteFeedById(feed.id);
      }
    }
  }

  // ------------------------------ articles --------------------------------

  /** Android pullArticles: scope × filter, with optional ascending sort and search. */
  async listArticles(
    accountId: string, feedId: string, filter: string, limit: number,
    groupId?: string, sortAscending?: boolean, searchContent?: string,
    lightweight: boolean = false
  ): Promise<Article[]> {
    // The article list only renders title/summary/metadata. Reading `content`
    // and `full_content` here would marshal every article's full HTML body into
    // memory just to show a row — the main cause of the stutter when switching
    // to the "all" filter (up to 500 bodies at once). Those columns are loaded
    // on demand by getArticle / the prefetcher instead.
    const columns: string = lightweight
      ? `a.id, a.feed_id, a.feed_title, a.title, a.author, a.link,
              a.summary, a.image_url, a.published_at, a.is_read, a.is_starred`
      : `a.id, a.feed_id, a.feed_title, a.title, a.author, a.link,
              a.summary, a.content, a.full_content, a.image_url, a.published_at, a.is_read, a.is_starred`;
    let sql: string = `SELECT ${columns} FROM article a WHERE a.account_id = ?`;
    const args: Array<string | number> = [accountId];
    if (feedId.length > 0) {
      sql += ' AND a.feed_id = ?';
      args.push(feedId);
    }
    if (filter === 'unread') {
      sql += ' AND a.is_read = 0';
    } else if (filter === 'starred') {
      sql += ' AND a.is_starred = 1';
    }
    if (groupId && groupId.length > 0) {
      sql += ' AND a.feed_id IN (SELECT id FROM feed WHERE group_id = ?)';
      args.push(groupId);
    }
    if (searchContent && searchContent.length > 0) {
      sql += ' AND (a.title LIKE ? OR a.summary LIKE ? OR a.content LIKE ?)';
      const pattern: string = `%${searchContent}%`;
      args.push(pattern, pattern, pattern);
    }
    // Secondary key on id keeps ordering deterministic when several articles
    // share the same published_at, so the list cannot reshuffle between the
    // incremental-limit reloads used for paging.
    sql += sortAscending
      ? ' ORDER BY a.published_at ASC, a.id ASC LIMIT ?'
      : ' ORDER BY a.published_at DESC, a.id DESC LIMIT ?';
    args.push(limit);

    const result: Article[] = [];
    const rs = await this.query(sql, args);
    try {
      // Resolve column offsets once per query: doing it per row costs a
      // try/catch + string lookup for every one of the 13 columns.
      const cols: ArticleColumns = this.articleColumns(rs, !lightweight);
      while (this.nextRow(rs)) {
        result.push(this.readArticle(rs, cols, !lightweight));
      }
    } finally {
      this.closeRs(rs);
    }
    return result;
  }

  async listArticleIdsForFeed(accountId: string, feedId: string): Promise<string[]> {
    const rs = await this.query(
      'SELECT id FROM article WHERE account_id = ? AND feed_id = ? ORDER BY published_at DESC',
      [accountId, feedId]
    );
    const ids: string[] = [];
    try {
      while (this.nextRow(rs)) {
        ids.push(this.str(rs, this.colIndex(rs, 'id')));
      }
    } finally {
      this.closeRs(rs);
    }
    return ids;
  }

  async getArticle(id: string): Promise<Article | undefined> {
    const rs = await this.query(
      `SELECT a.id, a.feed_id, a.feed_title, a.title, a.author, a.link,
              a.summary, a.content, a.full_content, a.image_url, a.published_at, a.is_read, a.is_starred
       FROM article a WHERE a.id = ? LIMIT 1`,
      [id]
    );
    try {
      if (this.nextRow(rs)) {
        return this.readArticle(rs, this.articleColumns(rs));
      }
    } finally {
      this.closeRs(rs);
    }
    return undefined;
  }

  /** Same as getArticle without the HTML bodies; for callers that only need
   *  metadata (remote id, title, link). Avoids marshalling a full body. */
  async getArticleMeta(id: string): Promise<Article | undefined> {
    const rs = await this.query(
      `SELECT a.id, a.feed_id, a.feed_title, a.title, a.author, a.link,
              a.summary, a.image_url, a.published_at, a.is_read, a.is_starred
       FROM article a WHERE a.id = ? LIMIT 1`,
      [id]
    );
    try {
      if (this.nextRow(rs)) {
        return this.readArticle(rs, this.articleColumns(rs, false), false);
      }
    } finally {
      this.closeRs(rs);
    }
    return undefined;
  }

  private articleColumns(rs: relationalStore.ResultSet, includeBody: boolean = true): ArticleColumns {
    return {
      id: this.colIndex(rs, 'id'),
      feedId: this.colIndex(rs, 'feed_id'),
      feedTitle: this.colIndex(rs, 'feed_title'),
      title: this.colIndex(rs, 'title'),
      author: this.colIndex(rs, 'author'),
      link: this.colIndex(rs, 'link'),
      summary: this.colIndex(rs, 'summary'),
      content: includeBody ? this.colIndex(rs, 'content') : -1,
      fullContent: includeBody ? this.colIndex(rs, 'full_content') : -1,
      imageUrl: this.colIndex(rs, 'image_url'),
      publishedAt: this.colIndex(rs, 'published_at'),
      isRead: this.colIndex(rs, 'is_read'),
      isStarred: this.colIndex(rs, 'is_starred'),
    };
  }

  private readArticle(rs: relationalStore.ResultSet, cols: ArticleColumns, includeBody: boolean = true): Article {
    return {
      id: this.str(rs, cols.id),
      feedId: this.str(rs, cols.feedId),
      feedTitle: this.str(rs, cols.feedTitle),
      title: this.str(rs, cols.title),
      author: this.str(rs, cols.author),
      link: this.str(rs, cols.link),
      summary: this.str(rs, cols.summary),
      content: includeBody && cols.content >= 0 ? this.str(rs, cols.content) : '',
      fullContent: includeBody && cols.fullContent >= 0 ? this.str(rs, cols.fullContent) : '',
      imageUrl: this.str(rs, cols.imageUrl),
      publishedAt: this.lng(rs, cols.publishedAt),
      isRead: this.lng(rs, cols.isRead) === 1,
      isStarred: this.lng(rs, cols.isStarred) === 1,
    };
  }

  /** Returns the number of articles written. Runs as one transaction: the
   *  previous per-row commit cost one disk sync per article, which dominated
   *  large batch inserts (100-500 rows per sync batch). */
  async insertArticles(articles: Article[], accountId: string, ignoreExisting: boolean = false): Promise<number> {
    if (articles.length === 0) {
      return 0;
    }
    // Local subscriptions must not overwrite existing rows: Android's
    // insertListIfNotExist filters out links already in the DB, otherwise a
    // re-sync would reset is_read/is_starred and clear full_content (forcing a
    // re-fetch from the origin on every sync). Remote services insert only
    // id-difference sets, so they keep REPLACE to mirror ArticleDao.insert.
    const conflict: string = ignoreExisting ? 'IGNORE' : 'REPLACE';
    const sql: string =
      `INSERT OR ${conflict} INTO article
       (id, account_id, feed_id, feed_title, title, author, link, summary, content, full_content,
        image_url, published_at, is_read, is_starred)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;
    await this.withTransaction(async () => {
      for (const article of articles) {
        await this.exec(sql, [
          article.id, accountId, article.feedId, article.feedTitle, article.title,
          article.author, article.link, article.summary, article.content, article.fullContent,
          article.imageUrl, article.publishedAt,
          article.isRead ? 1 : 0, article.isStarred ? 1 : 0,
        ]);
      }
    });
    return articles.length;
  }

  async updateArticleContent(id: string, content: string): Promise<void> {
    await this.exec('UPDATE article SET content = ? WHERE id = ?', [content, id]);
  }

  async updateArticleFullContent(id: string, content: string): Promise<void> {
    await this.exec('UPDATE article SET full_content = ? WHERE id = ?', [content, id]);
  }

  /** Delete articles older than the given timestamp (ms). Returns the deleted count. */
  async deleteArticlesBefore(timestamp: number): Promise<number> {
    // Starred and unread articles are kept, matching Android: retention must
    // never remove articles the user explicitly wants to keep.
    const condition: string =
      'published_at > 0 AND published_at < ? AND is_starred = 0 AND is_read = 1';
    const rs = await this.query(
      `SELECT COUNT(*) AS n FROM article WHERE ${condition}`,
      [timestamp]
    );
    let count: number = 0;
    try {
      if (this.nextRow(rs)) {
        count = this.lng(rs, this.colIndex(rs, 'n'));
      }
    } finally {
      this.closeRs(rs);
    }
    if (count > 0) {
      await this.exec(
        `DELETE FROM article WHERE ${condition}`,
        [timestamp]
      );
    }
    return count;
  }

  async clearFullContent(): Promise<void> {
    await this.exec("UPDATE article SET full_content = ''");
  }

  async setArticleRead(id: string, read: boolean): Promise<void> {
    await this.exec('UPDATE article SET is_read = ? WHERE id = ?', [read ? 1 : 0, id]);
  }

  async setArticleStarred(id: string, starred: boolean): Promise<void> {
    await this.exec('UPDATE article SET is_starred = ? WHERE id = ?', [starred ? 1 : 0, id]);
  }

  async setStates(ids: string[], read?: boolean, starred?: boolean): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    // One UPDATE per 500 ids instead of one per id. Remote reconciliation can
    // pass tens of thousands of ids in a single call, which previously meant
    // tens of thousands of round-trips to the RDB thread.
    await this.withTransaction(async () => {
      if (read !== undefined) {
        await this.updateStateInChunks(ids, 'is_read', read ? 1 : 0);
      }
      if (starred !== undefined) {
        await this.updateStateInChunks(ids, 'is_starred', starred ? 1 : 0);
      }
    });
  }

  private async updateStateInChunks(ids: string[], column: string, value: number): Promise<void> {
    for (let start = 0; start < ids.length; start += STATE_UPDATE_CHUNK) {
      const end: number = Math.min(start + STATE_UPDATE_CHUNK, ids.length);
      let placeholders: string = '';
      const args: Array<relationalStore.ValueType> = [value];
      for (let i = start; i < end; i++) {
        placeholders += placeholders.length === 0 ? '?' : ',?';
        args.push(ids[i]);
      }
      await this.exec(
        `UPDATE article SET ${column} = ? WHERE id IN (${placeholders})`, args
      );
    }
  }

  async setStatesByFeed(accountId: string, feedId: string, read: boolean): Promise<void> {
    await this.exec(
      'UPDATE article SET is_read = ? WHERE account_id = ? AND feed_id = ?',
      [read ? 1 : 0, accountId, feedId]
    );
  }

  async markAllRead(accountId: string): Promise<void> {
    await this.setAllRead(accountId, true);
  }

  async setAllRead(accountId: string, read: boolean): Promise<void> {
    await this.exec(
      'UPDATE article SET is_read = ? WHERE account_id = ?',
      [read ? 1 : 0, accountId]
    );
  }

  async countStarredInFeed(feedId: string): Promise<number> {
    const rs = await this.query(
      'SELECT COUNT(*) AS n FROM article WHERE feed_id = ? AND is_starred = 1', [feedId]
    );
    try {
      if (this.nextRow(rs)) return this.lng(rs, this.colIndex(rs, 'n'));
    } finally {
      this.closeRs(rs);
    }
    return 0;
  }

  /** AbstractRssRepository.deleteFeed(feed, onlyDeleteNoStarred = true). */
  async deleteFeedPreservingStarred(feedId: string): Promise<void> {
    if (await this.countStarredInFeed(feedId) > 0) {
      return;
    }
    await this.deleteFeedById(feedId);
  }

  async countArticles(
    accountId: string, filter: string, feedId?: string, groupId?: string
  ): Promise<number> {
    let sql: string = 'SELECT COUNT(*) AS n FROM article WHERE account_id = ?';
    const args: Array<string | number> = [accountId];
    if (filter === 'unread') {
      sql += ' AND is_read = 0';
    } else if (filter === 'starred') {
      sql += ' AND is_starred = 1';
    }
    if (feedId && feedId.length > 0) {
      sql += ' AND feed_id = ?';
      args.push(feedId);
    }
    if (groupId && groupId.length > 0) {
      sql += ' AND feed_id IN (SELECT id FROM feed WHERE group_id = ?)';
      args.push(groupId);
    }
    const rs = await this.query(sql, args);
    try {
      if (this.nextRow(rs)) return this.lng(rs, this.colIndex(rs, 'n'));
    } finally {
      this.closeRs(rs);
    }
    return 0;
  }

  async countUnread(accountId: string, feedId?: string, groupId?: string): Promise<number> {
    let sql: string = 'SELECT COUNT(*) AS n FROM article WHERE account_id = ? AND is_read = 0';
    const args: Array<string | number> = [accountId];
    if (feedId && feedId.length > 0) {
      sql += ' AND feed_id = ?';
      args.push(feedId);
    }
    if (groupId && groupId.length > 0) {
      sql += ' AND feed_id IN (SELECT id FROM feed WHERE group_id = ?)';
      args.push(groupId);
    }
    const rs = await this.query(sql, args);
    try {
      if (this.nextRow(rs)) {
        return this.lng(rs, this.colIndex(rs, 'n'));
      }
    } finally {
      this.closeRs(rs);
    }
    return 0;
  }

  /** Unread + starred + total for one scope in a single query. The article list
   *  used to issue six separate COUNT queries (scoped and global, three filters
   *  each) on every load and badge refresh. */
  async articleCounts(
    accountId: string, feedId?: string, groupId?: string
  ): Promise<ArticleCounts> {
    let sql: string =
      `SELECT COALESCE(SUM(CASE WHEN is_read = 0 THEN 1 ELSE 0 END), 0) AS unread,
              COALESCE(SUM(CASE WHEN is_starred = 1 THEN 1 ELSE 0 END), 0) AS starred,
              COUNT(*) AS total
       FROM article WHERE account_id = ?`;
    const args: Array<string | number> = [accountId];
    if (feedId && feedId.length > 0) {
      sql += ' AND feed_id = ?';
      args.push(feedId);
    }
    if (groupId && groupId.length > 0) {
      sql += ' AND feed_id IN (SELECT id FROM feed WHERE group_id = ?)';
      args.push(groupId);
    }
    const rs = await this.query(sql, args);
    try {
      if (this.nextRow(rs)) {
        return {
          unread: this.lng(rs, this.colIndex(rs, 'unread')),
          starred: this.lng(rs, this.colIndex(rs, 'starred')),
          total: this.lng(rs, this.colIndex(rs, 'total')),
        };
      }
    } finally {
      this.closeRs(rs);
    }
    return { unread: 0, starred: 0, total: 0 };
  }

  /** Ids only, no article bodies. `markAllRead` used to load up to 100k full
   *  articles (content + full_content) just to collect their ids. */
  async listArticleIds(
    accountId: string, filter: string, feedId?: string, groupId?: string, before?: number
  ): Promise<string[]> {
    let sql: string = 'SELECT id FROM article WHERE account_id = ?';
    const args: Array<string | number> = [accountId];
    if (filter === 'unread') {
      sql += ' AND is_read = 0';
    } else if (filter === 'starred') {
      sql += ' AND is_starred = 1';
    }
    if (feedId && feedId.length > 0) {
      sql += ' AND feed_id = ?';
      args.push(feedId);
    }
    if (groupId && groupId.length > 0) {
      sql += ' AND feed_id IN (SELECT id FROM feed WHERE group_id = ?)';
      args.push(groupId);
    }
    // Only articles published before `before` (for "mark older than N days").
    if (before !== undefined && before > 0) {
      sql += ' AND published_at < ?';
      args.push(before);
    }
    const rs = await this.query(sql, args);
    const ids: string[] = [];
    try {
      const idCol: number = this.colIndex(rs, 'id');
      while (this.nextRow(rs)) {
        ids.push(this.str(rs, idCol));
      }
    } finally {
      this.closeRs(rs);
    }
    return ids;
  }

  /** Id + read/star flags for every local article in one scan. Remote
   *  reconciliation previously ran three separate full-table id queries. */
  async listArticleStates(accountId: string): Promise<ArticleState[]> {
    const rs = await this.query(
      'SELECT id, is_read, is_starred FROM article WHERE account_id = ?',
      [accountId]
    );
    const states: ArticleState[] = [];
    try {
      const idCol: number = this.colIndex(rs, 'id');
      const readCol: number = this.colIndex(rs, 'is_read');
      const starredCol: number = this.colIndex(rs, 'is_starred');
      while (this.nextRow(rs)) {
        states.push({
          id: this.str(rs, idCol),
          isRead: this.lng(rs, readCol) === 1,
          isStarred: this.lng(rs, starredCol) === 1,
        });
      }
    } finally {
      this.closeRs(rs);
    }
    return states;
  }

  /** Previous/next article ids within the same list scope as listArticles,
   *  ordered like it (published_at DESC, id DESC). Reusing the same WHERE
   *  clauses makes prev/next on the global "全部" tab span every feed instead
   *  of being confined to the current article's feed. Two bounded queries
   *  replace loading the whole scope's id list into memory. */
  async neighborArticleIds(
    accountId: string, articleId: string, publishedAt: number,
    feedId: string, filter: string, groupId: string, searchText: string
  ): Promise<ArticleNeighbors> {
    const result: ArticleNeighbors = { previous: '', next: '' };
    let where: string = 'account_id = ?';
    const scopeArgs: Array<string | number> = [accountId];
    if (feedId.length > 0) {
      where += ' AND feed_id = ?';
      scopeArgs.push(feedId);
    }
    // Unread tab: do NOT filter by is_read. Opening the current article marks it
    // read, and scrolling marks newer rows read; the list keeps those rows in
    // place (grayed out). An is_read=0 filter would exclude them from "previous",
    // breaking pull-to-previous. So unread/All both search the full feed/group scope.
    // Starred tab: DO restrict to is_starred=1 so prev/next stay within the
    // starred list the user is actually viewing (matches Android's list snapshot).
    if (filter === 'starred') {
      where += ' AND is_starred = 1';
    }
    if (groupId.length > 0) {
      where += ' AND feed_id IN (SELECT id FROM feed WHERE group_id = ?)';
      scopeArgs.push(groupId);
    }
    if (searchText.length > 0) {
      where += ' AND (title LIKE ? OR summary LIKE ? OR content LIKE ?)';
      const pattern: string = `%${searchText}%`;
      scopeArgs.push(pattern, pattern, pattern);
    }
    const newer = await this.query(
      `SELECT id FROM article
       WHERE ${where}
         AND (published_at > ? OR (published_at = ? AND id > ?))
       ORDER BY published_at ASC, id ASC LIMIT 1`,
      scopeArgs.concat([publishedAt, publishedAt, articleId])
    );
    try {
      if (this.nextRow(newer)) {
        result.previous = this.str(newer, this.colIndex(newer, 'id'));
      }
    } finally {
      this.closeRs(newer);
    }
    const older = await this.query(
      `SELECT id FROM article
       WHERE ${where}
         AND (published_at < ? OR (published_at = ? AND id < ?))
       ORDER BY published_at DESC, id DESC LIMIT 1`,
      scopeArgs.concat([publishedAt, publishedAt, articleId])
    );
    try {
      if (this.nextRow(older)) {
        result.next = this.str(older, this.colIndex(older, 'id'));
      }
    } finally {
      this.closeRs(older);
    }
    return result;
  }

  /** Remote IDs of local articles, used for remote → local state reconciliation. */
  async listRemoteIds(accountId: string, read?: boolean, starred?: boolean): Promise<string[]> {
    let sql: string = 'SELECT id FROM article WHERE account_id = ?';
    const args: Array<string | number> = [accountId];
    if (read !== undefined) {
      sql += ' AND is_read = ?';
      args.push(read ? 1 : 0);
    }
    if (starred !== undefined) {
      sql += ' AND is_starred = ?';
      args.push(starred ? 1 : 0);
    }
    const rs = await this.query(sql, args);
    const ids: string[] = [];
    try {
      while (this.nextRow(rs)) {
        ids.push(this.str(rs, this.colIndex(rs, 'id')));
      }
    } finally {
      this.closeRs(rs);
    }
    return ids;
  }
}

export const database: ReadYouDatabase = new ReadYouDatabase();
