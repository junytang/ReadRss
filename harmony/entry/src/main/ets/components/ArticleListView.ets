import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { Article, Feed, FeedGroup, filterFeedsByDrawer } from '../model/Models';
import { rssRepository } from '../rss/RssRepository';
import { ArticleCounts } from '../data/Database';
import { fullContentPrefetcher } from '../rss/FullContentPrefetcher';
import { ArticlePaging, AppendResult } from '../rss/ArticlePaging';
import { Logger } from '../common/Logger';
import { settingsStore } from '../data/SettingsStore';
import { readStatusStore } from '../rss/ReadStatusStore';
import { goBack, openArticle, openSettings } from '../common/NavigationService';
import {
  DESC_LONG, DESC_NONE, DESC_SHORT, FILTER_ALL, FILTER_STARRED, FILTER_UNREAD,
  SWIPE_NONE, SWIPE_TOGGLE_READ, SWIPE_TOGGLE_STARRED,
} from '../common/Constants';
import { FilterBarView } from './FilterBarView';
import { FontManager } from '../common/FontManager';
import { FeedIcon } from '../common/FeedIcon';
import { accountRepository } from '../account/AccountRepository';
import { accountTypeShortName } from '../account/AccountModels';
import { FeedListView } from './FeedListView';
import { ArticleRowView } from './ArticleRowView';

/** Offscreen distance (vp) used by the filter/feed slide transition. */
const DISTANCE: number = 1000;
/** Slide duration (ms). Shared by the animation and its cleanup timer so the
 *  snapshot is never removed before the animation actually finishes. */
const SLIDE_DURATION: number = 200;
/** Row count the deferred second batch fills to. Kept modest (Android pages
 *  on demand); scrolling past it triggers loadMore, so there is no need to
 *  eagerly materialize 500 ForEach rows and their component nodes. */
const FULL_PAGE_SIZE: number = 100;
/** Rows added per chunk of the deferred batch, to avoid one long build frame. */
const EXPAND_CHUNK: number = 100;
/** Rows added per loadMore page when scrolling past the expanded batch. */
const LOAD_MORE_STEP: number = 100;
/** Largest single scroll jump treated as genuine scrolling. Bigger jumps are
 *  stale offsets from a context switch and must not mass-mark articles read. */
