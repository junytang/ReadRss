import { common } from '@kit.AbilityKit';
import { Article, Feed, FeedGroup, filterFeedsByDrawer } from '../model/Models';
import { rssRepository } from '../rss/RssRepository';
import { fullContentPrefetcher } from '../rss/FullContentPrefetcher';
import { Logger } from '../common/Logger';
import { settingsStore } from '../data/SettingsStore';
import { readStatusBatcher } from '../rss/ReadStatusBatcher';
import { goBack, openArticle, openSettings } from '../common/NavigationService';
import { FILTER_ALL, FILTER_STARRED, FILTER_UNREAD } from '../common/Constants';
import { FilterBarView } from './FilterBarView';
import { FontManager } from '../common/FontManager';
import { FeedIcon } from '../common/FeedIcon';
import { accountRepository } from '../account/AccountRepository';
import { accountTypeShortName } from '../account/AccountModels';

/** Offscreen distance (vp) used by the filter/feed slide transition. */
const DISTANCE: number = 1000;
/** Slide duration (ms). Shared by the animation and its cleanup timer so the
 *  snapshot is never removed before the animation actually finishes. */
const SLIDE_DURATION: number = 200;
/** Full initial dataset, loaded in a deferred second batch. */
const FULL_PAGE_SIZE: number = 500;
/** Rows added per chunk of the deferred batch, to avoid one long build frame. */
const EXPAND_CHUNK: number = 100;
/** Rows added per loadMore page when scrolling past the expanded batch. */
const LOAD_MORE_STEP: number = 200;

