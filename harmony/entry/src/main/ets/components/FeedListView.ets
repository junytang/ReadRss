import { Feed, FeedGroup } from '../model/Models';
import { rssRepository } from '../rss/RssRepository';
import { openAccounts } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';
import { FeedIcon } from '../common/FeedIcon';
import { FILTER_ALL, FILTER_STARRED } from '../common/Constants';

interface FeedListRow {
  key: string;
  groupName?: string;
  groupId?: string;
  feed?: Feed;
}

/**
 * Subscription drawer panel. A controlled component: the parent
 * (ArticleListView) owns the feed/group/count data and the slide animation;
 * this view only renders the list and reports selections via callbacks.
 */
@Component
export struct FeedListView {
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('fontScale') uiFontScale: number = 1;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('bottomInset') bottomInset: number = 0;

  private scroller: Scroller = new Scroller();
  // Three @Watch callbacks plus aboutToAppear can each schedule a 30ms
  // scroll-to-selection in one selection change. Coalesce into one trailing
  // timer and cancel it when the drawer closes.
  private scrollTimer: number = -1;

  @Prop feeds: Feed[] = [];
  @Prop groups: FeedGroup[] = [];
  @Prop @Watch('onSelectionChanged') currentFilter: string = FILTER_ALL;
  @Prop accountName: string = '';
  @Prop accountTypeLabel: string = '';
  @Prop bannerLabel: string = '';
  @Prop bannerCount: number = 0;
  @Prop @Watch('onSelectionChanged') selectedFeedId: string = '';
  @Prop @Watch('onSelectionChanged') selectedGroupId: string = '';

