import { common } from '@kit.AbilityKit';
import { Feed, FeedGroup } from '../model/Models';
import { rssRepository } from '../rss/RssRepository';
import { settingsStore } from '../data/SettingsStore';
import { goBack, openAccounts, openFlow, openSettings, openSubscribe } from '../common/NavigationService';
import { accountRepository } from '../account/AccountRepository';
import { accountTypeName } from '../account/AccountModels';
import { FILTER_ALL, FILTER_STARRED, FILTER_UNREAD } from '../common/Constants';
import { FilterBarView } from './FilterBarView';
import { FeedIcon } from '../common/FeedIcon';
import { FontManager } from '../common/FontManager';

/** Home screen: subscription list with pull-to-refresh and unread counts. */
@Component
export struct FeedListView {
  @Prop asDestination: boolean = false;
  onCloseFeeds: () => void = () => {};
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('feedIconTick') @Watch('onFeedIconChanged') feedIconTick: number = 0;
  @StorageProp('feedFilterTick') @Watch('onFeedFilterChanged') feedFilterTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('readStatusTick') @Watch('onReadStatusChanged') readStatusTick: number = 0;
  @State feeds: Feed[] = [];
  @State groups: FeedGroup[] = [];
  @State isRefreshing: boolean = false;
  @State isSyncing: boolean = false;
  @State isLoading: boolean = true;
  @State activeAccountLabel: string = '';
  @State bannerCount: number = 0;
  @StorageLink('currentFilter') currentFilter: string = FILTER_UNREAD;
  @StorageProp('accountSwitchTick') @Watch('onAccountChanged') accountTick: number = 0;
  @StorageProp('feedDataTick') @Watch('onFeedDataChanged') feedDataTick: number = 0;
  @StorageProp('navBackTick') @Watch('onNavBack') navBackTick: number = 0;

  onAccountChanged(): void {
    this.loadAccount();
    this.load();
  }

  onFeedDataChanged(): void {
    this.load();
  }

  onNavBack(): void {
    this.load();
  }

  onReadStatusChanged(): void {
    this.load();
  }

  onFeedIconChanged(): void {
    this.feeds = this.feeds.slice();
  }

  onFeedFilterChanged(): void {
    this.load();
  }

