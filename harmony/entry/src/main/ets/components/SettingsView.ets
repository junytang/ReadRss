import { settingsStore } from '../data/SettingsStore';
import { rssRepository } from '../rss/RssRepository';
import {
  goBack, openAccounts, openArticleListStyle, openReaderStyle, openSystemStyle,
} from '../common/NavigationService';
import { FontManager } from '../common/FontManager';
import { bundleManager } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { ToastUtil } from '../common/ToastUtil';

/** Minimal settings screen covering the preferences that affect the MVP. */
@Component
export struct SettingsView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @State syncOnLaunch: boolean = true;
  @State markReadOnOpen: boolean = true;
  @State markReadOnScroll: boolean = false;
  @State keepArticleDays: number = 30;
  @State fetchBatchSize: number = 100;
  @State versionLabel: string = 'v1.0.0';

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
    const settings = settingsStore.get();
    this.syncOnLaunch = settings.syncOnLaunch;
    this.markReadOnOpen = settings.markReadOnOpen;
    this.markReadOnScroll = settings.markReadOnScroll;
    this.keepArticleDays = settings.keepArticleDays;
    this.fetchBatchSize = settings.fetchBatchSize;
    this.loadVersion();
  }

  /** Read versionName (1.0.0) and versionCode (build number) from the manifest. */
  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      this.versionLabel = `v${info.versionName} (build ${info.versionCode})`;
    } catch (error) {
      Logger.warn(`getBundleInfoForSelfSync failed: ${(error as Error).message}`);
    }
  }

  private fetchBatchMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    for (const size of [50, 100, 200, 300, 500]) {
      items.push({
        value: `${size}`,
        action: () => {
          this.fetchBatchSize = size;
          settingsStore.setFetchBatchSize(size);
        },
      });
    }
    return items;
  }

  private keepDaysMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    const values: number[] = [7, 14, 30, 90];
    const labels: string[] = ['1周', '2周', '1月', '3月'];
    for (let i: number = 0; i < values.length; i++) {
      const days: number = values[i];
      items.push({
        value: labels[i],
        action: () => {
          this.keepArticleDays = days;
          settingsStore.setKeepArticleDays(days);
        },
      });
    }
    return items;
  }

  private keepDaysLabel(): string {
    if (this.keepArticleDays === 7) return '1周';
    if (this.keepArticleDays === 14) return '2周';
    if (this.keepArticleDays === 30) return '1月';
    if (this.keepArticleDays === 90) return '3月';
    return `${this.keepArticleDays}天`;
  }


  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  /** Thin divider between items inside a grouped settings card. */
  @Builder
  divider(): void {
    Row() {
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(this.darkMode ? '#2A2D31' : '#ECEFF2')
    }
    .width('100%')
    .padding({ left: 16 })
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
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
          Text('设置').fontFamily(this.appFont())
            .fontSize(this.fs(19))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 20 })

        Scroll() {
          Column() {
            Text('账号').fontFamily(this.appFont()).fontSize(this.fs(14)).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start).padding({ left: 16, bottom: 8 })
              .margin({ top: 16 })
            Column() {
              Row() {
                Column() {
                  Text('账号管理').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('本地 / Fever / Google Reader / FreshRSS').fontFamily(this.appFont())
                    .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Image($r('sys.media.ohos_ic_public_arrow_right'))
                  .width(18).height(18).fillColor(this.secondaryColor())
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => openAccounts())
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)

            Text('外观').fontFamily(this.appFont()).fontSize(this.fs(14)).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start).padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })
            Column() {
              Row() {
                Column() {
                  Text('系统').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('系统字号、字体与深色模式').fontFamily(this.appFont())
                    .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Image($r('sys.media.ohos_ic_public_arrow_right'))
                  .width(18).height(18).fillColor(this.secondaryColor())
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => openSystemStyle())

              this.divider()

              Row() {
                Column() {
                  Text('文章列表').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('标题、摘要、元信息的字号与字体').fontFamily(this.appFont())
                    .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Image($r('sys.media.ohos_ic_public_arrow_right'))
                  .width(18).height(18).fillColor(this.secondaryColor())
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => openArticleListStyle())

              this.divider()

              Row() {
                Column() {
                  Text('全文阅读').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('正文字号、页边距、行距与字体').fontFamily(this.appFont())
                    .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Image($r('sys.media.ohos_ic_public_arrow_right'))
                  .width(18).height(18).fillColor(this.secondaryColor())
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => openReaderStyle())
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)

            Text('阅读').fontFamily(this.appFont()).fontSize(this.fs(14)).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start).padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })
            Column() {
              Row() {
                Column() {
                  Text('启动时同步').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('打开应用时自动刷新订阅').fontFamily(this.appFont()).fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ isOn: this.syncOnLaunch, type: ToggleType.Switch })
                  .onChange((value: boolean) => {
                    this.syncOnLaunch = value;
                    settingsStore.setSyncOnLaunch(value);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })

              this.divider()

              Row() {
                Column() {
                  Text('打开文章即标已读').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('进入阅读页后标记为已读').fontFamily(this.appFont()).fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ isOn: this.markReadOnOpen, type: ToggleType.Switch })
                  .onChange((value: boolean) => {
                    this.markReadOnOpen = value;
                    settingsStore.setMarkReadOnOpen(value);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })

              this.divider()

              Row() {
                Column() {
                  Text('滚动标记已读').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('滚动出屏幕的文章自动标为已读').fontFamily(this.appFont())
                    .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ isOn: this.markReadOnScroll, type: ToggleType.Switch })
                  .onChange((value: boolean) => {
                    this.markReadOnScroll = value;
                    settingsStore.setMarkReadOnScroll(value);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })

              this.divider()

              Row() {
                Column() {
                  Text('每次拉取条数').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('同步时每批拉取并入库的文章数量')
                    .fontFamily(this.appFont()).fontSize(this.fs(13)).fontColor(this.secondaryColor())
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Text(`${this.fetchBatchSize}`).fontFamily(this.appFont())
                    .fontSize(this.fs(15)).fontColor(this.secondaryColor())
                  Image($r('sys.media.ohos_ic_public_arrow_right'))
                    .width(18).height(18).fillColor(this.secondaryColor()).margin({ left: 4 })
                }
                .alignItems(VerticalAlign.Center)
                .bindMenu(this.fetchBatchMenu(), { placement: Placement.BottomRight })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })

              this.divider()

              Row() {
                Column() {
                  Text('保留文章时间').fontFamily(this.appFont()).fontSize(this.fs(15)).fontColor(this.textColor())
                  Text('清理超过该时间的文章')
                    .fontFamily(this.appFont()).fontSize(this.fs(13)).fontColor(this.secondaryColor())
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Text(this.keepDaysLabel()).fontFamily(this.appFont())
                    .fontSize(this.fs(15)).fontColor(this.secondaryColor())
                  Image($r('sys.media.ohos_ic_public_arrow_right'))
                    .width(18).height(18).fillColor(this.secondaryColor()).margin({ left: 4 })
                }
                .alignItems(VerticalAlign.Center)
                .bindMenu(this.keepDaysMenu(), { placement: Placement.BottomRight })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)

            Column() {
              Text('调试').fontFamily(this.appFont()).fontSize(this.fs(15)).fontWeight(FontWeight.Medium).fontColor(this.textColor())
              Text('清除全文缓存')
                .fontFamily(this.appFont())
                .fontSize(this.fs(13)).fontColor('#2663D6')
                .margin({ top: 10 })
                .onClick(async () => {
                  await rssRepository.clearFullContentCache();
                  ToastUtil.show(this.getUIContext(), '全文缓存已清除');
                })
              Text('关于').fontFamily(this.appFont()).fontSize(this.fs(15)).fontWeight(FontWeight.Medium).fontColor(this.textColor())
                .margin({ top: 20 })
              Text(`ReadRss · ${this.versionLabel}`).fontFamily(this.appFont())
                .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 10 })
              Text('This version is a hard fork of Android ReadYou version.')
                .fontFamily(this.appFont())
                .fontSize(this.fs(13)).fontColor(this.secondaryColor()).margin({ top: 6 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)
            .margin({ top: 24 })
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 48 + this.bottomInset })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
