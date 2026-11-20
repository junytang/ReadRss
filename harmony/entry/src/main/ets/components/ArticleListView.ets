import { common } from '@kit.AbilityKit';
import { Article, Feed, FeedGroup } from '../model/Models';
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

/** Article list for one feed (or all feeds when feedId is empty). */
@Component
export struct ArticleListView {
  @Prop feedId: string = '';
  @Prop feedTitle: string = '全部文章';
  @Prop isRoot: boolean = false;
  onOpenFeeds: () => void = () => {};
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('fontScale') fontScale: number = 1;
  @StorageProp('readStatusTick') @Watch('onReadStatusChanged') readStatusTick: number = 0;
  @StorageProp('feedIconTick') @Watch('onFeedIconChanged') feedIconTick: number = 0;
  @StorageProp('feedFilterTick') @Watch('onFeedFilterChanged') feedFilterTick: number = 0;
  @StorageProp('accountSwitchTick') @Watch('onAccountSwitched') accountSwitchTick: number = 0;
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
  @State markReadOnScroll: boolean = false;
  @State unreadCount: number = 0;
  @State starredCount: number = 0;
  @State allCount: number = 0;
  @State showMarkAllConfirm: boolean = false;
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
    this.refreshCounts();
    this.refreshFeeds();
  }

  private async refreshCounts(): Promise<void> {
    this.unreadCount = await rssRepository.unreadCount(this.currentFeedId, this.currentGroupId);
    this.starredCount = await rssRepository.articleCount(FILTER_STARRED, this.currentFeedId, this.currentGroupId);
    this.allCount = await rssRepository.articleCount(FILTER_ALL, this.currentFeedId, this.currentGroupId);
  }

  /** Refresh the drawer's per-feed unread badges after a read-state change. */
  private async refreshFeeds(): Promise<void> {
    const allFeeds: Feed[] = await rssRepository.listFeeds();
    this.iconFeeds = allFeeds;
    this.rebuildIconMap();
    this.feeds = settingsStore.get().onlyUnreadFeeds
      ? allFeeds.filter((feed: Feed) => feed.unreadCount > 0)
      : allFeeds;
    const allGroups: FeedGroup[] = await rssRepository.listGroups();
    this.groups = allGroups.filter((group: FeedGroup) =>
      this.feeds.some((feed: Feed) => feed.groupId === group.id)
    );
  }

  onFeedIconChanged(): void {
    this.rebuildIconMap();
    this.articles = this.articles.slice();
    this.feeds = this.feeds.slice();
    this.iconFeeds = this.iconFeeds.slice();
  }

  onFeedFilterChanged(): void {
    this.load();
  }

  onAccountSwitched(): void {
    this.loadAccount();
    this.load();
  }

  private async loadAccount(): Promise<void> {
    const account = await accountRepository.active();
    if (account) {
      this.accountName = account.name;
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
      this.unreadCount = Math.max(0, this.unreadCount - markedCount);
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

  private async load(): Promise<void> {
    // Discard results from an older load: selecting a feed then tapping a filter
    // tab can start two overlapping loads whose DB queries resolve out of order.
    const seq: number = ++this.loadSeq;
    this.markReadOnScroll = settingsStore.get().markReadOnScroll;
    const allFeeds: Feed[] = await rssRepository.listFeeds();
    if (seq !== this.loadSeq) return;
    this.iconFeeds = allFeeds;
    this.rebuildIconMap();
    this.feeds = settingsStore.get().onlyUnreadFeeds
      ? allFeeds.filter((feed: Feed) => feed.unreadCount > 0)
      : allFeeds;
    const allGroups: FeedGroup[] = await rssRepository.listGroups();
    if (seq !== this.loadSeq) return;
    this.groups = allGroups.filter((group: FeedGroup) =>
      this.feeds.some((feed: Feed) => feed.groupId === group.id)
    );
    FeedIcon.prefetch(this.getUIContext().getHostContext() as common.Context, this.feeds);
    const articles: Article[] = await rssRepository.listArticles(
      this.currentFeedId, this.currentFilter, 500, this.currentGroupId, false, this.searchText
    );
    if (seq !== this.loadSeq) return;
    this.articles = articles;
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
    fullContentPrefetcher.ensureWindow(
      this.articles, this.firstVisibleIndex, this.visibleCount
    );
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
    if (this.isSyncing) {
      return;
    }
    this.isSyncing = true;
    this.isRefreshing = true;
    try {
      await rssRepository.syncAll();
      await this.load();
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
    this.unreadCount = 0;
    rssRepository.markAllRead(this.currentFeedId).then(() => { this.refreshFeeds(); }).catch((error: Error) => {
      this.setLocalRead(ids, false);
      this.unreadCount = previousUnread;
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
          this.unreadCount = Math.max(0, this.unreadCount + (read ? -1 : 1));
          rssRepository.markRead(article.id, read).then(() => { this.refreshFeeds(); }).catch((error: Error) => {
            this.setLocalRead([article.id], !read);
            this.unreadCount = Math.max(0, this.unreadCount + (read ? 1 : -1));
            Logger.error(`Mark read failed: ${error.message}`);
          });
        })
    }
  }

  @Builder
  articleItem(article: Article): void {
    Row() {
      Column() {
        Text(article.title).fontFamily(this.appFont())
          .fontSize(17)
          .fontWeight(article.isRead ? FontWeight.Normal : FontWeight.Medium)
          .fontColor(article.isRead ? this.readColor() : this.textColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (article.summary.length > 0) {
          Text(article.summary).fontFamily(this.appFont())
            .fontSize(15)
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
              .margin({ right: 4 })
          } else {
            Image($r('app.media.ic_feeds'))
              .width(14)
              .height(14)
              .padding(2)
              .fillColor(article.isRead ? this.readColor() : this.secondaryColor())
              .margin({ right: 4 })
          }
          Text(article.feedTitle).fontFamily(this.appFont())
            .fontSize(13)
            .fontColor(article.isRead ? this.readColor() : this.secondaryColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (article.isStarred) {
            Text('★').fontFamily(this.appFont()).fontSize(12).fontColor('#F9A825')
              .margin({ right: 6 })
          }
          Text(this.formatDate(article.publishedAt)).fontFamily(this.appFont())
            .fontSize(13)
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
    this.unreadCount = Math.max(0, previousUnread - ids.length);
    rssRepository.markReadBatch(ids, true).then(() => { this.refreshFeeds(); }).catch((error: Error) => {
      this.setLocalRead(ids, false);
      this.unreadCount = previousUnread;
      Logger.error(`Mark by date failed: ${error.message}`);
    });
  }

  private menuToggleRead(): void {
    const id: string = this.menuArticleId;
    const read: boolean = !this.menuArticleRead;
    this.setLocalRead([id], read);
    this.menuArticleRead = read;
    this.unreadCount = Math.max(0, this.unreadCount + (read ? -1 : 1));
    rssRepository.markRead(id, read).then(() => { this.refreshFeeds(); }).catch((error: Error) => {
      this.setLocalRead([id], !read);
      this.unreadCount = Math.max(0, this.unreadCount + (read ? 1 : -1));
      Logger.error(`Toggle read failed: ${error.message}`);
    });
  }

  private menuToggleStarred(): void {
    const id: string = this.menuArticleId;
    const starred: boolean = !this.menuArticleStarred;
    this.setLocalStarred(id, starred);
    this.menuArticleStarred = starred;
    this.starredCount = Math.max(0, this.starredCount + (starred ? 1 : -1));
    rssRepository.markStarred(id, starred).catch((error: Error) => {
      this.setLocalStarred(id, !starred);
      this.starredCount = Math.max(0, this.starredCount + (starred ? -1 : 1));
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
      .fontSize(14)
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

  @Builder
  drawerGroupItem(group: FeedGroup): void {
    Row() {
      Text(group.name)
        .fontSize(13)
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
      this.currentFeedId = '';
      this.currentGroupId = group.id;
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; });
      this.load();
    })
  }

  @Builder
  drawerFeedItem(feedId: string, title: string, unreadCount: number): void {
    Row() {
      if (this.iconForFeed(feedId).length > 0) {
        Image(this.iconForFeed(feedId))
          .width(20)
          .height(20)
          .borderRadius(4)
          .margin({ right: 8 })
      } else {
        Image($r('app.media.ic_feeds'))
          .width(20)
          .height(20)
          .padding(3)
          .fillColor(this.secondaryColor())
          .margin({ right: 8 })
      }
      Text(title)
        .fontSize(feedId.length === 0 ? 17 : 15)
        .fontColor(this.textColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (unreadCount > 0) {
        Text(`${unreadCount}`)
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor('#2663D6')
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
      this.currentFeedId = feedId;
      this.currentGroupId = '';
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; });
      this.load();
    })
  }

  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0 ? FontManager.family() : 'sans-serif';
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
            .fontSize(18)
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
          .divider({ strokeWidth: 1, color: this.darkMode ? '#2A2D31' : '#ECEFF2' })
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
            if (scrollState === ScrollState.Idle) {
              this.flushScrollMarks();
            }
          })
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
            this.currentFilter = filter;
            this.load();
          },
        })
      }

      if (this.showMarkAllConfirm) {
        Column() {
          Column() {
            Text('全部标记为已读').fontFamily(this.appFont())
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textColor())
            Text('确定将当前列表中的文章全部标记为已读吗？').fontFamily(this.appFont())
              .fontSize(14)
              .fontColor(this.secondaryColor())
              .margin({ top: 12 })
            Row() {
              Text('取消').fontFamily(this.appFont())
                .fontSize(15)
                .fontColor(this.secondaryColor())
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.showMarkAllConfirm = false; })
              Text('确定').fontFamily(this.appFont())
                .fontSize(15)
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
              Text(this.menuArticleRead ? '○' : '●').fontSize(18)
                .fontColor(this.textColor()).width(32).textAlign(TextAlign.Center)
              Text(this.menuArticleRead ? '标记为未读' : '标记为已读').fontFamily(this.appFont())
                .fontSize(16).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuToggleRead();
            })

            Row() {
              Text(this.menuArticleStarred ? '☆' : '★').fontSize(18)
                .fontColor(this.menuArticleStarred ? this.secondaryColor() : '#F9A825')
                .width(32).textAlign(TextAlign.Center)
              Text(this.menuArticleStarred ? '取消收藏' : '标记为收藏').fontFamily(this.appFont())
                .fontSize(16).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuToggleStarred();
            })

            Row() {
              Text('↑').fontSize(18).fontColor(this.textColor()).width(32).textAlign(TextAlign.Center)
              Text('标记上面文章为已读').fontFamily(this.appFont())
                .fontSize(16).fontColor(this.textColor()).layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.setArticleMenuVisible(false);
              this.menuMarkByDate(true);
            })

            Row() {
              Text('↓').fontSize(18).fontColor(this.textColor()).width(32).textAlign(TextAlign.Center)
              Text('标记下面文章为已读').fontFamily(this.appFont())
                .fontSize(16).fontColor(this.textColor()).layoutWeight(1)
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
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.textColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.accountTypeLabel)
                  .fontFamily(this.appFont())
                  .fontSize(12)
                  .fontColor(this.secondaryColor())
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('✕')
                .fontSize(18)
                .fontColor(this.secondaryColor())
                .onClick(() => { this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => { this.showFeedDrawer = false; }); })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 4 })

            List() {
              ListItem() {
                this.drawerFeedItem('', '全部', 0)
              }

              if (this.feeds.length === 0) {
                ListItem() {
                  Text(settingsStore.get().onlyUnreadFeeds ? '没有未读的订阅源' : '还没有订阅源')
                    .fontFamily(this.appFont())
                    .fontSize(13)
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
                    this.drawerFeedItem(feed.id, feed.title, feed.unreadCount)
                  }
                }, (feed: Feed) => feed.id)
              }, (group: FeedGroup) => group.id)
              ForEach(this.ungroupedFeeds(), (feed: Feed) => {
                ListItem() {
                  this.drawerFeedItem(feed.id, feed.title, feed.unreadCount)
                }
              }, (feed: Feed) => feed.id)
            }
            .width('100%')
            .layoutWeight(1)
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