  private async loadAccount(): Promise<void> {
    const account = await accountRepository.active();
    if (account) {
      this.activeAccountLabel = `${account.name} · ${accountTypeName(account.type)}`;
    }
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

  aboutToAppear(): void {
    this.loadAccount();
    this.load();
    if (settingsStore.get().syncOnLaunch) {
      this.sync();
    }
  }

  private async load(): Promise<void> {
    try {
      const allFeeds: Feed[] = await rssRepository.listFeeds();
      this.feeds = settingsStore.get().onlyUnreadFeeds
        ? allFeeds.filter((feed: Feed) => feed.unreadCount > 0)
        : allFeeds;
      const allGroups: FeedGroup[] = await rssRepository.listGroups();
      // Hide groups that have no visible feeds.
      this.groups = allGroups.filter((group: FeedGroup) =>
        this.feeds.some((feed: Feed) => feed.groupId === group.id)
      );
      FeedIcon.prefetch(this.getUIContext().getHostContext() as common.Context, this.feeds);
      this.bannerCount = await rssRepository.articleCount(this.currentFilter);
    } finally {
      this.isLoading = false;
    }
  }

  private filterName(): string {
    if (this.currentFilter === FILTER_STARRED) return '星标';
    if (this.currentFilter === FILTER_ALL) return '全部';
    return '未读';
  }

  /** Android FeedsBanner: click opens Flow with global scope (group=null, feed=null). */
  private openGlobalFlow(): void {
    openFlow('', `${this.filterName()}文章`);
  }

  private async sync(): Promise<void> {
    // isRefreshing is controlled by Refresh's two-way binding (already true on pull).
    // Use a separate guard to avoid skipping the request.
    if (this.isSyncing) {
      return;
    }
    this.isSyncing = true;
    this.isRefreshing = true;
    try {
      const result = await rssRepository.syncAll();
      await this.load();
      this.getUIContext().getPromptAction().showToast({
        message: `同步完成：${result.succeeded} 个源，新增 ${result.newArticles} 篇，失败 ${result.failed} 个`,
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `同步失败：${(error as Error).message}` });
    } finally {
      this.isSyncing = false;
      this.isRefreshing = false;
    }
  }

  private async markAllRead(): Promise<void> {
    await rssRepository.markAllRead('');
    await this.load();
    this.getUIContext().getPromptAction().showToast({ message: '已全部标为已读' });
  }

  private feedsInGroup(groupId: string): Feed[] {
    return this.feeds.filter((feed: Feed) => feed.groupId === groupId);
  }

  private ungroupedFeeds(): Feed[] {
    const ids: string[] = this.groups.map((group: FeedGroup) => group.id);
    return this.feeds.filter((feed: Feed) => ids.indexOf(feed.groupId) < 0);
  }

  @Builder
  groupHeader(name: string): void {
    Row() {
      Text(name).fontFamily(this.appFont())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.secondaryColor())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 6 })
    .backgroundColor(this.darkMode ? '#1A1D21' : '#F1F3F6')
  }

  @Builder
  feedRow(feed: Feed): void {
    ListItem() {
      this.feedItem(feed)
    }
    .onClick(() => openFlow(feed.id, feed.title))
    .swipeAction({
      end: {
        builder: () => { this.swipeDelete(feed); },
      },
    })
  }

  @Builder
  swipeDelete(feed: Feed): void {
    Row() {
      Button('取消订阅')
        .backgroundColor('#D93025')
        .fontColor(Color.White)
        .onClick(async () => {
          try {
            await rssRepository.removeFeed(feed.id);
            await this.load();
          } catch (error) {
            this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
          }
        })
    }
  }

  @Builder
  feedItem(feed: Feed): void {
    Row() {
      if (FeedIcon.src(feed.iconUrl).length > 0) {
        Image(FeedIcon.src(feed.iconUrl))
          .width(32)
          .height(32)
          .borderRadius(6)
          .margin({ right: 10 })
      } else {
        Image($r('app.media.ic_feeds'))
          .width(32)
          .height(32)
          .padding(6)
          .fillColor(this.secondaryColor())
          .margin({ right: 10 })
      }
      Column() {
        Text(feed.title).fontFamily(this.appFont())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(feed.url).fontFamily(this.appFont())
          .fontSize(12)
          .fontColor(this.secondaryColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (feed.unreadCount > 0) {
        Text(`${feed.unreadCount}`).fontFamily(this.appFont())
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor('#2663D6')
          .borderRadius(12)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .margin({ left: 12 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.surfaceColor())
  }


  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0 ? FontManager.family() : 'sans-serif';
  }

  build() {
    Stack() {
      Column() {
      Row() {
        if (this.asDestination) {
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
        Column() {
          Text(this.asDestination ? '订阅源' : 'ReadYou').fontFamily(this.appFont())
            .fontSize(this.asDestination ? 18 : 26)
            .fontWeight(this.asDestination ? FontWeight.Medium : FontWeight.Bold)
            .fontColor(this.textColor())
          if (!this.asDestination) {
            Text('订阅 · 阅读 · 稍后读').fontFamily(this.appFont())
              .fontSize(12)
              .fontColor(this.secondaryColor())
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button() {
          Image($r('app.media.ic_account'))
            .width(20)
            .height(20)
            .fillColor('#1A1C1E')
        }
        .type(ButtonType.Circle)
        .width(38)
        .height(38)
        .backgroundColor(Color.White)
        .onClick(() => openAccounts())

        if (!this.asDestination) {
          Button() {
            Image($r('app.media.ic_refresh'))
              .width(20)
              .height(20)
              .fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38)
          .height(38)
          .margin({ left: 8 })
          .backgroundColor(Color.White)
          .onClick(() => this.sync())
        }

        Button() {
          Image($r('app.media.ic_add'))
            .width(20)
            .height(20)
            .fillColor('#1A1C1E')
        }
        .type(ButtonType.Circle)
        .width(38)
        .height(38)
        .margin({ left: 8 })
        .backgroundColor(Color.White)
        .onClick(() => openSubscribe())

        Button() {
          Image($r('app.media.ic_settings'))
            .width(20)
            .height(20)
            .fillColor('#1A1C1E')
        }
        .type(ButtonType.Circle)
        .width(38)
        .height(38)
        .margin({ left: 8 })
        .backgroundColor(Color.White)
        .onClick(() => openSettings())
      }
      .width('100%')
      .padding({
        left: this.asDestination ? 12 : 20,
        right: this.asDestination ? 16 : 20,
        top: (this.asDestination ? 14 : 20),
        bottom: this.asDestination ? 14 : 16,
      })

      if (!this.asDestination) {
        Row() {
          Text('订阅源').fontFamily(this.appFont())
            .fontSize(14)
            .fontColor(this.secondaryColor())
          Blank()
          Text('全部已读').fontFamily(this.appFont())
            .fontSize(14)
            .fontColor('#2663D6')
            .onClick(() => this.markAllRead())
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 10 })
      }

      // With "only unread feeds" enabled, an empty result is normal: keep the
      // banner and list layout instead of showing a big centered empty state.
      if (this.feeds.length === 0 && !this.isLoading && !settingsStore.get().onlyUnreadFeeds) {
        Column() {
          Text('还没有订阅源').fontFamily(this.appFont())
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
          Text('点击右上角 + 添加 RSS 地址开始阅读').fontFamily(this.appFont())
            .fontSize(14)
            .fontColor(this.secondaryColor())
            .margin({ top: 8 })
          Button('添加订阅')
            .margin({ top: 24 })
            .onClick(() => openSubscribe())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // Banner lives outside the List so no list/refresh inset can add blank space.
        if (!this.asDestination) {
          Row() {
            Column() {
              Text(this.filterName()).fontFamily(this.appFont())
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.textColor())
              Text(`查看全部${this.filterName()}文章 · ${this.bannerCount} 篇`).fontFamily(this.appFont())
                .fontSize(13)
                .fontColor(this.secondaryColor())
                .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('→').fontFamily(this.appFont()).fontSize(20).fontColor(this.secondaryColor())
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(this.surfaceColor())
          .onClick(() => this.openGlobalFlow())
        }

        Refresh({ refreshing: $$this.isRefreshing }) {
          List() {
            ForEach(this.groups, (group: FeedGroup) => {
              ListItem() {
                this.groupHeader(group.name)
              }
              ForEach(this.feedsInGroup(group.id), (feed: Feed) => {
                this.feedRow(feed)
              }, (feed: Feed) => feed.id)
            }, (group: FeedGroup) => group.id)

            if (this.ungroupedFeeds().length > 0) {
              ListItem() {
                this.groupHeader('未分组')
              }
              ForEach(this.ungroupedFeeds(), (feed: Feed) => {
                this.feedRow(feed)
              }, (feed: Feed) => feed.id)
            }

            if (!this.asDestination && this.feeds.length > 0) {
              ListItem() {
                Row().width('100%').height(72)
              }
            }
          }
          .width('100%')
          .height('100%')
          .divider({ strokeWidth: 1, color: this.darkMode ? '#2A2D31' : '#ECEFF2' })
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => this.sync())
      }

      }
      .width('100%')
      .height('100%')

      // HarmonyOS 7 floating filter tab bar, only on the home page.
      if (!this.asDestination) {
        FilterBarView({
          onFilterChange: (filter: string) => {
            this.currentFilter = filter;
            this.load();
          },
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')
    .alignContent(Alignment.Bottom)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