const MAX_SCROLL_MARK_STEP: number = 30;

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
  // Article-list behavior settings (from Settings > Article List).
  @StorageProp('sortUnreadEarliest') sortUnreadEarliest: boolean = false;
  @StorageProp('swipeStartAction') swipeStartAction: number = SWIPE_TOGGLE_STARRED;
  @StorageProp('swipeEndAction') swipeEndAction: number = SWIPE_TOGGLE_READ;
  @StorageProp('showFeedIcon') showFeedIcon: boolean = true;
  @StorageProp('showFeedName') showFeedName: boolean = true;
  @StorageProp('showArticleImage') showArticleImage: boolean = true;
  @StorageProp('articleDescLength') articleDescLength: number = DESC_SHORT;
  @StorageProp('listSettingsTick') @Watch('onListSettingsChanged') listSettingsTick: number = 0;
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
  // Unfiltered group list; used to re-derive `groups` on filter switch without
  // an async DB read (which would momentarily pair new feeds with stale groups).
  private allGroups: FeedGroup[] = [];
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
  // Pagination state machine (stale-result guards / hasMore / dedupe) is a pure
  // class so it can be unit-tested; the component adds DB/UI side effects.
  private paging: ArticlePaging = new ArticlePaging();
  // Separate guard for badge/count refreshes so overlapping Watch callbacks
  // cannot pair feeds from one filter with groups from another.
  private feedRefreshSeq: number = 0;
  // AppStorage-backed so toggling it in Settings updates this always-mounted
  // list immediately, without relying on load()/onShown refresh timing.
  @StorageProp('markReadOnScroll') markReadOnScroll: boolean = false;
  @State unreadCount: number = 0;
  @State starredCount: number = 0;
  @State allCount: number = 0;
  // Global totals (all sources) for the drawer top row, independent of the
  // currently selected feed/group.
  @State globalUnread: number = 0;
  @State globalStarred: number = 0;
  @State globalAll: number = 0;
  // Slide transition between filter/feed contexts: the previous list slides out
  // while the new one slides in from the opposite edge.
  @State prevArticles: Article[] = [];
  @State curOffset: number = 0;
  @State prevOffset: number = 0;
  @State prevTopSpacer: number = 0; // height of rows scrolled above the snapshot
  private scrollOffset: number = 0;
  // Drives the visible article list; used by the title-bar tap to scroll to top.
  private listScroller: Scroller = new Scroller();
  // Context switches replace the rows while the List keeps its old scroll
  // offset. Until it snaps back to index 0, onScrollIndex reports the stale
  // offset against the NEW rows and would mark off-screen articles as read.
  private suppressScrollMark: boolean = false;
  private contextSeq: number = 0;
  // True while waiting for onScrollIndex(0) to confirm the snap-to-top after a
  // context switch. A stale large start arriving in this window is ignored.
  private awaitingTopConfirm: boolean = false;
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
  // Set on disappear so multi-step async work (expandToFullPage) stops issuing
  // DB queries and touching state after the component is gone.
  private disposed: boolean = false;
  @State showSearch: boolean = false;
  // Android FlowPage scrolls to the top before revealing the search bar. This
  // flag defers showing it until onScrollIndex reports index 0, so the list
  // reflow caused by inserting the bar cannot immediately auto-hide it again.
  private pendingShowSearch: boolean = false;
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
    // The store is the single source of truth. Re-project its diffs onto the
    // loaded rows (keeping read rows gray in the list) and re-derive counts.
    readStatusStore.applyTo(this.articles);
    this.articles = this.articles.slice();
    this.refreshCounts();
    this.notifyBannerTick();
  }

  /** The store committed a batch to the DB: re-read per-feed unread badges so
   *  the subscription drawer shows the authoritative counts. */
  private onReadStatusFlushed(): void {
    this.refreshFeeds();
  }

  private async refreshCounts(): Promise<void> {
    // Counts = DB aggregate + local diff delta. No dual counters to keep in sync.
    const scoped: ArticleCounts = await rssRepository.articleCounts(this.currentFeedId, this.currentGroupId);
    const scopedUnreadDelta: number =
      readStatusStore.unreadDelta(this.currentFeedId, this.currentGroupId, false);
    this.unreadCount = Math.max(0, scoped.unread + scopedUnreadDelta);
    this.starredCount = scoped.starred + readStatusStore.starredDelta('');
    this.allCount = scoped.total;
    // Global totals for the drawer top row, never scoped by feed/group.
    const global: ArticleCounts = await rssRepository.articleCounts();
    this.globalUnread = Math.max(0, global.unread + readStatusStore.unreadDelta('', '', true));
    this.globalStarred = global.starred + readStatusStore.starredDelta('');
    this.globalAll = global.total;
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
    const estimatedRows: number = Math.max(5, Math.floor(usable / this.estimatedRowHeight()));
    const perScreen: number = this.visibleCount > 0 ? this.visibleCount : estimatedRows;
    return Math.min(80, Math.max(20, perScreen * 2));
  }

  /** Sort ascending only for the unread filter (Android: starred/all are fixed DESC). */
  private sortAscending(): boolean {
    return this.sortUnreadEarliest && this.currentFilter === FILTER_UNREAD;
  }

  /** Identity of the current ordering. Any change invalidates paged appends. */
  private computeOrderKey(): string {
    return [
      this.currentFeedId, this.currentGroupId, this.currentFilter,
      this.searchText, this.sortAscending() ? 'asc' : 'desc',
    ].join('|');
  }

  /** Estimated height of one article row (vp), derived from the same display
   *  settings the row renderer uses. Display toggles change row height, so the
   *  first-page estimate must track them; otherwise the initial batch is too
   *  small (blank space) or too large (wasted rows) before real measurement. */
  private estimatedRowHeight(): number {
    const titleLines: number = 2;
    const summaryLines: number = this.articleDescLength === DESC_NONE
      ? 0 : (this.articleDescLength === DESC_LONG ? 3 : 2);
    // ~1.3 line-height factor, plus top margins and vertical padding.
    const title: number = titleLines * this.articleTitleFontSize * this.fontScale * 1.3;
    const summary: number = summaryLines > 0
      ? 6 * this.fontScale + summaryLines * this.articleSummaryFontSize * this.fontScale * 1.3
      : 0;
    const meta: number = 6 * this.fontScale + this.articleMetaFontSize * this.fontScale * 1.4;
    // A thumbnail sits on the right; when shown it sets a minimum row height.
    const image: number = this.showArticleImage ? 64 : 0;
    const padding: number = 28 * this.fontScale;
    return Math.max(title + summary + meta + padding, image + padding);
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

  /** Set feeds + groups together from the cached unfiltered lists, keeping the
   *  drawer group headers and their feeds consistent for the active filter. */
  private applyFeedFilter(): void {
    this.feeds = filterFeedsByDrawer(this.iconFeeds, this.currentFilter);
    this.groups = this.allGroups.filter((group: FeedGroup) =>
      this.feeds.some((feed: Feed) => feed.groupId === group.id)
    );
  }

  /** Refresh the drawer's per-feed unread badges and global totals after a
   *  read/star change, so both the per-source badges and the top banner count
   *  stay in sync with the database. */
  private async refreshFeeds(): Promise<void> {
    const seq: number = ++this.feedRefreshSeq;
    const allFeeds: Feed[] = await rssRepository.listFeeds();
    if (seq !== this.feedRefreshSeq) return;
    this.iconFeeds = allFeeds;
    this.rebuildIconMap();
    const allGroups: FeedGroup[] = await rssRepository.listGroups();
    if (seq !== this.feedRefreshSeq) return;
    this.allGroups = allGroups;
    this.applyFeedFilter();
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

  /** A list-behavior setting changed (sort / display toggles): reload so the
   *  query uses the new sort order and rows render with the new visibility. */
  onListSettingsChanged(): void {
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
    this.disposed = false;
    this.currentFeedId = this.feedId;
    this.loadAccount();
    this.load();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    // Cancel pending deferred work so it does not keep querying the DB or hold
    // this component alive after the list has been popped.
    if (this.slideTimer !== 0) {
      clearTimeout(this.slideTimer);
      this.slideTimer = 0;
    }
    if (this.expandTimer !== 0) {
      clearTimeout(this.expandTimer);
      this.expandTimer = 0;
    }
    this.flushScrollMarks();
    readStatusStore.flush();
  }

  /** Mark rows above the visible range as read; committed in the background by
   *  ReadStatusStore. Called only when scrolling stops (ScrollState.Idle), so a
   *  continuous scroll does not fire it on every frame. Mirrors Android: unread
   *  tab only. */
  private markScrolledArticles(start: number): void {
    if (!this.markReadOnScroll || this.currentFilter !== FILTER_UNREAD
      || start <= this.lastMarkedIndex) {
      return;
    }
    // Normal scrolling advances `start` by only a few rows per frame. A large
    // single jump means a stale scroll offset from a context switch slipped
    // through (e.g. a delayed onScrollIndex delivered after the guard lifted).
    // Re-anchor instead of mass-marking off-screen articles as read.
    if (start - this.lastMarkedIndex > MAX_SCROLL_MARK_STEP) {
      this.lastMarkedIndex = start;
      return;
    }
    let markedCount: number = 0;
    for (let i = this.lastMarkedIndex; i < start && i < this.articles.length; i++) {
      const article: Article = this.articles[i];
      if (!article.isRead) {
        // Local diff is the source of truth; the store publishes a tick that
        // re-projects rows and re-derives counts. Mutate in place now and slice
        // once on Idle (flushScrollMarks) to avoid per-frame ForEach rebuilds.
        this.articles[i] = ArticleListView.withReadState(article, true);
        readStatusStore.markRead(article.id, false, true, article.feedId, this.currentGroupId);
        markedCount++;
      }
    }
    this.lastMarkedIndex = start;
    if (markedCount > 0) {
      this.scrollMarksPending = true;
      Logger.info(`Marked ${markedCount} articles read on scroll`);
    }
  }

  /** Apply deferred visual updates once, after scrolling stops. */
  private flushScrollMarks(): void {
    if (this.scrollMarksPending) {
      this.scrollMarksPending = false;
      this.articles = this.articles.slice();
    }
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
    if (ids.length === 0) {
      return;
    }
    // Set lookup keeps this O(rows) instead of O(rows × ids) on big selections.
    const targets: Set<string> = new Set<string>(ids);
    const next: Article[] = [];
    for (const article of this.articles) {
      next.push(targets.has(article.id)
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

  private async load(
    resetPaging: boolean = true, fromSync: boolean = false, snapToTop: boolean = true
  ): Promise<void> {
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
    // Reset to the first page only on a genuine context switch (filter/feed/search).
    // A sync-completed refresh passes false to preserve how deep the user scrolled.
    const seq: number = this.paging.beginLoad(
      this.firstPageSize(), this.computeOrderKey(), resetPaging
    );
    if (resetPaging) {
      this.beginContextSwitch();
    }
    const allFeeds: Feed[] = await rssRepository.listFeeds();
    if (this.paging.isStale(seq, this.paging.getPageSeq(), this.paging.getOrderKey())) return;
    this.iconFeeds = allFeeds;
    this.rebuildIconMap();
    const allGroups: FeedGroup[] = await rssRepository.listGroups();
    if (seq !== this.paging.getLoadSeq()) return;
    this.allGroups = allGroups;
    this.applyFeedFilter();
    FeedIcon.prefetch(this.getUIContext().getHostContext() as common.Context, this.feeds);
    const articles: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, this.paging.getDisplayLimit(),
      this.currentGroupId, this.sortAscending(), this.searchText, true
    );
    if (seq !== this.paging.getLoadSeq()) return;
    // Re-project local diffs onto DB rows so locally-changed read/star state
    // survives a reload (the DB commit is still pending in the store).
    readStatusStore.applyTo(articles);
    this.articles = articles;
    this.paging.updateHasMore(articles.length, this.paging.getDisplayLimit());
    this.finishSlide();
    if (resetPaging) {
      this.finishContextSwitch(snapToTop);
    }
    this.scheduleExpand(seq);
    this.lastMarkedIndex = 0;
    this.lastPrefetchIndex = 0;
    this.scrollMarksPending = false;
    if (seq !== this.paging.getLoadSeq()) return;
    // Derive counts from DB + local diff (refreshCounts does both queries).
    await this.refreshCounts();
    if (seq !== this.paging.getLoadSeq()) return;
    fullContentPrefetcher.ensureWindow(
      this.articles, this.firstVisibleIndex, this.visibleCount
    );
  }

  /** Filter-tab switch: only the article list changes. Skip the feed/group/count
   *  queries and the icon prefetch, which are unaffected by the filter. */
  private async reloadForFilterSwitch(): Promise<void> {
    const seq: number = this.paging.beginLoad(this.firstPageSize(), this.computeOrderKey(), true);
    this.beginContextSwitch();
    // Re-derive BOTH feeds and groups from the cached unfiltered lists. Leaving
    // groups stale here is what shows empty groups when switching to starred.
    this.applyFeedFilter();
    const articles: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, this.paging.getDisplayLimit(),
      this.currentGroupId, this.sortAscending(), this.searchText, true
    );
    if (seq !== this.paging.getLoadSeq()) return;
    readStatusStore.applyTo(articles);
    this.articles = articles;
    this.paging.updateHasMore(articles.length, this.paging.getDisplayLimit());
    this.lastMarkedIndex = 0;
    this.lastPrefetchIndex = 0;
    this.scrollMarksPending = false;
    this.finishSlide();
    this.finishContextSwitch();
    fullContentPrefetcher.ensureWindow(this.articles, this.firstVisibleIndex, this.visibleCount);
    this.scheduleExpand(seq);
  }

  /** Load the remaining (up to FULL_PAGE_SIZE) lightweight rows after the first
   *  batch has painted and the slide finished. Keeps the tab switch snappy. */
  private scheduleExpand(seq: number): void {
    if (this.paging.getDisplayLimit() >= FULL_PAGE_SIZE) {
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
    // Capture the ordering at request time. If a sort/feed/filter switch lands
    // while the DB query is in flight, orderKey changes and these rows are stale.
    const orderKey: string = this.paging.getOrderKey();
    const rows: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, targetLimit,
      this.currentGroupId, this.sortAscending(), this.searchText, true
    );
    if (this.paging.isStale(seq, pageSeq, orderKey)) {
      return false;
    }
    // Fewer rows than requested means the data source is exhausted.
    this.paging.updateHasMore(rows.length, targetLimit);
    const merged: AppendResult = this.paging.mergeAppend(this.articles, rows);
    this.articles = merged.articles;
    this.paging.setDisplayLimit(targetLimit);
    return merged.appended;
  }

  private async expandToFullPage(seq: number): Promise<void> {
    if (seq !== this.paging.getLoadSeq() || this.paging.getDisplayLimit() >= FULL_PAGE_SIZE
      || this.paging.isLoadingMore()) {
      return;
    }
    const pageSeq: number = this.paging.getPageSeq();
    while (this.paging.getDisplayLimit() < FULL_PAGE_SIZE && this.paging.getHasMore()) {
      if (this.disposed || this.paging.isPageStale(seq, pageSeq) || this.paging.isLoadingMore()) {
        return;
      }
      const target: number = this.paging.nextExpandTarget(FULL_PAGE_SIZE, EXPAND_CHUNK);
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
    if (this.paging.isLoadingMore()) {
      return;
    }
    // While a sync is committing batches the DB holds an intermediate state;
    // loading another page now could mix partial rows into the list. Triggered
    // automatically by scrolling, so ignore silently (no toast) to avoid spam.
    if (this.isSyncing || !this.paging.getHasMore()) {
      return;
    }
    const seq: number = this.paging.getLoadSeq();
    const pageSeq: number = this.paging.beginLoadMore();
    if (pageSeq < 0) {
      return;
    }
    try {
      const nextLimit: number = this.paging.getDisplayLimit() + LOAD_MORE_STEP;
      await this.fetchAppend(nextLimit, seq, pageSeq);
    } catch (error) {
      Logger.error(`Load more failed: ${(error as Error).message}`);
    } finally {
      this.paging.endLoadMore();
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
    // Carry the visible list scope so prev/next in the reader stay inside it
    // (e.g. the "全部" tab spans every feed, not just this article's feed).
    openArticle(article.id, {
      feedId: this.currentFeedId,
      groupId: this.currentGroupId,
      filter: this.currentFilter,
      searchText: this.searchText,
    });
  }

  /** Mark unread articles as read. `days <= 0` means all; otherwise only
   *  articles older than N days (Android MarkAsReadBar 1/3/7/All). */
  private doMarkRead(days: number): void {
    const before: number = days > 0 ? Date.now() - days * 24 * 60 * 60 * 1000 : 0;
    const ids: string[] = [];
    for (const article of this.articles) {
      if (article.isRead) {
        continue;
      }
      if (days <= 0 || article.publishedAt < before) {
        ids.push(article.id);
      }
    }
    if (ids.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '没有符合条件的文章' });
      return;
    }
    // Local diff drives rows and counts; the bulk service call persists to DB
    // and server in the background. On failure, drop the local diff and re-read.
    this.setLocalRead(ids, true);
    for (const article of this.articles) {
      if (ids.indexOf(article.id) >= 0) {
        // Display-only diff; markAllRead persists via its own service call, so
        // do not schedule a duplicate flush (avoids double-push race).
        readStatusStore.markReadLocal(article.id, false, true, article.feedId, this.currentGroupId);
      }
    }
    const task: Promise<void> = days <= 0
      ? rssRepository.markAllRead(this.currentFeedId, this.currentGroupId)
      : rssRepository.markAllReadBefore(this.currentFeedId, this.currentGroupId, before);
    task.then(() => {
      // Commit succeeded: clear the local diffs that are now persisted, then
      // re-derive counts. The store's publish tick drives the rest.
      for (const id of ids) {
        readStatusStore.clearConfirmed(id);
      }
      // markAllRead wrote the DB directly: re-read per-feed badges (and counts).
      this.refreshFeeds();
      this.notifyBannerTick();
    }).catch((error: Error) => {
      for (const id of ids) {
        readStatusStore.clearConfirmed(id);
      }
      this.setLocalRead(ids, false);
      this.refreshFeeds();
      this.notifyBannerTick();
      Logger.error(`Mark read failed: ${error.message}`);
    });
  }

  /** Optimistically toggle read state for one row (shared by swipe + menu). */
  private toggleRead(article: Article): void {
    const read: boolean = !article.isRead;
    // Immediate local row update for instant UI; markRead publishes a tick that
    // re-derives counts and re-projects all rows (no explicit refreshCounts).
    this.setLocalRead([article.id], read);
    readStatusStore.markRead(article.id, !read, !article.isRead, article.feedId, this.currentGroupId);
  }

  /** Optimistically toggle starred state for one row (shared by swipe + menu). */
  private toggleStar(article: Article): void {
    const starred: boolean = !article.isStarred;
    this.setLocalStarred(article.id, starred);
    readStatusStore.markStarred(article.id, starred, article.isStarred, article.feedId);
  }

  /** Mark-as-read options as a standard Array<MenuElement> menu. Using the
   *  system menu (same as SettingsView) instead of a Menu() CustomBuilder avoids
   *  the oversized / blank-strip rendering seen on some devices; the title is
   *  supplied via MenuOptions.title (only applies to Array<MenuElement>). */
  private markReadMenu(): Array<MenuElement> {
    return [
      { value: '1 天内', action: () => this.doMarkRead(1) },
      { value: '3 天内', action: () => this.doMarkRead(3) },
      { value: '7 天内', action: () => this.doMarkRead(7) },
      { value: '全部', action: () => this.doMarkRead(0) },
    ];
  }

  /** Icon-only action button shown by a swipe. A fixed-size container with a
   *  centred icon avoids the icon being squeezed by padding (ArkUI width/height
   *  includes padding), which otherwise shows only a small gray circle. */
  @Builder
  swipeActionButton(article: Article, action: number): void {
    if (action === SWIPE_TOGGLE_READ || action === SWIPE_TOGGLE_STARRED) {
      Row() {
        // Icons show the ACTION (what a tap will do), consistent with the
        // long-press menu and the reader menu: a filled star means "collect",
        // an outline star means "uncollect"; a check means "mark read", a ring
        // means "mark unread".
        Image(action === SWIPE_TOGGLE_READ
          ? (article.isRead ? $r('app.media.ic_filter_unread') : $r('app.media.ic_mark_read'))
          : (article.isStarred ? $r('app.media.ic_star_outline') : $r('app.media.ic_filter_star')))
          .width(22)
          .height(22)
          .fillColor(Color.White)
      }
      .width(52)
      .height(52)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ left: 8, right: 8 })
      .backgroundColor(action === SWIPE_TOGGLE_STARRED && !article.isStarred ? '#F9A825' : '#5E636A')
      .borderRadius(26)
      .onClick(() => {
        if (action === SWIPE_TOGGLE_READ) {
          this.toggleRead(article);
        } else {
          this.toggleStar(article);
        }
      })
    }
  }

  @Builder
  articleItem(article: Article): void {
    // Reuses the same row layout as the Settings > Article List preview.
    ArticleRowView({
      article: article,
      feedIconSrc: this.iconForFeed(article.feedId),
      onLongPress: () => {
        this.menuArticleId = article.id;
        this.menuArticleRead = article.isRead;
        this.menuArticleStarred = article.isStarred;
        this.menuArticleTime = article.publishedAt;
        this.setArticleMenuVisible(true);
      },
    })
  }

  /** Android ArticleListReaderViewModel.markAsReadFromListByDate. "Above" and
   *  "below" follow the visible sort direction: with the default newest-first
   *  order above = newer; with oldest-first above = older. */
  private menuMarkByDate(above: boolean): void {
    const ids: string[] = [];
    // In ASC order "above" is older; in DESC (default) "above" is newer.
    const aboveIsOlder: boolean = this.sortAscending();
    const wantOlder: boolean = above ? aboveIsOlder : !aboveIsOlder;
    for (const article of this.articles) {
      if (article.id === this.menuArticleId || article.isRead) {
        continue;
      }
      if (wantOlder
            ? article.publishedAt < this.menuArticleTime
            : article.publishedAt > this.menuArticleTime) {
        ids.push(article.id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    // Local diff drives the immediate gray-out and count; the service persists
    // in the background via the store's own batch path (no double push here).
    this.setLocalRead(ids, true);
    for (const article of this.articles) {
      if (ids.indexOf(article.id) >= 0) {
        readStatusStore.markRead(article.id, false, true, article.feedId, this.currentGroupId);
      }
    }
    // The markX calls publish readStatusTick; the watcher re-derives rows and
    // counts. This path uses the store's background flush, so failures retry.
  }

  private menuToggleRead(): void {
    const id: string = this.menuArticleId;
    const read: boolean = !this.menuArticleRead;
    const article: Article | undefined = this.articles.find((a: Article): boolean => a.id === id);
    const dbUnread: boolean = article !== undefined ? !article.isRead : !read;
    this.setLocalRead([id], read);
    this.menuArticleRead = read;
    readStatusStore.markRead(id, !read, dbUnread, article?.feedId ?? '', this.currentGroupId);
  }

  private menuToggleStarred(): void {
    const id: string = this.menuArticleId;
    const starred: boolean = !this.menuArticleStarred;
    const article: Article | undefined = this.articles.find((a: Article): boolean => a.id === id);
    this.setLocalStarred(id, starred);
    this.menuArticleStarred = starred;
    readStatusStore.markStarred(id, starred, !starred, article?.feedId ?? '');
  }

  /** Share the long-pressed article via the system share sheet (Android menu item). */
  private async menuShare(): Promise<void> {
    const article: Article | undefined = await rssRepository.getArticleMeta(this.menuArticleId);
    const link: string = article?.link ?? '';
    if (link.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这篇文章没有原文链接' });
      return;
    }
    try {
      const title: string = article?.title ?? '';
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: link,
        title: title,
        description: title,
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `分享失败：${(error as Error).message}` });
    }
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

  /** Drawer callbacks. The drawer panel (FeedListView) reports the selection;
   *  this view keeps the slide animation and scope switching. */
  private onDrawerSelectGlobal(): void {
    const key: string = '__global__';
    if (key !== this.currentSelectionKey()) {
      this.prepareSlide(this.drawerSlideDirection(key));
    }
    this.currentFeedId = '';
    this.currentGroupId = '';
    this.closeDrawer();
    this.load();
  }

  private onDrawerSelectFeed(feedId: string): void {
    const key: string = `f:${feedId}`;
    if (key !== this.currentSelectionKey()) {
      this.prepareSlide(this.drawerSlideDirection(key));
    }
    this.currentFeedId = feedId;
    this.currentGroupId = '';
    this.closeDrawer();
    this.load();
  }

  private onDrawerSelectGroup(groupId: string): void {
    const key: string = `g:${groupId}`;
    if (key !== this.currentSelectionKey()) {
      this.prepareSlide(this.drawerSlideDirection(key));
    }
    this.currentFeedId = '';
    this.currentGroupId = groupId;
    this.closeDrawer();
    this.load();
  }

  private closeDrawer(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => {
      this.showFeedDrawer = false;
    });
  }

  private onDrawerDeletedFeed(): void {
    this.refreshFeeds();
    this.load();
  }

  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  /** Force the row list to rebuild when an article font size changes. */
  onFontSizeChanged(): void {
    if (this.articles.length > 0) {
      this.articles = this.articles.slice();
    }
  }

  /** Tap the title bar to smoothly scroll the article list back to the top.
    *  Index 0 is always the first article: the top spacer lives only in the
    *  outgoing snapshot list, not in the current list. */
  private scrollToTop(): void {
    try {
      this.listScroller.scrollToIndex(0, true, ScrollAlign.START);
    } catch (error) {
      // List may not have laid out yet (e.g. tapped before the first paint).
    }
  }

  /** Begin a genuine context switch (filter/feed/group/search): freeze scroll
   *  marking immediately so the stale List offset can't mark off-screen rows. */
  private beginContextSwitch(): void {
    this.contextSeq++;
    this.suppressScrollMark = true;
    this.awaitingTopConfirm = true;
    this.lastMarkedIndex = 0;
  }

  /** Settle a replaced list and release the marking guard. When snapToTop is
   *  true (filter/feed/group/search switches) scroll to index 0; when false
   *  (page re-shown after reading) keep the current offset. Either way the
   *  guard stays until layout settles, so a stale offset can't mark rows. */
  private finishContextSwitch(snapToTop: boolean = true): void {
    const seq: number = this.contextSeq;
    if (snapToTop) {
      this.firstVisibleIndex = 0;
      try {
        this.listScroller.scrollToIndex(0, false, ScrollAlign.START);
      } catch (error) {
        // List may not have laid out yet.
      }
    } else {
      // Keeping position (page re-shown): no top confirmation is coming.
      this.awaitingTopConfirm = false;
    }
    // Safety net only. Normal release happens when onScrollIndex reports 0.
    setTimeout(() => {
      if (seq !== this.contextSeq) return;
      if (snapToTop) {
        // Re-snap in case the first one ran before the new rows were measured.
        try {
          this.listScroller.scrollToIndex(0, false, ScrollAlign.START);
        } catch (error) {
          // ignore
        }
        // Force-release even if no onScrollIndex fired (e.g. empty list).
        this.firstVisibleIndex = 0;
      }
      this.lastMarkedIndex = this.firstVisibleIndex;
      this.awaitingTopConfirm = false;
      this.suppressScrollMark = false;
    }, 150);
  }

  /** Search button, mirroring Android FlowPage.kt: when scrolled down, animate
    *  the list to the top first and only then reveal the search bar. Showing it
    *  while scrolled makes the list reflow and emit onScrollIndex(start > 0),
    *  whose auto-hide would make the bar flash and vanish. */
  private toggleSearch(): void {
    if (this.showSearch) {
      this.showSearch = false;
      this.pendingShowSearch = false;
      return;
    }
    if (this.firstVisibleIndex > 0) {
      this.pendingShowSearch = true;
      this.scrollToTop();
      // Safety net: if the smooth scroll never reports index 0 (e.g. before
      // first layout), snap to the top instantly before revealing the bar so
      // the reflow can't re-trigger the auto-hide. Also covers an empty list.
      setTimeout(() => {
        if (this.pendingShowSearch) {
          this.pendingShowSearch = false;
          try {
            this.listScroller.scrollToIndex(0, false, ScrollAlign.START);
          } catch (error) {
            // List may not be laid out yet; revealing the bar is still useful.
          }
          this.showSearch = true;
        }
      }, 800);
    } else {
      this.showSearch = true;
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
          .onClick(() => this.toggleSearch())

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
          // Standard ArkUI menu, titled "标记为已读" (Android MarkAsReadBar).
          .bindMenu(this.markReadMenu(), {
            title: '标记为已读',
            placement: Placement.BottomRight,
          })
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 14 })
        // Tapping the title bar scrolls the list back to the top. Buttons in
        // this row consume their own clicks, so they don't trigger this.
        .onClick(() => this.scrollToTop())

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
            List({ scroller: this.listScroller }) {
              ForEach(this.articles, (article: Article) => {
                ListItem() {
                  this.articleItem(article)
                }
                .onClick(() => this.open(article))
                .swipeAction({
                  start: this.swipeStartAction === SWIPE_NONE ? undefined : {
                    builder: () => { this.swipeActionButton(article, this.swipeStartAction); },
                  },
                  end: this.swipeEndAction === SWIPE_NONE ? undefined : {
                    builder: () => { this.swipeActionButton(article, this.swipeEndAction); },
                  },
                })
              // Keep isRead/isStarred in the key: ArkUI ForEach reuses a node
              // when its key is unchanged and will NOT re-run the item builder,
              // so a pure-id key leaves the row's gray/star visuals stale after
              // an optimistic mark. The state fields force a fresh row.
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
              // A context switch swaps the rows but the List briefly keeps the
              // OLD scroll offset. A stale large `start` against the new rows
              // would mark off-screen articles as read, so gate everything on
              // the snap-to-top confirmation.
              if (this.suppressScrollMark) {
                if (this.awaitingTopConfirm) {
                  if (start === 0) {
                    // Snap confirmed: the visible list is genuinely at the top.
                    this.firstVisibleIndex = 0;
                    this.visibleCount = end >= start ? end - start + 1 : 0;
                    this.lastMarkedIndex = 0;
                    this.lastPrefetchIndex = 0;
                    this.awaitingTopConfirm = false;
                    this.suppressScrollMark = false;
                  }
                  // start > 0 here is a stale offset from before the switch —
                  // ignore it entirely (no mark, no prefetch, no search toggle).
                } else {
                  // Page re-shown while keeping position: track it, but still
                  // suppress marking until the safety net releases the guard.
                  this.firstVisibleIndex = start;
                  this.visibleCount = end >= start ? end - start + 1 : 0;
                }
                return;
              }

              this.firstVisibleIndex = start;
              this.visibleCount = end >= start ? end - start + 1 : 0;
              // Deferred reveal from toggleSearch: the list is now at the top,
              // so inserting the search bar cannot trigger the auto-hide below.
              if (start === 0 && this.pendingShowSearch) {
                this.pendingShowSearch = false;
                this.showSearch = true;
              }
              if (start > 0 && this.showSearch) {
                this.showSearch = false;
              }
              // Throttle prefetch: only recompute the window after the visible
              // item moved a few rows, not on every index tick.
              if (Math.abs(start - this.lastPrefetchIndex) >= 3) {
                this.lastPrefetchIndex = start;
                fullContentPrefetcher.ensureWindow(this.articles, start, this.visibleCount);
              }
              // Scroll marking runs only on Idle (see onScroll below), not every frame.
            })
            // Flush the deferred row rebuilds when scrolling settles, so the
            // ForEach is rebuilt once instead of on every scroll frame.
            .onScroll((offset: number, scrollState: ScrollState) => {
              this.scrollOffset = offset;
              if (scrollState === ScrollState.Idle) {
                // Mark everything scrolled past in one pass when scrolling
                // stops, then rebuild rows once. lastMarkedIndex guards against
                // a stale large jump being mistaken for genuine scrolling.
                this.markScrolledArticles(this.firstVisibleIndex);
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
              Image($r('app.media.ic_share'))
                .width(24).height(24).fillColor(this.textColor())
                .margin({ right: 12 })
              Text('分享').fontFamily(this.appFont())
                .fontSize(this.fs(16)).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuShare();
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

          FeedListView({
            feeds: this.feeds,
            groups: this.groups,
            currentFilter: this.currentFilter,
            accountName: this.accountName,
            accountTypeLabel: this.accountTypeLabel,
            bannerLabel: this.filterName(),
            bannerCount: this.drawerTotalCount(),
            selectedFeedId: this.currentFeedId,
            selectedGroupId: this.currentGroupId,
            onSelectFeed: (feedId: string) => this.onDrawerSelectFeed(feedId),
            onSelectGroup: (groupId: string) => this.onDrawerSelectGroup(groupId),
            onSelectGlobal: () => this.onDrawerSelectGlobal(),
            onClose: () => this.closeDrawer(),
            onDeletedFeed: () => this.onDrawerDeletedFeed(),
          })
          .width('66%')
          .height('100%')
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
    // Returning from the reader re-runs load() to refresh read state. Keep the
    // user's scroll position here (still suppressing stale-offset marking),
    // unlike filter/feed/group switches which snap to the top.
    .onShown(() => this.load(true, false, false))
  }
}
