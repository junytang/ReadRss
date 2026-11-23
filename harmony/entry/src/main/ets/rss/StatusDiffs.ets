/**
 * Pure, side-effect-free state machine for pending read/star changes.
 *
 * This is the diff-map core of Android's DiffMapHolder, extracted so it can be
 * unit-tested without any platform dependency (no AppStorage, timer, DB or IO).
 * ReadStatusStore owns one instance and adds the platform side effects around it.
 */

export interface ReadDiff {
  unread: boolean;
  feedId: string;
  groupId: string;
}

export interface StarDiff {
  starred: boolean;
  feedId: string;
}

export interface ReadIdPartition {
  readIds: string[];
  unreadIds: string[];
}

export interface StarIdPartition {
  starredIds: string[];
  unstarredIds: string[];
}

export class StatusDiffs {
  private readDiffs: Map<string, ReadDiff> = new Map<string, ReadDiff>();
  private starDiffs: Map<string, StarDiff> = new Map<string, StarDiff>();
  private attempts: Map<string, number> = new Map<string, number>();

  // ------------------------------- queries --------------------------------

  effectiveUnread(articleId: string, dbUnread: boolean): boolean {
    const diff: ReadDiff | undefined = this.readDiffs.get(articleId);
    return diff === undefined ? dbUnread : diff.unread;
  }

  effectiveStarred(articleId: string, dbStarred: boolean): boolean {
    const diff: StarDiff | undefined = this.starDiffs.get(articleId);
    return diff === undefined ? dbStarred : diff.starred;
  }

  /** Read-only access to a diff, used when handing a committed change over to
   *  the independent server-retry queue (see ReadStatusStore). */
  readDiffOf(id: string): ReadDiff | undefined {
    return this.readDiffs.get(id);
  }

  starDiffOf(id: string): StarDiff | undefined {
    return this.starDiffs.get(id);
  }

  hasRead(id: string): boolean {
    return this.readDiffs.has(id);
  }

  hasStar(id: string): boolean {
    return this.starDiffs.has(id);
  }

  /** Count delta to add to a DB count: +1 locally-unread-but-DB-read,
   *  -1 locally-read-but-DB-unread. Scoped by feedId/groupId when provided. */
  unreadDelta(feedId: string, groupId: string, global: boolean): number {
    let delta: number = 0;
    this.readDiffs.forEach((diff: ReadDiff): void => {
      if (!global && feedId.length > 0 && diff.feedId !== feedId) {
        return;
      }
      if (!global && feedId.length === 0 && groupId.length > 0 && diff.groupId !== groupId) {
        return;
      }
      delta += diff.unread ? 1 : -1;
    });
    return delta;
  }

  starredDelta(feedId: string): number {
    let delta: number = 0;
    this.starDiffs.forEach((diff: StarDiff): void => {
      if (feedId.length > 0 && diff.feedId !== feedId) {
        return;
      }
      delta += diff.starred ? 1 : -1;
    });
    return delta;
  }

  readCount(): number {
    return this.readDiffs.size;
  }

  starCount(): number {
    return this.starDiffs.size;
  }

  forEachRead(cb: (diff: ReadDiff, id: string) => void): void {
    this.readDiffs.forEach(cb);
  }

  forEachStar(cb: (diff: StarDiff, id: string) => void): void {
    this.starDiffs.forEach(cb);
  }

  /** Partition read diffs into ids to mark read / unread on flush. */
  readIdsByState(): ReadIdPartition {
    const readIds: string[] = [];
    const unreadIds: string[] = [];
    this.readDiffs.forEach((diff: ReadDiff, id: string): void => {
      if (diff.unread) {
        unreadIds.push(id);
      } else {
        readIds.push(id);
      }
    });
    return { readIds: readIds, unreadIds: unreadIds };
  }

  starIdsByState(): StarIdPartition {
    const starredIds: string[] = [];
    const unstarredIds: string[] = [];
    this.starDiffs.forEach((diff: StarDiff, id: string): void => {
      if (diff.starred) {
        starredIds.push(id);
      } else {
        unstarredIds.push(id);
      }
    });
    return { starredIds: starredIds, unstarredIds: unstarredIds };
  }

  allIds(): string[] {
    const ids: string[] = [];
    this.readDiffs.forEach((_d: ReadDiff, id: string): void => { ids.push(id); });
    this.starDiffs.forEach((_s: StarDiff, id: string): void => {
      if (ids.indexOf(id) < 0) {
        ids.push(id);
      }
    });
    return ids;
  }

  // ------------------------------- mutations ------------------------------

  /** Returns true when a diff was added/changed (caller schedules side effects). */
  markRead(id: string, unread: boolean, currentUnread: boolean, feedId: string, groupId: string): boolean {
    const baseline: boolean = this.readDiffs.has(id)
      ? !this.readDiffs.get(id)!.unread
      : currentUnread;
    if (unread === baseline) {
      this.readDiffs.delete(id);
      this.attempts.delete(id);
      return false;
    }
    this.readDiffs.set(id, { unread: unread, feedId: feedId, groupId: groupId });
    return true;
  }

  markStarred(id: string, starred: boolean, currentStarred: boolean, feedId: string): boolean {
    const baseline: boolean = this.starDiffs.has(id)
      ? !this.starDiffs.get(id)!.starred
      : currentStarred;
    if (starred === baseline) {
      this.starDiffs.delete(id);
      this.attempts.delete(id);
      return false;
    }
    this.starDiffs.set(id, { starred: starred, feedId: feedId });
    return true;
  }

  /** Load a diff directly (used when restoring from cache). */
  setReadDiff(id: string, diff: ReadDiff): void {
    this.readDiffs.set(id, diff);
  }

  setStarDiff(id: string, diff: StarDiff): void {
    this.starDiffs.set(id, diff);
  }

  /** Remove an id after server confirmation or give-up. Returns the diff that
   *  was removed (for persistence), or undefined if absent. */
  clear(id: string): void {
    this.readDiffs.delete(id);
    this.starDiffs.delete(id);
    this.attempts.delete(id);
  }

  /** Remove only the read diff for an id, leaving a pending star diff intact. */
  clearRead(id: string): void {
    this.readDiffs.delete(id);
  }

  /** Remove only the star diff for an id, leaving a pending read diff intact. */
  clearStar(id: string): void {
    this.starDiffs.delete(id);
  }

  /** Bump attempt count; returns the new count, or -1 if the id was dropped. */
  fail(id: string, maxAttempts: number): number {
    const next: number = (this.attempts.get(id) ?? 0) + 1;
    if (next >= maxAttempts) {
      this.clear(id);
      return -1;
    }
    this.attempts.set(id, next);
    return next;
  }

  attemptOf(id: string): number {
    return this.attempts.get(id) ?? 0;
  }

  /** Resolve ids against a confirmed set; returns the highest new attempt. */
  resolve(ids: string[], done: string[], maxAttempts: number): number {
    const ok: Set<string> = new Set<string>(done);
    let highest: number = 0;
    for (const id of ids) {
      if (ok.has(id)) {
        this.clear(id);
      } else {
        const attempt: number = this.fail(id, maxAttempts);
        if (attempt > highest) {
          highest = attempt;
        }
      }
    }
    return highest;
  }
}
