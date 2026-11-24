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

  querySql(sql: string, args: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> {
    return this.onQuery(sql, args);
  }
  executeSql(sql: string, args: Array<relationalStore.ValueType>): Promise<void> {
    return this.onExec(sql);
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
  private idx: number = 0;
  private rowDone: boolean = false;
  goToNextRow(): boolean {
    if (this.rowDone) return false;
    this.rowDone = true;
    return true;
  }
  getColumnIndex(name: string): number { return 0; }
  getString(i: number): string { return ''; }
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
