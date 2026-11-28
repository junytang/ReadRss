import { describe, it, expect, MockKit, when } from '@ohos/hypium';
import { database } from '../main/ets/data/Database';
import { relationalStore } from '@kit.ArkData';
import { Article } from '../main/ets/model/Models';
import { PendingFilterIds } from '../main/ets/rss/StatusDiffs';

interface DbAccess { db(): relationalStore.RdbStore; }
interface FakeResultSet {
  goToNextRow(): boolean;
  getColumnIndex(name: string): number;
  getString(i: number): string;
  getLong(i: number): number;
  close(): void;
}
class FakeStore {
  onQuery: (sql: string, args: Array<relationalStore.ValueType>) => Promise<relationalStore.ResultSet> =
    (): Promise<relationalStore.ResultSet> => Promise.resolve(new EmptyResultSet() as object as relationalStore.ResultSet);
  onExec: (sql: string) => Promise<void> = (): Promise<void> => Promise.resolve();
  onExecWithArgs: (sql: string, args: Array<relationalStore.ValueType>) => Promise<void> =
    (): Promise<void> => Promise.resolve();

  querySql(sql: string, args: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> {
    return this.onQuery(sql, args);
  }
  executeSql(sql: string, args: Array<relationalStore.ValueType>): Promise<void> {
    void this.onExec(sql);
    return this.onExecWithArgs(sql, args);
  }
  beginTransaction(): void {}
  commit(): void {}
  rollBack(): void {}
}

class EmptyResultSet implements FakeResultSet {
  goToNextRow(): boolean { return false; }
  getColumnIndex(name: string): number { return 0; }
  getString(i: number): string { return ''; }
  getLong(i: number): number { return 0; }
  close(): void {}
}

/** ResultSet with one row; getLong returns values in sequence per call. */
class OneRowResultSet implements FakeResultSet {
  seq: number[] = [];
  idValue: string = '';
  private idx: number = 0;
  private rowDone: boolean = false;
  goToNextRow(): boolean {
    if (this.rowDone) return false;
    this.rowDone = true;
    return true;
  }
  getColumnIndex(name: string): number { return 0; }
  getString(i: number): string { return this.idValue; }
  getLong(i: number): number {
    const v: number = this.seq[this.idx] ?? 0;
    this.idx++;
    return v;
  }
  close(): void {}
}

export default function databaseTest(): void {
  describe('Database SQL construction (mocked RdbStore)', () => {
    it('listArticles builds unread-scoped SQL with correct ORDER BY', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      let capturedArgs: Array<relationalStore.ValueType> = [];

      const rs: relationalStore.ResultSet = new EmptyResultSet() as object as relationalStore.ResultSet;
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onQuery = (sql: string, args: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> => {
        capturedSql = sql;
        capturedArgs = args;
        return Promise.resolve(rs);
      };

      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);
      const access = database as object as DbAccess;
      expect(access.db() === (fakeStore as object as relationalStore.RdbStore)).assertTrue();

      const rows: Article[] = await database.listArticles('acc1', 'feed1', 'unread', 30, 'g1', false, 'kw', true);
      expect(rows.length).assertEqual(0);
      expect(capturedSql.indexOf('a.account_id = ?') >= 0).assertTrue();
      expect(capturedSql.indexOf('a.feed_id = ?') >= 0).assertTrue();
      expect(capturedSql.indexOf('a.is_read = 0') >= 0).assertTrue();
      expect(capturedSql.indexOf('a.feed_id IN (SELECT id FROM feed WHERE group_id = ?)') >= 0).assertTrue();
      expect(capturedSql.indexOf('a.title LIKE ?') >= 0).assertTrue();
      expect(capturedSql.indexOf('ORDER BY a.published_at DESC, a.id DESC LIMIT ?') >= 0).assertTrue();
      expect(capturedArgs.length).assertEqual(7);
      mock.clear(database);
    });

    it('listArticles uses a keyset cursor predicate with the last row values', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      let capturedArgs: Array<relationalStore.ValueType> = [];
      const rs: relationalStore.ResultSet = new EmptyResultSet() as object as relationalStore.ResultSet;
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onQuery = (sql: string, args: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> => {
        capturedSql = sql;
        capturedArgs = args;
        return Promise.resolve(rs);
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.listArticles('acc1', '', 'unread', 30, '', false, undefined, true, undefined,
        { publishedAt: 1234, id: 'a9' });
      expect(capturedSql.indexOf('a.published_at < ? OR (a.published_at = ? AND a.id < ?)') >= 0)
        .assertTrue();
      expect(capturedArgs.length).assertEqual(5);
      expect(capturedArgs[1]).assertEqual(1234);
      expect(capturedArgs[2]).assertEqual(1234);
      expect(capturedArgs[3]).assertEqual('a9');
      mock.clear(database);
    });

    it('insertArticles batches rows and counts only genuinely new ids on IGNORE', 0, async () => {
      const mock: MockKit = new MockKit();
      const statements: string[] = [];
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExecWithArgs = (sql: string): Promise<void> => {
        if (sql.indexOf('INSERT OR IGNORE') >= 0) {
          statements.push(sql);
        }
        return Promise.resolve();
      };
      // One existing row: the count must exclude it.
      const existing: OneRowResultSet = new OneRowResultSet();
      existing.idValue = 'a1';
      fakeStore.onQuery = (): Promise<relationalStore.ResultSet> =>
        Promise.resolve(existing as object as relationalStore.ResultSet);
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      const articles: Article[] = [];
      for (let i: number = 0; i < 3; i++) {
        const a: Article = {
          id: `a${i}`, feedId: 'f1', feedTitle: 'F', title: 't', author: '', link: '',
          summary: '', content: '', fullContent: '', imageUrl: '', publishedAt: 1,
          isRead: false, isStarred: false,
        };
        articles.push(a);
      }
      const inserted: number = await database.insertArticles(articles, 'acc1', true);
      // a1 already exists locally: it must not be counted as newly inserted.
      expect(inserted).assertEqual(2);
      expect(statements.length).assertEqual(1);
      // Two surviving rows produce two multi-column VALUES groups.
      expect((statements[0].match(/\(\?\s*,\s*\?/g) ?? []).length >= 2).assertTrue();
      mock.clear(database);
    });

    it('clearFullContent scopes the UPDATE to one account', 0, async () => {
      const mock: MockKit = new MockKit();
      let sql: string = '';
      let args: Array<relationalStore.ValueType> = [];
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExecWithArgs = (s: string, a: Array<relationalStore.ValueType>): Promise<void> => {
        sql = s;
        args = a;
        return Promise.resolve();
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.clearFullContent('acc2');
      expect(sql.indexOf('WHERE account_id = ?') >= 0).assertTrue();
      expect(args.length).assertEqual(1);
      expect(args[0]).assertEqual('acc2');
      mock.clear(database);
    });

    it('debugClearAllArticles scopes deletion and cursor reset to one account', 0, async () => {
      const mock: MockKit = new MockKit();
      const statements: string[] = [];
      const args: Array<Array<relationalStore.ValueType>> = [];
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExecWithArgs = (s: string, a: Array<relationalStore.ValueType>): Promise<void> => {
        statements.push(s);
        args.push(a);
        return Promise.resolve();
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.debugClearAllArticles('acc2');
      expect(statements.length).assertEqual(2);
      // article is keyed by account_id; account is keyed by id.
      expect(statements[0].indexOf('DELETE FROM article WHERE account_id = ?') >= 0).assertTrue();
      expect(statements[1].indexOf('UPDATE account') >= 0).assertTrue();
      expect(statements[1].indexOf('WHERE id = ?') >= 0).assertTrue();
      expect(args[0][0]).assertEqual('acc2');
      expect(args[1][0]).assertEqual('acc2');
      mock.clear(database);
    });

    it('listArticles includes pending local ids in starred/unread filters', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      let capturedArgs: Array<relationalStore.ValueType> = [];
      const rs: relationalStore.ResultSet = new EmptyResultSet() as object as relationalStore.ResultSet;
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onQuery = (sql: string, args: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> => {
        capturedSql = sql;
        capturedArgs = args;
        return Promise.resolve(rs);
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      const pending: PendingFilterIds = {
        starredIds: ['acc1$newstar'], unstarredIds: ['acc1$oldstar'],
        unreadIds: ['acc1$newunread'], readIds: ['acc1$oldread'],
      };
      await database.listArticles('acc1', '', 'starred', 30, '', false, '', true, pending);
      expect(capturedSql.indexOf('a.is_starred = 1 OR a.id IN (?)') >= 0).assertTrue();
      expect(capturedSql.indexOf('a.id NOT IN (?)') >= 0).assertTrue();
      expect(capturedArgs.indexOf('acc1$newstar') >= 0).assertTrue();
      expect(capturedArgs.indexOf('acc1$oldstar') >= 0).assertTrue();

      await database.listArticles('acc1', '', 'unread', 30, '', false, '', true, pending);
      expect(capturedSql.indexOf('a.is_read = 0 OR a.id IN (?)') >= 0).assertTrue();
      expect(capturedArgs.indexOf('acc1$newunread') >= 0).assertTrue();
      mock.clear(database);
    });

    it('listArticles ascending sort and non-lightweight columns', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      const rs: relationalStore.ResultSet = new EmptyResultSet() as object as relationalStore.ResultSet;
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onQuery = (sql: string): Promise<relationalStore.ResultSet> => {
        capturedSql = sql;
        return Promise.resolve(rs);
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.listArticles('acc1', '', 'all', 50, '', true, '', false);
      expect(capturedSql.indexOf('a.content') >= 0).assertTrue();
      expect(capturedSql.indexOf('a.full_content') >= 0).assertTrue();
      expect(capturedSql.indexOf('ORDER BY a.published_at ASC, a.id ASC LIMIT ?') >= 0).assertTrue();
      mock.clear(database);
    });

    it('insertArticles uses INSERT OR IGNORE when ignoreExisting', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExec = (sql: string): Promise<void> => { capturedSql = sql; return Promise.resolve(); };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      const article: Article = {
        id: 'a1', feedId: 'f1', feedTitle: 'F', title: 'T', author: '', link: '',
        summary: '', content: '', fullContent: '', imageUrl: '', publishedAt: 0,
        isRead: false, isStarred: false,
      };
      await database.insertArticles([article], 'acc1', true);
      expect(capturedSql.indexOf('INSERT OR IGNORE INTO article') >= 0).assertTrue();
      mock.clear(database);
    });

    it('articleCounts builds aggregate SQL and maps one row', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      const row: OneRowResultSet = new OneRowResultSet();
      row.seq = [5, 2, 20]; // unread, starred, total
      const rs: relationalStore.ResultSet = row as object as relationalStore.ResultSet;
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onQuery = (sql: string): Promise<relationalStore.ResultSet> => {
        capturedSql = sql;
        return Promise.resolve(rs);
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      const counts = await database.articleCounts('acc1', 'f1', 'g1');
      expect(counts.unread).assertEqual(5);
      expect(counts.starred).assertEqual(2);
      expect(counts.total).assertEqual(20);
      expect(capturedSql.indexOf('SUM(CASE WHEN is_read = 0') >= 0).assertTrue();
      expect(capturedSql.indexOf('SUM(CASE WHEN is_starred = 1') >= 0).assertTrue();
      expect(capturedSql.indexOf('AND feed_id = ?') >= 0).assertTrue();
      expect(capturedSql.indexOf('feed_id IN (SELECT id FROM feed WHERE group_id = ?)') >= 0).assertTrue();
      mock.clear(database);
    });

    it('countUnread builds unread COUNT SQL', 0, async () => {
      const mock: MockKit = new MockKit();
      let capturedSql: string = '';
      const row: OneRowResultSet = new OneRowResultSet();
      row.seq = [7];
      const rs: relationalStore.ResultSet = row as object as relationalStore.ResultSet;
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onQuery = (sql: string): Promise<relationalStore.ResultSet> => {
        capturedSql = sql;
        return Promise.resolve(rs);
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      const n: number = await database.countUnread('acc1');
      expect(n).assertEqual(7);
      expect(capturedSql.indexOf('is_read = 0') >= 0).assertTrue();
      mock.clear(database);
    });

    it('setStates writes batched UPDATE with read/starset columns', 0, async () => {
      const mock: MockKit = new MockKit();
      const sqls: string[] = [];
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExec = (sql: string): Promise<void> => { sqls.push(sql); return Promise.resolve(); };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.setStates(['a1', 'a2'], true, undefined);
      expect(sqls.length >= 1).assertTrue();
      expect(sqls[0].indexOf('UPDATE article SET is_read = ?') >= 0).assertTrue();
      mock.clear(database);
    });

    it('bulk read-state setters honor the before cutoff', 0, async () => {
      const mock: MockKit = new MockKit();
      const sqls: string[] = [];
      const argsets: Array<Array<relationalStore.ValueType>> = [];
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExecWithArgs = (sql: string, args: Array<relationalStore.ValueType>): Promise<void> => {
        sqls.push(sql);
        argsets.push(args);
        return Promise.resolve();
      };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.setStatesByFeed('acc1', 'f1', true, 5000);
      await database.setStatesByGroup('acc1', 'g1', true, 5000);
      await database.setAllRead('acc1', true, 5000);
      expect(sqls.length).assertEqual(3);
      for (const sql of sqls) {
        expect(sql.indexOf('published_at < ?') >= 0).assertTrue();
      }
      for (const args of argsets) {
        expect(args[args.length - 1]).assertEqual(5000);
      }
      mock.clear(database);
    });

    it('deleteFeedById issues DELETE for article and feed', 0, async () => {
      const mock: MockKit = new MockKit();
      const sqls: string[] = [];
      const fakeStore: FakeStore = new FakeStore();
      fakeStore.onExec = (sql: string): Promise<void> => { sqls.push(sql); return Promise.resolve(); };
      const dbMock = mock.mockPrivateFunc(database, 'db');
      when(dbMock)().afterReturn(fakeStore as object as relationalStore.RdbStore);

      await database.deleteFeedById('f1');
      expect(sqls.length).assertEqual(2);
      expect(sqls[0].indexOf('DELETE FROM article WHERE feed_id = ?') >= 0).assertTrue();
      expect(sqls[1].indexOf('DELETE FROM feed WHERE id = ?') >= 0).assertTrue();
      mock.clear(database);
    });
  });
}