/** Article list for one feed (or all feeds when feedId is empty). */
@Component
export struct ArticleListView {
  @Prop feedId: string = '';
  @Prop feedTitle: string = '全部文章';
  @Prop isRoot: boolean = false;
  onOpenFeeds: () => void = () => {};
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  // Fallback only; the real value is read directly from AppStorage. Keeping this
  // as @StorageProp would create the key with 800 and overwrite the real height
  // published by EntryAbility.
  private windowHeightVp: number = 800;
  @StorageProp('fontScale') @Watch('onFontSizeChanged') fontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.fontScale; }
  @StorageProp('articleTitleFontSize') articleTitleFontSize: number = 17;
  @StorageProp('articleSummaryFontSize') articleSummaryFontSize: number = 15;
  @StorageProp('articleMetaFontSize') articleMetaFontSize: number = 13;
  @StorageProp('articleFontFamily') articleFontFamily: string = 'sans-serif';
  @StorageProp('readStatusTick') @Watch('onReadStatusChanged') readStatusTick: number = 0;
  @StorageProp('readStatusFlushedTick') @Watch('onReadStatusFlushed') readStatusFlushedTick: number = 0;
  @StorageProp('feedIconTick') @Watch('onFeedIconChanged') feedIconTick: number = 0;
  @StorageProp('accountSwitchTick') @Watch('onAccountSwitched') accountSwitchTick: number = 0;
  @StorageProp('feedDataTick') @Watch('onSyncBatch') syncBatchTick: number = 0;
  @StorageProp('syncFirstBatchTick') @Watch('onSyncFirstBatch') firstBatchTick: number = 0;
  @StorageProp('syncFinishedTick') @Watch('onSyncFinished') syncFinishedTick: number = 0;
  @StorageLink('currentFilter') currentFilter: string = FILTER_UNREAD;

  @State articles: Article[] = [];
  @State feeds: Feed[] = [];
  // Full, unfiltered feed list used only for article icon lookup. `feeds` is
  // filtered by "only unread feeds" for the drawer, which can drop a source
  // and make its articles lose their icon after marking read.
  @State iconFeeds: Feed[] = [];
  // feedId -> normalized icon src, rebuilt only when the feed list changes.
  // Avoids a linear scan on every article row render.
  private iconSrcMap: Map<string, string> = new Map();
  @State groups: FeedGroup[] = [];
  @State currentFeedId: string = '';
  @State currentGroupId: string = '';
  @State showFeedDrawer: boolean = false;
  @State isRefreshing: boolean = false;
  @State isSyncing: boolean = false;
  @State searchText: string = '';
  @State firstVisibleIndex: number = 0;
  private visibleCount: number = 0;
  private lastMarkedIndex: number = 0;
  private scrollMarksPending: boolean = false;
  private lastPrefetchIndex: number = 0;
  private loadSeq: number = 0;
  private displayLimit: number = 500;
  private isLoadingMore: boolean = false;
  private pageLoadSeq: number = 0;
  // True while more rows may exist beyond the currently loaded prefix.
  private hasMore: boolean = true;
  // Unread rows optimistically marked read in the CURRENT scope but not yet
  // written to the DB by the batcher. Used to correct DB-based count re-reads.
  private scopeUnreadDelta: number = 0;
  @State markReadOnScroll: boolean = false;
  @State unreadCount: number = 0;
  @State starredCount: number = 0;
  @State allCount: number = 0;
  // Global totals (all sources) for the drawer top row, independent of the
  // currently selected feed/group.
  @State globalUnread: number = 0;
  @State globalStarred: number = 0;
  @State globalAll: number = 0;
  @State showMarkAllConfirm: boolean = false;
  // Slide transition between filter/feed contexts: the previous list slides out
  // while the new one slides in from the opposite edge.
  @State prevArticles: Article[] = [];
  @State curOffset: number = 0;
  @State prevOffset: number = 0;
  @State prevTopSpacer: number = 0; // height of rows scrolled above the snapshot
  private scrollOffset: number = 0;
  // Target offsets frozen at prepareSlide time so a late replayed onChange
  // cannot reverse the direction mid-transition.
  private targetCurOffset: number = 0;
  private targetPrevOffset: number = 0;
  // Direction source that only ever changes inside onFilterChange. It is not
  // tied to AppStorage propagation, so it cannot desync from the visible tab.
  private selectedFilterIndex: number = 0;
  private slideTimer: number = 0;
  private slideAnimating: boolean = false;
  // Deferred second batch: fill the rest of the list after the first paint.
  private expandTimer: number = 0;
  @State showSearch: boolean = false;
  @State accountName: string = '';
  @State accountTypeLabel: string = '';
  @State showArticleMenu: boolean = false;
  @State menuArticleId: string = '';
  @State menuArticleRead: boolean = false;
  @State menuArticleStarred: boolean = false;
  @State menuArticleTime: number = 0;

  private surfaceColor(): string {
    return this.darkMode ? '#1F2226' : '#FFFFFF';
  }

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  onReadStatusChanged(): void {
    // Keep the row in the list (gray) instead of reloading, which would remove
    // it from the unread filter immediately after returning from the reader.
    const change: string = AppStorage.get<string>('lastChangedArticle') ?? '';
    const parts: string[] = change.split('|');
    if (parts.length === 3) {
      const articleId: string = parts[0];
      const field: string = parts[1];
      const value: boolean = parts[2] === 'true';
      for (let i = 0; i < this.articles.length; i++) {
        if (this.articles[i].id === articleId) {
          const current: Article = this.articles[i];
          this.articles[i] = {
            id: current.id,
            feedId: current.feedId,
            feedTitle: current.feedTitle,
            title: current.title,
            author: current.author,
            link: current.link,
            summary: current.summary,
            content: current.content,
            fullContent: current.fullContent,
            imageUrl: current.imageUrl,
            publishedAt: current.publishedAt,
            isRead: field === 'read' ? value : current.isRead,
            isStarred: field === 'starred' ? value : current.isStarred,
          };
          this.articles = this.articles.slice();
          break;
        }
      }
    }
    // Counts and the drawer's unread badges still come from the database.
    this.refreshFeeds();
    // Reading a article marks it read in the DB; refresh the subscription banner
    // so its unread total reflects the change too.
    this.notifyBannerTick();
  }

  private async refreshCounts(): Promise<void> {
    // Subtract the not-yet-persisted optimistic marks so a DB re-read never
    // jumps back to the stale (higher) unread value while the batcher is pending.
    const globalDelta: number = AppStorage.get<number>('optimisticUnreadDelta') ?? 0;
    const scoped: number = await rssRepository.unreadCount(this.currentFeedId, this.currentGroupId);
    this.unreadCount = Math.max(0, scoped - this.scopeUnreadDelta);
    this.starredCount = await rssRepository.articleCount(FILTER_STARRED, this.currentFeedId, this.currentGroupId);
    this.allCount = await rssRepository.articleCount(FILTER_ALL, this.currentFeedId, this.currentGroupId);
    // Global totals for the drawer top row, never scoped by feed/group.
    const global: number = await rssRepository.unreadCount();
    this.globalUnread = Math.max(0, global - globalDelta);
    this.globalStarred = await rssRepository.articleCount(FILTER_STARRED);
    this.globalAll = await rssRepository.articleCount(FILTER_ALL);
  }

  /** First batch size: roughly two screens of rows, adapted to the device.
   *  Once the list has rendered we use the real measured visible-row count,
   *  which automatically accounts for screen height, font scale, orientation
   *  and split view. Before the first render we fall back to an estimate. */
  private firstPageSize(): number {
    const stored: number | undefined = AppStorage.get<number>('windowHeightVp');
    const winH: number = stored !== undefined && stored > 0 ? stored : this.windowHeightVp;
    const chrome: number = this.topInset + this.bottomInset + 160;
    const usable: number = Math.max(240, winH - chrome);
    const estimatedRows: number = Math.max(5, Math.floor(usable / (120 * this.fontScale)));
    const perScreen: number = this.visibleCount > 0 ? this.visibleCount : estimatedRows;
    return Math.min(80, Math.max(20, perScreen * 2));
  }

  /** Begin a slide transition: snapshot old rows on top, covering the list. */
  private prepareSlide(direction: number): void {
    // Even when the current list is empty we still run the transition: the new
    // list slides in from the correct edge, there is just no outgoing snapshot.
    // Freeze the direction into concrete offsets now. A later replayed onChange
    // must not be able to change these.
    this.targetCurOffset = 0;
    this.targetPrevOffset = direction > 0 ? -DISTANCE : DISTANCE;
    // Snapshot only the visible rows (+ a small buffer), not all 500. Rows
    // scrolled above the viewport are represented by a single spacer so the
    // outgoing frame still matches what the user was looking at.
    const start: number = this.firstVisibleIndex;
    const end: number = Math.min(
      this.articles.length,
      start + this.visibleCount + 2
    );
    this.prevArticles = this.articles.slice(start, end);
    this.prevTopSpacer = this.scrollOffset > 0 ? this.scrollOffset : 0;
    this.slideAnimating = true;
    this.prevOffset = 0;
    // New list starts offscreen on the opposite side; it animates in with the
    // new content once loading completes.
    this.curOffset = direction > 0 ? DISTANCE : -DISTANCE;
  }

  /** Slide old rows out and new rows in using the offsets frozen at prepare. */
  private finishSlide(): void {
    if (!this.slideAnimating) {
      return;
    }
    this.slideAnimating = false;
    this.getUIContext().animateTo({ duration: SLIDE_DURATION, curve: Curve.EaseOut }, () => {
      this.curOffset = this.targetCurOffset;
      this.prevOffset = this.targetPrevOffset;
    });
    if (this.slideTimer !== 0) {
      clearTimeout(this.slideTimer);
    }
    this.slideTimer = setTimeout(() => {
      this.prevArticles = [];
      this.prevOffset = 0;
    }, SLIDE_DURATION);
  }

  /** Notify the subscription page to refresh its banner totals after a mark. */
  private notifyBannerTick(): void {
    AppStorage.setOrCreate<number>('bannerTick', Date.now());
  }

  /** Refresh the drawer's per-feed unread badges and global totals after a
   *  read/star change, so both the per-source badges and the top banner count
   *  stay in sync with the database. */
  private async refreshFeeds(): Promise<void> {
    const allFeeds: Feed[] = await rssRepository.listFeeds();
    this.iconFeeds = allFeeds;
    this.rebuildIconMap();
    this.feeds = filterFeedsByDrawer(allFeeds, this.currentFilter);
    const allGroups: FeedGroup[] = await rssRepository.listGroups();
    this.groups = allGroups.filter((group: FeedGroup) =>
      this.feeds.some((feed: Feed) => feed.groupId === group.id)
    );
    // Global totals drive the drawer's top "全部/未读/星标" row.
    await this.refreshCounts();
  }

  onFeedIconChanged(): void {
    this.rebuildIconMap();
    this.articles = this.articles.slice();
    this.feeds = this.feeds.slice();
    this.iconFeeds = this.iconFeeds.slice();
  }

  /** First content batch landed: stop the spinner AND reload the list so the
   *  new articles appear at once (the batch is already committed). The "同步完成"
   *  toast still comes at sync end; later batches only refresh counts/badges. */
  onSyncFirstBatch(): void {
    if (this.isSyncing) {
      this.isRefreshing = false;
    }
    // Reload now with the first batch committed, preserving paging depth. Without
    // this the list would keep showing stale data until onSyncFinished, so the UI
    // would jump only when the final toast appears.
    this.load(false, true);
  }

  /** A full sync finished. Reload the article list with everything committed so
   *  far, preserving paging depth (covers first-install sync from EntryAbility). */
  onSyncFinished(): void {
    this.load(false, true);
    // A page-level pull refresh (isSyncing=true) shows its own toast; this covers
    // syncs started elsewhere (first install / launch sync from EntryAbility).
    if (!this.isSyncing) {
      this.getUIContext().getPromptAction().showToast({ message: '同步完成' });
    }
  }

  /** A sync batch was committed: refresh unread counts/badges live. The list
   *  itself is reloaded once by onSyncFirstBatch and again by onSyncFinished;
   *  reloading on every batch would interrupt reading. */
  onSyncBatch(): void {
    this.refreshFeeds();
  }

  onAccountSwitched(): void {
    this.loadAccount();
    this.load();
  }

  private async loadAccount(): Promise<void> {
    const account = await accountRepository.active();
    if (account) {
      // Prefer the user-entered display name; fall back to the username when
      // no name was provided.
      let name: string = account.name;
      if (name.length === 0) {
        const credentials = accountRepository.credentials(account);
        name = credentials.username;
      }
      this.accountName = name;
      this.accountTypeLabel = accountTypeShortName(account.type);
    }
  }

  aboutToAppear(): void {
    this.currentFeedId = this.feedId;
    this.markReadOnScroll = settingsStore.get().markReadOnScroll;
    this.loadAccount();
    this.load();
  }

  aboutToDisappear(): void {
    this.flushScrollMarks();
    readStatusBatcher.flush();
  }

  private readColor(): string {
    return this.darkMode ? '#6B7076' : '#9AA0A6';
  }

  /** Mark rows above the visible range as read; commit is batched by ReadStatusBatcher. */
  private markScrolledArticles(start: number): void {
    if (!this.markReadOnScroll || start <= this.lastMarkedIndex) {
      return;
    }
    let markedCount: number = 0;
    for (let i = this.lastMarkedIndex; i < start && i < this.articles.length; i++) {
      const article: Article = this.articles[i];
      if (!article.isRead) {
        // Mutate in place during scrolling. Do NOT slice here: replacing the
        // whole @State array on every index change forces ForEach to rebuild
        // all 500 rows and causes visible stutter. We defer the single slice
        // until scrolling settles (flushScrollMarks).
        this.articles[i] = ArticleListView.withReadState(article, true);
        readStatusBatcher.add(article.id);
        markedCount++;
      }
    }
    this.lastMarkedIndex = start;
    if (markedCount > 0) {
      this.scrollMarksPending = true;
      // Optimistic local updates only. The batcher writes to the DB 10s later;
      // re-reading from the DB now would return the stale (unread) counts and
      // make the number jump back. Keep the local value until the flush tick.
      this.scopeUnreadDelta += markedCount;
      this.optimisticUnreadChange(-markedCount);
      Logger.info(`Marked ${markedCount} articles read on scroll`);
    }
  }

  /** Apply an optimistic unread-count change across every view that shows it:
   *  this page's scoped+global counts, and the subscription page's banner via a
   *  shared delta. `delta` is the change in unread count (negative = marked read).
   *  The DB write that follows will re-read authoritative values via refreshFeeds. */
  private optimisticUnreadChange(delta: number): void {
    this.unreadCount = Math.max(0, this.unreadCount + delta);
    this.globalUnread = Math.max(0, this.globalUnread + delta);
    // optimisticUnreadDelta counts rows marked read but not yet in the DB. A
    // negative unread delta (marked read) increases it.
    const prev: number = AppStorage.get<number>('optimisticUnreadDelta') ?? 0;
    AppStorage.setOrCreate<number>('optimisticUnreadDelta', prev - delta);
    AppStorage.setOrCreate<number>('bannerTick', Date.now());
  }

  /** Undo the optimistic delta contribution of a completed/failed mark, without
   *  clearing deltas belonging to other pending marks (e.g. scroll batching). */
  private decrementOptimisticDelta(unreadDelta: number): void {
    const prev: number = AppStorage.get<number>('optimisticUnreadDelta') ?? 0;
    AppStorage.setOrCreate<number>('optimisticUnreadDelta', Math.max(0, prev + unreadDelta));
  }

  /** Apply deferred visual updates once, after scrolling stops. Do not re-read
   *  counts from the DB here — the batcher has not flushed yet. */
  private flushScrollMarks(): void {
    if (this.scrollMarksPending) {
      this.scrollMarksPending = false;
      this.articles = this.articles.slice();
    }
  }

  /** The batcher has written to the DB: now counting is safe and authoritative. */
  private onReadStatusFlushed(): void {
    // Clear the pending deltas BEFORE re-reading so refreshCounts sees the real
    // DB values (no double subtraction).
    this.scopeUnreadDelta = 0;
    AppStorage.setOrCreate<number>('optimisticUnreadDelta', 0);
    if (this.articles.length > 0) {
      this.refreshCounts();
      this.refreshFeeds();
    }
    AppStorage.setOrCreate<number>('bannerTick', Date.now());
  }

  /** Create a fresh instance so ForEach detects the change (ArkTS has no object spread). */
  private static withReadState(article: Article, isRead: boolean): Article {
    return {
      id: article.id,
      feedId: article.feedId,
      feedTitle: article.feedTitle,
      title: article.title,
      author: article.author,
      link: article.link,
      summary: article.summary,
      content: article.content,
      fullContent: article.fullContent,
      imageUrl: article.imageUrl,
      publishedAt: article.publishedAt,
      isRead: isRead,
      isStarred: article.isStarred,
    };
  }

  private static withStarredState(article: Article, isStarred: boolean): Article {
    return {
      id: article.id,
      feedId: article.feedId,
      feedTitle: article.feedTitle,
      title: article.title,
      author: article.author,
      link: article.link,
      summary: article.summary,
      content: article.content,
      fullContent: article.fullContent,
      imageUrl: article.imageUrl,
      publishedAt: article.publishedAt,
      isRead: article.isRead,
      isStarred: isStarred,
    };
  }

  /** Optimistic UI update: change rows first, persist in the background. */
  private setLocalRead(ids: string[], read: boolean): void {
    const next: Article[] = [];
    for (const article of this.articles) {
      next.push(ids.indexOf(article.id) >= 0
        ? ArticleListView.withReadState(article, read) : article);
    }
    this.articles = next;
  }

  private setLocalStarred(id: string, starred: boolean): void {
    const next: Article[] = [];
    for (const article of this.articles) {
      next.push(article.id === id
        ? ArticleListView.withStarredState(article, starred) : article);
    }
    this.articles = next;
  }

  private async load(resetPaging: boolean = true, fromSync: boolean = false): Promise<void> {
    // During a sync the DB is being written batch by batch. An externally
    // triggered load would read an intermediate state and reset paging/scroll
    // markers, so ignore it. The sync's own refreshes pass fromSync=true.
    if (this.isSyncing && !fromSync) {
      // A slide was prepared for this load; cancel it so the list is not stuck
      // offscreen.
      if (this.slideAnimating) {
        this.slideAnimating = false;
        this.prevArticles = [];
        this.curOffset = 0;
        this.prevOffset = 0;
      }
      return;
    }
    // Discard results from an older load: selecting a feed then tapping a filter
    // tab can start two overlapping loads whose DB queries resolve out of order.
    const seq: number = ++this.loadSeq;
    // Invalidate any in-flight loadMore so it cannot append stale rows after us.
    this.pageLoadSeq++;
    // Reset to the first page only on a genuine context switch (filter/feed/search).
    // A sync-completed refresh passes false to preserve how deep the user scrolled.
    if (resetPaging) {
      this.displayLimit = this.firstPageSize();
      // A scope switch invalidates the old scope's pending scroll marks.
      this.scopeUnreadDelta = 0;
    }
    this.markReadOnScroll = settingsStore.get().markReadOnScroll;
    const allFeeds: Feed[] = await rssRepository.listFeeds();
    if (seq !== this.loadSeq) return;
    this.iconFeeds = allFeeds;
    this.rebuildIconMap();
    this.feeds = filterFeedsByDrawer(allFeeds, this.currentFilter);
    const allGroups: FeedGroup[] = await rssRepository.listGroups();
    if (seq !== this.loadSeq) return;
    this.groups = allGroups.filter((group: FeedGroup) =>
      this.feeds.some((feed: Feed) => feed.groupId === group.id)
    );
    FeedIcon.prefetch(this.getUIContext().getHostContext() as common.Context, this.feeds);
    const articles: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, this.displayLimit,
      this.currentGroupId, false, this.searchText, true
    );
    if (seq !== this.loadSeq) return;
    this.articles = articles;
    this.hasMore = articles.length >= this.displayLimit;
    this.finishSlide();
    this.scheduleExpand(seq);
    this.lastMarkedIndex = 0;
    this.lastPrefetchIndex = 0;
    this.scrollMarksPending = false;
    const unread: number = await rssRepository.unreadCount(this.currentFeedId, this.currentGroupId);
    if (seq !== this.loadSeq) return;
    this.unreadCount = unread;
    const starred: number = await rssRepository.articleCount(FILTER_STARRED, this.currentFeedId, this.currentGroupId);
    if (seq !== this.loadSeq) return;
    this.starredCount = starred;
    const all: number = await rssRepository.articleCount(FILTER_ALL, this.currentFeedId, this.currentGroupId);
    if (seq !== this.loadSeq) return;
    this.allCount = all;
    // Drawer global totals, never scoped by the selected feed/group.
    this.globalUnread = await rssRepository.unreadCount();
    this.globalStarred = await rssRepository.articleCount(FILTER_STARRED);
    this.globalAll = await rssRepository.articleCount(FILTER_ALL);
    fullContentPrefetcher.ensureWindow(
      this.articles, this.firstVisibleIndex, this.visibleCount
    );
  }

  /** Filter-tab switch: only the article list changes. Skip the feed/group/count
   *  queries and the icon prefetch, which are unaffected by the filter. */
  private async reloadForFilterSwitch(): Promise<void> {
    const seq: number = ++this.loadSeq;
    this.pageLoadSeq++;
    this.displayLimit = this.firstPageSize();
    this.scopeUnreadDelta = 0;
    this.feeds = filterFeedsByDrawer(this.iconFeeds, this.currentFilter);
    const articles: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, this.displayLimit,
      this.currentGroupId, false, this.searchText, true
    );
    if (seq !== this.loadSeq) return;
    this.articles = articles;
    this.hasMore = articles.length >= this.displayLimit;
    this.lastMarkedIndex = 0;
    this.lastPrefetchIndex = 0;
    this.scrollMarksPending = false;
    this.finishSlide();
    fullContentPrefetcher.ensureWindow(this.articles, this.firstVisibleIndex, this.visibleCount);
    this.scheduleExpand(seq);
  }

  /** Load the remaining (up to FULL_PAGE_SIZE) lightweight rows after the first
   *  batch has painted and the slide finished. Keeps the tab switch snappy. */
  private scheduleExpand(seq: number): void {
    if (this.displayLimit >= FULL_PAGE_SIZE) {
      return;
    }
    if (this.expandTimer !== 0) {
      clearTimeout(this.expandTimer);
      this.expandTimer = 0;
    }
    this.expandTimer = setTimeout(() => {
      this.expandTimer = 0;
      this.expandToFullPage(seq);
    }, SLIDE_DURATION + 20);
  }

  /** Append rows from the DB up to `targetLimit`, keeping existing rows so the
   *  list identity and scroll position stay intact. Rows are deduplicated by id
   *  instead of assuming `articles` is a strict prefix of the query result —
   *  under the unread/starred filters, marking a row read/starred removes it from
   *  the query while the optimistic (grayed-out) row stays in the list, so the
   *  two prefixes diverge. Returns true if any genuinely new row was appended. */
  private async fetchAppend(targetLimit: number, seq: number, pageSeq: number): Promise<boolean> {
    const rows: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, targetLimit,
      this.currentGroupId, false, this.searchText, true
    );
    if (seq !== this.loadSeq || pageSeq !== this.pageLoadSeq) {
      return false;
    }
    // Fewer rows than requested means the data source is exhausted.
    this.hasMore = rows.length >= targetLimit;
    const known: Set<string> = new Set<string>();
    for (const article of this.articles) {
      known.add(article.id);
    }
    const fresh: Article[] = [];
    for (const row of rows) {
      if (!known.has(row.id)) {
        known.add(row.id);
        fresh.push(row);
      }
    }
    if (fresh.length > 0) {
      this.articles = this.articles.concat(fresh);
    }
    this.displayLimit = targetLimit;
    return fresh.length > 0;
  }

  private async expandToFullPage(seq: number): Promise<void> {
    if (seq !== this.loadSeq || this.displayLimit >= FULL_PAGE_SIZE || this.isLoadingMore) {
      return;
    }
    const pageSeq: number = this.pageLoadSeq;
    while (this.displayLimit < FULL_PAGE_SIZE && this.hasMore) {
      if (seq !== this.loadSeq || pageSeq !== this.pageLoadSeq || this.isLoadingMore) {
        return;
      }
      const target: number = Math.min(this.displayLimit + EXPAND_CHUNK, FULL_PAGE_SIZE);
      const appended: boolean = await this.fetchAppend(target, seq, pageSeq);
      if (!appended) {
        // No genuinely new rows: either data is exhausted (hasMore now false) or
        // a concurrent load invalidated this page. Stop expanding in both cases.
        break;
      }
      // Yield to the render loop so each chunk paints in its own frame.
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 16); });
    }
    fullContentPrefetcher.ensureWindow(this.articles, this.firstVisibleIndex, this.visibleCount);
  }

  /** Load the next page when scrolling reaches the end. Appends to keep the
   *  current scroll position and already-read markings intact. */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore) {
      return;
    }
    // While a sync is committing batches the DB holds an intermediate state;
    // loading another page now could mix partial rows into the list. Triggered
    // automatically by scrolling, so ignore silently (no toast) to avoid spam.
    if (this.isSyncing || !this.hasMore) {
      return;
    }
    const seq: number = this.loadSeq;
    this.isLoadingMore = true;
    const pageSeq: number = ++this.pageLoadSeq;
    try {
      const nextLimit: number = this.displayLimit + LOAD_MORE_STEP;
      await this.fetchAppend(nextLimit, seq, pageSeq);
    } catch (error) {
      Logger.error(`Load more failed: ${(error as Error).message}`);
    } finally {
      this.isLoadingMore = false;
    }
  }

  private titleText(): string {
    let base: string = this.feedTitle;
    // On the global page the base title follows the selected filter.
    if (this.feedId.length === 0) {
      if (this.currentFilter === FILTER_STARRED) {
        base = '星标文章';
      } else if (this.currentFilter === FILTER_ALL) {
        base = '全部文章';
      } else {
        base = '未读文章';
      }
    }
    if (this.currentFilter === FILTER_STARRED) {
      return `${base} (${this.starredCount})`;
    }
    if (this.currentFilter === FILTER_ALL) {
      return `${base} (${this.allCount})`;
    }
    return `${base} (${this.unreadCount})`;
  }

  private filterColor(value: string): string {
    return this.currentFilter === value ? '#2663D6' : this.secondaryColor();
  }

  private async sync(): Promise<void> {
    // Ignore duplicate pull while a sync is still committing batches; stop its
    // spinner and notify instead of silently returning.
    if (this.isSyncing) {
      this.isRefreshing = false;
      this.getUIContext().getPromptAction().showToast({ message: '正在同步中，请稍候' });
      return;
    }
    this.isSyncing = true;
    this.isRefreshing = true;
    try {
      await rssRepository.syncAll();
      // No load() here: syncAll emits syncFinishedTick internally, whose watcher
      // (onSyncFinished) already reloaded the list while preserving paging depth.
      this.getUIContext().getPromptAction().showToast({ message: '同步完成' });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `同步失败：${(error as Error).message}` });
    } finally {
      this.isSyncing = false;
      this.isRefreshing = false;
    }
  }

  private open(article: Article): void {
    // A long press that opens the menu can still be followed by a click event.
    if (this.showArticleMenu) {
      return;
    }
    openArticle(article.id);
  }

  private doMarkAllRead(): void {
    this.showMarkAllConfirm = false;
    const ids: string[] = [];
    for (const article of this.articles) {
      if (!article.isRead) {
        ids.push(article.id);
      }
    }
    const previousUnread: number = this.unreadCount;
    this.setLocalRead(ids, true);
    // Marking all currently-unread rows: unreadCount drops to zero in this scope.
    this.scopeUnreadDelta += previousUnread;
    this.optimisticUnreadChange(-previousUnread);
    rssRepository.markAllRead(this.currentFeedId, this.currentGroupId).then(() => {
      // DB is authoritative now; drop only this mark's optimistic contribution.
      if (this.scopeUnreadDelta >= previousUnread) { this.scopeUnreadDelta -= previousUnread; }
      this.decrementOptimisticDelta(-previousUnread);
      this.refreshFeeds();
      this.notifyBannerTick();
    }).catch((error: Error) => {
      this.setLocalRead(ids, false);
      if (this.scopeUnreadDelta >= previousUnread) { this.scopeUnreadDelta -= previousUnread; }
      this.decrementOptimisticDelta(-previousUnread);
      this.unreadCount = previousUnread;
      this.refreshCounts();
      this.notifyBannerTick();
      Logger.error(`Mark all read failed: ${error.message}`);
    });
  }

  private formatDate(timestamp: number): string {
    if (timestamp <= 0) {
      return '';
    }
    const date: Date = new Date(timestamp);
    const now: Date = new Date();
    const sameDay: boolean = date.getFullYear() === now.getFullYear() &&
      date.getMonth() === now.getMonth() &&
      date.getDate() === now.getDate();
    if (sameDay) {
      return `${date.getHours()}:${date.getMinutes().toString().padStart(2, '0')}`;
    }
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  @Builder
  swipeMark(article: Article): void {
    Row() {
      Button(article.isRead ? '标未读' : '标已读')
        .backgroundColor('#5E636A')
        .fontColor(Color.White)
        .onClick(() => {
          const read: boolean = !article.isRead;
          // UI first; the server is only asked to correct the state afterwards.
          this.setLocalRead([article.id], read);
          const delta: number = read ? -1 : 1;
          if (read) { this.scopeUnreadDelta += 1; }
          this.optimisticUnreadChange(delta);
          rssRepository.markRead(article.id, read).then(() => {
            if (read && this.scopeUnreadDelta > 0) { this.scopeUnreadDelta -= 1; }
            this.decrementOptimisticDelta(delta);
            this.refreshFeeds();
            this.notifyBannerTick();
          }).catch((error: Error) => {
            this.setLocalRead([article.id], !read);
            if (read && this.scopeUnreadDelta > 0) { this.scopeUnreadDelta -= 1; }
            this.decrementOptimisticDelta(delta);
            this.unreadCount = Math.max(0, this.unreadCount - delta);
            this.refreshCounts();
            this.notifyBannerTick();
            Logger.error(`Mark read failed: ${error.message}`);
          });
        })
    }
  }

  @Builder
  articleItem(article: Article): void {
    Row() {
      Column() {
        Text(article.title).fontFamily(this.listFont())
          .fontSize(this.articleTitleFontSize * this.fontScale)
          .fontWeight(article.isRead ? FontWeight.Normal : FontWeight.Medium)
          .fontColor(article.isRead ? this.readColor() : this.textColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (article.summary.length > 0) {
          Text(article.summary).fontFamily(this.listFont())
            .fontSize(this.articleSummaryFontSize * this.fontScale)
            .fontColor(article.isRead ? this.readColor() : this.secondaryColor())
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 * this.fontScale })
            .width('100%')
        }
        Row() {
          if (this.iconForFeed(article.feedId).length > 0) {
            Image(this.iconForFeed(article.feedId))
              .width(14)
              .height(14)
              .borderRadius(3)
              .syncLoad(true)
              .margin({ right: 4 })
          } else {
            Image($r('app.media.app_icon'))
              .width(14)
              .height(14)
              .borderRadius(3)
              .syncLoad(true)
              .margin({ right: 4 })
          }
          Text(article.feedTitle).fontFamily(this.listFont())
            .fontSize(this.articleMetaFontSize * this.fontScale)
            .fontColor(article.isRead ? this.readColor() : this.secondaryColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (article.isStarred) {
            Text('★').fontFamily(this.appFont()).fontSize(this.fs(12)).fontColor('#F9A825')
              .margin({ right: 6 })
          }
          Text(this.formatDate(article.publishedAt)).fontFamily(this.listFont())
            .fontSize(this.articleMetaFontSize * this.fontScale)
            .fontColor(article.isRead ? this.readColor() : this.secondaryColor())
        }
        .width('100%')
        .margin({ top: 6 * this.fontScale })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({
      left: 16, right: 16,
      top: 14 * this.fontScale, bottom: 14 * this.fontScale,
    })
    .backgroundColor(this.surfaceColor())
    .gesture(
      LongPressGesture().onAction(() => {
        this.menuArticleId = article.id;
        this.menuArticleRead = article.isRead;
        this.menuArticleStarred = article.isStarred;
        this.menuArticleTime = article.publishedAt;
        this.setArticleMenuVisible(true);
      })
    )
  }

  /** Android ArticleListReaderViewModel.markAsReadFromListByDate: newest first,
   *  so "above" means newer (date > current) and "below" means older. */
  private menuMarkByDate(above: boolean): void {
    const ids: string[] = [];
    for (const article of this.articles) {
      if (article.id === this.menuArticleId || article.isRead) {
        continue;
      }
      if (above ? article.publishedAt > this.menuArticleTime
                : article.publishedAt < this.menuArticleTime) {
        ids.push(article.id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    // Turn the rows gray immediately; the server only corrects state on failure.
    const previousUnread: number = this.unreadCount;
    this.setLocalRead(ids, true);
    this.scopeUnreadDelta += ids.length;
    this.optimisticUnreadChange(-ids.length);
    rssRepository.markReadBatch(ids, true).then(() => {
      if (this.scopeUnreadDelta >= ids.length) { this.scopeUnreadDelta -= ids.length; }
      this.decrementOptimisticDelta(-ids.length);
      this.refreshFeeds();
      this.notifyBannerTick();
    }).catch((error: Error) => {
      this.setLocalRead(ids, false);
      if (this.scopeUnreadDelta >= ids.length) { this.scopeUnreadDelta -= ids.length; }
      this.decrementOptimisticDelta(-ids.length);
      this.unreadCount = previousUnread;
      this.refreshCounts();
      this.notifyBannerTick();
      Logger.error(`Mark by date failed: ${error.message}`);
    });
  }

  private menuToggleRead(): void {
    const id: string = this.menuArticleId;
    const read: boolean = !this.menuArticleRead;
    this.setLocalRead([id], read);
    this.menuArticleRead = read;
    const delta: number = read ? -1 : 1;
    if (read) { this.scopeUnreadDelta += 1; }
    this.optimisticUnreadChange(delta);
    rssRepository.markRead(id, read).then(() => {
      if (read && this.scopeUnreadDelta > 0) { this.scopeUnreadDelta -= 1; }
      this.decrementOptimisticDelta(delta);
      this.refreshFeeds();
      this.notifyBannerTick();
    }).catch((error: Error) => {
      this.setLocalRead([id], !read);
      if (read && this.scopeUnreadDelta > 0) { this.scopeUnreadDelta -= 1; }
      this.decrementOptimisticDelta(delta);
      this.unreadCount = Math.max(0, this.unreadCount - delta);
      this.refreshCounts();
      this.notifyBannerTick();
      Logger.error(`Toggle read failed: ${error.message}`);
    });
  }

  private menuToggleStarred(): void {
    const id: string = this.menuArticleId;
    const starred: boolean = !this.menuArticleStarred;
    this.setLocalStarred(id, starred);
    this.menuArticleStarred = starred;
    this.starredCount = Math.max(0, this.starredCount + (starred ? 1 : -1));
    rssRepository.markStarred(id, starred).then(() => {
      // DB now has the new star state; re-read authoritative counts.
      this.refreshFeeds();
      this.notifyBannerTick();
    }).catch((error: Error) => {
      this.setLocalStarred(id, !starred);
      this.starredCount = Math.max(0, this.starredCount + (starred ? -1 : 1));
      this.refreshCounts();
      this.notifyBannerTick();
      Logger.error(`Toggle starred failed: ${error.message}`);
    });
  }

  private setArticleMenuVisible(visible: boolean): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.showArticleMenu = visible;
    });
  }

  @Builder
  searchBar(): void {
    TextInput({ placeholder: '搜索文章…', text: this.searchText })
      .id('searchInput')
      .onAppear(() => {
        this.getUIContext().getFocusController().requestFocus('searchInput');
      })
      .width('100%')
      .height(38)
      .fontSize(this.fs(14))
      .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
      .fontColor(this.textColor())
      .onChange((value: string) => {
        this.searchText = value;
        this.load();
      })
  }


  private rebuildIconMap(): void {
    this.iconSrcMap.clear();
    for (const feed of this.iconFeeds) {
      this.iconSrcMap.set(feed.id, FeedIcon.src(feed.iconUrl));
    }
  }

  private iconForFeed(feedId: string): string {
    const src: string | undefined = this.iconSrcMap.get(feedId);
    return src === undefined ? '' : src;
  }

  private feedsInGroup(groupId: string): Feed[] {
    return this.feeds.filter((feed: Feed) => feed.groupId === groupId);
  }

  private ungroupedFeeds(): Feed[] {
    const ids: string[] = this.groups.map((group: FeedGroup) => group.id);
    return this.feeds.filter((feed: Feed) => ids.indexOf(feed.groupId) < 0);
  }

  /** Selection keys in the exact order shown in the drawer: top banner first,
   *  then each group followed by its feeds, then ungrouped feeds. */
  private drawerOrder(): string[] {
    const order: string[] = ['__global__'];
    for (const group of this.groups) {
      order.push(`g:${group.id}`);
      for (const feed of this.feedsInGroup(group.id)) {
        order.push(`f:${feed.id}`);
      }
    }
    for (const feed of this.ungroupedFeeds()) {
      order.push(`f:${feed.id}`);
    }
    return order;
  }

  private currentSelectionKey(): string {
    if (this.currentGroupId.length > 0) {
      return `g:${this.currentGroupId}`;
    }
    if (this.currentFeedId.length > 0) {
      return `f:${this.currentFeedId}`;
    }
    return '__global__';
  }

  /** Below the current selection -> up (1); above or the top banner -> down (-1). */
  private drawerSlideDirection(key: string): number {
    const order: string[] = this.drawerOrder();
    const from: number = order.indexOf(this.currentSelectionKey());
    const to: number = order.indexOf(key);
    return to > from ? 1 : -1;
  }

  @Builder
  drawerGroupItem(group: FeedGroup): void {
    Row() {
      Text(group.name)
        .fontFamily(this.appFont())
        .fontSize(this.fs(13))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor())
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.currentFeedId.length === 0 && this.currentGroupId === group.id
      ? (this.darkMode ? '#3A4657' : '#E8F0FE')
      : Color.Transparent)
    .onClick(() => {
      const key: string = `g:${group.id}`;
      if (key !== this.currentSelectionKey()) {
        this.prepareSlide(this.drawerSlideDirection(key));
      }
      this.currentFeedId = '';
      this.currentGroupId = group.id;
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; });
      this.load();
    })
  }

  @Builder
  drawerFeedItem(feedId: string, title: string, unreadCount: number): void {
    Row() {
      if (feedId.length === 0) {
        // Top "全部/未读/星标" row uses the same icon as the HdsTabs tab.
        Image(this.filterIcon())
          .width(20)
          .height(20)
          .padding(3)
          .fillColor(this.darkMode ? '#E8EAED' : '#1A1C1E')
          .margin({ right: 8 })
      } else if (this.iconForFeed(feedId).length > 0) {
        Image(this.iconForFeed(feedId))
          .width(20)
          .height(20)
          .borderRadius(4)
          .margin({ right: 8 })
      } else {
        Image($r('app.media.app_icon'))
          .width(20)
          .height(20)
          .borderRadius(4)
          .margin({ right: 8 })
      }
      Text(title)
        .fontFamily(this.appFont())
        // Source rows use the base 15vp; the top all-articles row is +2vp.
        .fontSize((feedId.length === 0 ? 17 : 15) * this.fontScale)
        .fontColor(this.textColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (unreadCount > 0) {
        Text(`${unreadCount}`)
          .fontFamily(this.appFont())
          .fontSize(this.fs(12))
          .fontColor(this.darkMode ? '#E8EAED' : '#1A1C1E')
          .backgroundColor(this.darkMode ? '#3A3A3A' : '#E8E8E8')
          .borderRadius(10)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({
      left: feedId.length === 0 ? 16 : 28,
      right: 16,
      top: feedId.length === 0 ? 18 : 12,
      bottom: feedId.length === 0 ? 18 : 12,
    })
    .backgroundColor(
      (feedId.length === 0
        ? (this.currentFeedId.length === 0 && this.currentGroupId.length === 0)
        : this.currentFeedId === feedId)
        ? (this.darkMode ? '#3A4657' : '#E8F0FE')
        : Color.Transparent
    )
    .onClick(() => {
      const key: string = feedId.length === 0 ? '__global__' : `f:${feedId}`;
      if (key !== this.currentSelectionKey()) {
        this.prepareSlide(this.drawerSlideDirection(key));
      }
      this.currentFeedId = feedId;
      this.currentGroupId = '';
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; });
      this.load();
    })
  }

  /** Badge count follows the active filter: starred uses starredCount, others unread. */
  private drawerBadgeCount(feed: Feed): number {
    return this.currentFilter === FILTER_STARRED ? feed.starredCount : feed.unreadCount;
  }

  /** Total article count for the active filter (shown on the drawer "全部" row). */
  private drawerTotalCount(): number {
    if (this.currentFilter === FILTER_STARRED) return this.globalStarred;
    if (this.currentFilter === FILTER_ALL) return this.globalAll;
    return this.globalUnread;
  }

  private filterName(): string {
    if (this.currentFilter === FILTER_STARRED) return '星标';
    if (this.currentFilter === FILTER_ALL) return '全部';
    return '未读';
  }

  /** Same icons as the HdsTabs bottom bar, used for the drawer top row. */
  private filterIcon(): Resource {
    if (this.currentFilter === FILTER_STARRED) return $r('app.media.ic_filter_star');
    if (this.currentFilter === FILTER_ALL) return $r('app.media.ic_filter_all');
    return $r('app.media.ic_filter_unread');
  }

  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  private listFont(): string {
    // Font selection is per context; the tick also covers custom font installs.
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.articleFontFamily) : 'sans-serif';
  }

  /** Force the row list to rebuild when an article font size changes. */
  onFontSizeChanged(): void {
    if (this.articles.length > 0) {
      this.articles = this.articles.slice();
    }
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        Row() {
          if (this.isRoot) {
            Button() {
              Image($r('app.media.ic_feeds'))
                .width(19)
                .height(19)
                .fillColor('#1A1C1E')
            }
            .type(ButtonType.Circle)
            .width(38)
            .height(38)
            .backgroundColor(Color.White)
            .margin({ right: 8 })
            .onClick(() => { this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = true; }); })
          } else {
            Button() {
              Image($r('app.media.ic_back'))
                .width(19)
                .height(19)
                .fillColor('#1A1C1E')
            }
            .type(ButtonType.Circle)
            .width(38)
            .height(38)
            .backgroundColor(Color.White)
            .margin({ right: 8 })
            .onClick(() => goBack())
          }
          Text(this.titleText()).fontFamily(this.appFont())
            .fontSize(this.fs(19))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button() {
            Image($r('app.media.ic_settings'))
              .width(19)
              .height(19)
              .fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38)
          .height(38)
          .backgroundColor(Color.White)
          .margin({ left: 8 })
          .onClick(() => openSettings())

          Button() {
            Image($r('app.media.ic_search'))
              .width(19)
              .height(19)
              .fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38)
          .height(38)
          .backgroundColor(Color.White)
          .margin({ left: 8 })
          .onClick(() => { this.showSearch = !this.showSearch; })

          Button() {
            Image($r('app.media.ic_mark_read'))
              .width(19)
              .height(19)
              .fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38)
          .height(38)
          .backgroundColor(Color.White)
          .margin({ left: 8 })
          .onClick(() => { this.showMarkAllConfirm = true; })
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 14 })

        if (this.showSearch) {
          Column() {
            this.searchBar()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 10 })
        }

        Refresh({ refreshing: $$this.isRefreshing }) {
          Stack() {
            // Previous snapshot slides out; non-interactive during the transition.
            // Keep this List in the tree at all times (hide it with Visibility
            // when idle) — conditionally inserting it shifts the current list
            // from child 0 to child 1 and ArkUI's component reuse then mixes up
            // which translate binding belongs to which list.
            List() {
              if (this.prevTopSpacer > 0) {
                ListItem() {
                  Row().width('100%').height(this.prevTopSpacer)
                }
              }
              ForEach(this.prevArticles, (article: Article) => {
                ListItem() {
                  this.articleItem(article)
                }
              }, (article: Article) => `${article.id}`)
            }
            .visibility(this.prevArticles.length > 0 ? Visibility.Visible : Visibility.None)
            .width('100%')
            .height('100%')
            .translate({ y: this.prevOffset })
            .hitTestBehavior(HitTestMode.None)
            .divider({ strokeWidth: 1, color: this.darkMode ? '#2A2D31' : '#ECEFF2' })

            // Current list slides in from the opposite edge.
            List() {
              ForEach(this.articles, (article: Article) => {
                ListItem() {
                  this.articleItem(article)
                }
                .onClick(() => this.open(article))
                .swipeAction({
                  end: {
                    builder: () => { this.swipeMark(article); },
                  },
                })
              }, (article: Article) => `${article.id}-${article.isRead}-${article.isStarred}`)

              if (this.isRoot) {
                // Trailing spacer: the floating HdsTabs capsule sits ~64vp above
                // the bottom, so keep enough room for the last row to scroll fully
                // above it instead of being covered.
                ListItem() {
                  Row().width('100%').height(144)
                }
              }
            }
            .width('100%')
            .height('100%')
            .translate({ y: this.curOffset })
            .divider({ strokeWidth: 1, color: this.darkMode ? '#2A2D31' : '#ECEFF2' })
            .onReachEnd(() => { this.loadMore(); })
            .onScrollIndex((start: number, end: number) => {
              this.firstVisibleIndex = start;
              this.visibleCount = end >= start ? end - start + 1 : 0;
              if (start > 0 && this.showSearch) {
                this.showSearch = false;
              }
              // Throttle prefetch: only recompute the window after the visible
              // item moved a few rows, not on every index tick.
              if (Math.abs(start - this.lastPrefetchIndex) >= 3) {
                this.lastPrefetchIndex = start;
                fullContentPrefetcher.ensureWindow(this.articles, start, this.visibleCount);
              }
              this.markScrolledArticles(start);
            })
            // Flush the deferred row rebuilds when scrolling settles, so the
            // ForEach is rebuilt once instead of on every scroll frame.
            .onScroll((offset: number, scrollState: ScrollState) => {
              this.scrollOffset = offset;
              if (scrollState === ScrollState.Idle) {
                this.flushScrollMarks();
              }
            })
          }
          .width('100%')
          .height('100%')
          .clip(true)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => this.sync())

      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')

      if (this.isRoot) {
        FilterBarView({
          onFilterChange: (filter: string) => {
            // Switching the bottom filter keeps the current feed/group scope,
            // matching Android's changeFilter(filterState.copy(filter = it)).
            if (this.currentFilter === filter) {
              return;
            }
            const order: string[] = [FILTER_UNREAD, FILTER_STARRED, FILTER_ALL];
            const newIndex: number = order.indexOf(filter);
            const direction: number = newIndex > this.selectedFilterIndex ? 1 : -1;
            this.selectedFilterIndex = newIndex;
            this.currentFilter = filter;
            this.prepareSlide(direction);
            this.reloadForFilterSwitch();
          },
        })
      }

      if (this.showMarkAllConfirm) {
        Column() {
          Column() {
            Text('全部标记为已读').fontFamily(this.appFont())
              .fontSize(this.fs(18))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textColor())
            Text('确定将当前列表中的文章全部标记为已读吗？').fontFamily(this.appFont())
              .fontSize(this.fs(14))
              .fontColor(this.secondaryColor())
              .margin({ top: 12 })
            Row() {
              Text('取消').fontFamily(this.appFont())
                .fontSize(this.fs(15))
                .fontColor(this.secondaryColor())
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.showMarkAllConfirm = false; })
              Text('确定').fontFamily(this.appFont())
                .fontSize(this.fs(15))
                .fontColor('#2663D6')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .onClick(() => this.doMarkAllRead())
            }
            .width('100%')
            .margin({ top: 24 })
          }
          .width('85%')
          .padding(24)
          .borderRadius(12)
          .backgroundColor(this.surfaceColor())
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center)
        .zIndex(20)
      }

      if (this.showArticleMenu) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#99000000')
            .transition(TransitionEffect.OPACITY)
            .animation({ duration: 220, curve: Curve.EaseInOut })
            .onClick(() => { this.setArticleMenuVisible(false); })

          Column() {
            Row() {
              Image(this.menuArticleRead ? $r('app.media.ic_filter_unread') : $r('app.media.ic_mark_read'))
                .width(24).height(24).fillColor(this.textColor())
                .margin({ right: 12 })
              Text(this.menuArticleRead ? '标记为未读' : '标记为已读').fontFamily(this.appFont())
                .fontSize(this.fs(16)).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuToggleRead();
            })

            Row() {
              Image(this.menuArticleStarred ? $r('app.media.ic_star_outline') : $r('app.media.ic_filter_star'))
                .width(24).height(24)
                .fillColor(this.menuArticleStarred ? this.secondaryColor() : '#F9A825')
                .margin({ right: 12 })
              Text(this.menuArticleStarred ? '取消收藏' : '标记为收藏').fontFamily(this.appFont())
                .fontSize(this.fs(16)).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuToggleStarred();
            })

            Row() {
              Image($r('app.media.ic_arrow_up'))
                .width(24).height(24).fillColor(this.textColor())
                .margin({ right: 12 })
              Text('标记上面文章为已读').fontFamily(this.appFont())
                .fontSize(this.fs(16)).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuMarkByDate(true);
            })

            Row() {
              Image($r('app.media.ic_arrow_down'))
                .width(24).height(24).fillColor(this.textColor())
                .margin({ right: 12 })
              Text('标记下面文章为已读').fontFamily(this.appFont())
                .fontSize(this.fs(16)).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuMarkByDate(false);
            })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 4, bottom: 48 })
          .backgroundColor(this.surfaceColor())
          .borderRadius({ topLeft: 16, topRight: 16 })
          .transition(TransitionEffect.translate({ y: 240 }))
          .animation({ duration: 220, curve: Curve.EaseInOut })
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Bottom)
        .zIndex(40)
      }

      if (this.showFeedDrawer) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#99000000')
            .transition(TransitionEffect.OPACITY)
            .animation({ duration: 240, curve: Curve.EaseInOut })
            .onClick(() => { this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; }); })

          Column() {
            Row() {
              Column() {
                Text(this.accountName.length > 0 ? this.accountName : '订阅源')
                  .fontSize(this.fs(18))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.textColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.accountTypeLabel)
                  .fontFamily(this.appFont())
                  .fontSize(this.fs(12))
                  .fontColor(this.secondaryColor())
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('✕')
                .fontFamily(this.appFont())
                .fontSize(this.fs(18))
                .fontColor(this.secondaryColor())
                .onClick(() => { this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; }); })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 4 })

            List() {
              ListItem() {
                this.drawerFeedItem('', this.filterName(), this.drawerTotalCount())
              }

              // Blank row separating the "全部" summary from the source list.
              ListItem() {
                Row().width('100%').height(12)
              }

              if (this.feeds.length === 0) {
                ListItem() {
                  Text(this.currentFilter === FILTER_ALL ? '还没有订阅源' : '该筛选下没有订阅源')
                    .fontFamily(this.appFont())
                    .fontSize(this.fs(13))
                    .fontColor(this.secondaryColor())
                    .margin({ left: 16, top: 10 })
                }
              }

              ForEach(this.groups, (group: FeedGroup) => {
                ListItem() {
                  this.drawerGroupItem(group)
                }
                ForEach(this.feedsInGroup(group.id), (feed: Feed) => {
                  ListItem() {
                    this.drawerFeedItem(feed.id, feed.title, this.drawerBadgeCount(feed))
                  }
                }, (feed: Feed) => feed.id)
              }, (group: FeedGroup) => group.id)
              ForEach(this.ungroupedFeeds(), (feed: Feed) => {
                ListItem() {
                  this.drawerFeedItem(feed.id, feed.title, this.drawerBadgeCount(feed))
                }
              }, (feed: Feed) => feed.id)
            }
            .width('100%')
            .layoutWeight(1)
            // Padding on the List reserves space at the bottom even when
            // scrolled to the end, so the last source never sits on the edge.
            .padding({ bottom: 50 })
          }
          .width('66%')
          .height('100%')
          .backgroundColor(this.surfaceColor())
          .padding({ bottom: 16 })
          .transition(TransitionEffect.translate({ x: -240 }))
          .animation({ duration: 240, curve: Curve.EaseInOut })

        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Start)
        .zIndex(30)
      }
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .onShown(() => this.load())
  }
}