  private scheduleScrollToSelection(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
    }
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      this.scrollToSelection();
    }, 30);
  }

  onSelectionChanged(): void {
    // Re-scroll when filter/selection changes while the drawer is open.
    this.scheduleScrollToSelection();
  }

  onSelectFeed: (feedId: string) => void = () => {};
  onSelectGroup: (groupId: string) => void = () => {};
  onSelectGlobal: () => void = () => {};
  onClose: () => void = () => {};
  onDeletedFeed: () => void = () => {};

  aboutToAppear(): void {
    // Scroll the last-selected source/group into view when the drawer opens.
    this.scheduleScrollToSelection();
  }

  aboutToDisappear(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  /** Locate the selected row in listRows and center it in the List. */
  private scrollToSelection(): void {
    const feed: string = this.selectedFeedId;
    const group: string = this.selectedGroupId;
    if (feed.length === 0 && group.length === 0) {
      return;
    }
    const rows: FeedListRow[] = this.listRows();
    let rowIndex: number = -1;
    for (let i: number = 0; i < rows.length; i++) {
      const row: FeedListRow = rows[i];
      if (feed.length > 0 && row.feed !== undefined && row.feed!.id === feed) {
        rowIndex = i;
        break;
      }
      if (group.length > 0 && row.groupId === group) {
        rowIndex = i;
        break;
      }
    }
    let index: number;
    if (rowIndex < 0) {
      // The selected feed/group does not exist under the current filter (e.g.
      // after switching starred/unread). Fall back to the top banner.
      index = 0;
    } else {
      // Two leading ListItems: banner + separator. No empty-state row when
      // feeds is non-empty (the only case a selection can exist).
      index = rowIndex + 2;
    }
    try {
      this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER);
    } catch (error) {
      // Ignore: list may not have laid out yet.
    }
  }

  private fs(size: number): number { return size * this.uiFontScale; }

  private appFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  private surfaceColor(): string {
    return this.darkMode ? '#1F2226' : '#FFFFFF';
  }

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  private badgeCount(feed: Feed): number {
    return this.currentFilter === FILTER_STARRED ? feed.starredCount : feed.unreadCount;
  }

  private feedsInGroup(groupId: string): Feed[] {
    return this.feeds.filter((feed: Feed) => feed.groupId === groupId);
  }

  private ungroupedFeeds(): Feed[] {
    const ids: string[] = this.groups.map((group: FeedGroup) => group.id);
    return this.feeds.filter((feed: Feed) => ids.indexOf(feed.groupId) < 0);
  }

  private listRows(): FeedListRow[] {
    const rows: FeedListRow[] = [];
    for (const group of this.groups) {
      const members: Feed[] = this.feedsInGroup(group.id);
      if (members.length === 0) {
        continue;
      }
      rows.push({ key: `g:${group.id}:${members.length}`, groupName: group.name, groupId: group.id });
      for (const feed of members) {
        rows.push({ key: `f:${feed.id}`, feed: feed });
      }
    }
    const ungrouped: Feed[] = this.ungroupedFeeds();
    if (ungrouped.length > 0) {
      rows.push({ key: 'g:ungrouped', groupName: '未分组' });
      for (const feed of ungrouped) {
        rows.push({ key: `f:${feed.id}`, feed: feed });
      }
    }
    return rows;
  }

  private isSelected(feedId: string, groupId: string): boolean {
    if (feedId.length > 0) {
      return this.selectedFeedId === feedId;
    }
    if (groupId.length > 0) {
      return this.selectedGroupId === groupId;
    }
    return this.selectedFeedId.length === 0 && this.selectedGroupId.length === 0;
  }

  @Builder
  header(): void {
    Row() {
      Column() {
        Text(this.accountName.length > 0 ? this.accountName : '订阅源')
          .fontFamily(this.appFont())
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
      .onClick(() => openAccounts())

      // Add-subscription button temporarily disabled (kept for later).
      // Button() {
      //   Image($r('app.media.ic_add'))
      //     .width(19).height(19).fillColor('#1A1C1E')
      // }
      // .type(ButtonType.Circle)
      // .width(34).height(34)
      // .backgroundColor(Color.White)
      // .margin({ right: 8 })
      // .onClick(() => openSubscribe())

      Text('✕')
        .fontFamily(this.appFont())
        .fontSize(this.fs(18))
        .fontColor(this.secondaryColor())
        .padding({ left: 4, right: 4 })
        .onClick(() => this.onClose())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  /** Shared badge so the banner count and per-feed counts use identical
   *  styling and margins — with the same parent right padding (16vp) their
   *  right edges land on the same vertical line. */
  @Builder
  countBadge(count: number, leadingGap: number): void {
    if (count > 0) {
      Text(`${count}`).fontFamily(this.appFont())
        .fontSize(this.fs(12))
        .fontColor(this.darkMode ? '#E8EAED' : '#1A1C1E')
        .backgroundColor(this.darkMode ? '#3A3A3A' : '#E8E8E8')
        .borderRadius(10)
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        .margin({ left: leadingGap })
    }
  }

  @Builder
  banner(): void {
    Row() {
      Text(this.bannerLabel).fontFamily(this.appFont())
        .fontSize(this.fs(17))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor())
        .layoutWeight(1)
      this.countBadge(this.bannerCount, 0)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.isSelected('', '') ? (this.darkMode ? '#3A4657' : '#E8F0FE') : Color.Transparent)
    .onClick(() => this.onSelectGlobal())
  }

  @Builder
  groupHeader(name: string, groupId: string): void {
    Row() {
      Text(name).fontFamily(this.appFont())
        .fontSize(this.fs(13))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 16, right: 16 })
    .backgroundColor(groupId.length > 0 && this.selectedGroupId === groupId
      ? (this.darkMode ? '#3A4657' : '#E8F0FE') : Color.Transparent)
    .onClick(() => {
      if (groupId.length > 0) {
        this.onSelectGroup(groupId);
      }
    })
  }

  @Builder
  feedIcon(feed: Feed): void {
    if (FeedIcon.src(feed.iconUrl).length > 0) {
      Image(FeedIcon.src(feed.iconUrl))
        .width(20).height(20).borderRadius(4).margin({ right: 8 })
    } else {
      Image($r('app.media.app_icon'))
        .width(20).height(20).borderRadius(4).margin({ right: 8 })
    }
  }

  @Builder
  deleteAction(feedId: string): void {
    Row() {
      Button('取消订阅')
        .backgroundColor('#D93025')
        .fontColor(Color.White)
        .onClick(async () => {
          try {
            await rssRepository.removeFeed(feedId);
            this.onDeletedFeed();
          } catch (error) {
            // Deletion failure is reported by the parent via reload.
          }
        })
    }
  }

  @Builder
  listRowItem(row: FeedListRow): void {
    if (row.feed !== undefined) {
      ListItem() {
        Row() {
          this.feedIcon(row.feed!)
          Text(row.feed!.title).fontFamily(this.appFont())
            .fontSize(this.fs(15))
            .fontColor(this.textColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          this.countBadge(this.badgeCount(row.feed!), 6)
        }
        .width('100%')
        .height(44)
        .padding({ left: 28, right: 16 })
        .backgroundColor(this.isSelected(row.feed!.id, '') ? (this.darkMode ? '#3A4657' : '#E8F0FE') : Color.Transparent)
      }
      .onClick(() => this.onSelectFeed(row.feed!.id))
      .swipeAction({
        end: {
          builder: () => { this.deleteAction(row.feed!.id); },
        },
      })
    } else {
      ListItem() {
        this.groupHeader(row.groupName ?? '', row.groupId ?? '')
      }
    }
  }

  build() {
    Column() {
      this.header()

      List({ scroller: this.scroller }) {
        ListItem() {
          this.banner()
        }
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
        ForEach(this.listRows(), (row: FeedListRow) => {
          this.listRowItem(row)
        }, (row: FeedListRow) => row.key)
        // Generous trailing spacer as a real ListItem. A fixed, sufficient
        // height avoids depending on List layoutWeight/padding math, which can
        // leave the last row flush against the screen bottom.
        ListItem() {
          Row().width('100%').height(72 + this.bottomInset)
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.surfaceColor())
  }
}
