import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { settingsStore } from '../data/SettingsStore';
import { rssRepository } from '../rss/RssRepository';
import { goBack, openAccounts } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';
import { fontScaleForIndex } from '../common/Constants';

/** Minimal settings screen covering the preferences that affect the MVP. */
@Component
export struct SettingsView {
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @State syncOnLaunch: boolean = true;
  @State markReadOnOpen: boolean = true;
  @State fontSizeIndex: number = 1;
  @State customFontPath: string = '';
  @State markReadOnScroll: boolean = false;
  @State keepArticleDays: number = 30;
  @State fetchBatchSize: number = 100;

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
    this.fontSizeIndex = settings.fontSizeIndex;
    this.customFontPath = settings.customFontPath;
    this.markReadOnScroll = settings.markReadOnScroll;
    this.keepArticleDays = settings.keepArticleDays;
    this.fetchBatchSize = settings.fetchBatchSize;
  }

  private applyFontSize(index: number): void {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext) {
      (hostContext as common.Context).getApplicationContext()
        .setFontSizeScale(fontScaleForIndex(index));
    }
    AppStorage.set<number>('fontScale', fontScaleForIndex(index));
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

  private fontSizeMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    const labels: string[] = ['小', '中', '大', '特大'];
    for (let i: number = 0; i < labels.length; i++) {
      const index: number = i;
      items.push({
        value: labels[i],
        action: () => {
          this.fontSizeIndex = index;
          settingsStore.setFontSizeIndex(index);
          this.applyFontSize(index);
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

  private fontSizeLabel(): string {
    const labels: string[] = ['小', '中', '大', '特大'];
    return this.fontSizeIndex >= 0 && this.fontSizeIndex < labels.length
      ? labels[this.fontSizeIndex] : '中';
  }

  private async chooseFont(): Promise<void> {
    const hostContext = this.getUIContext().getHostContext();
    if (!hostContext) {
      return;
    }
    const path: string = await FontManager.pickAndInstall(hostContext as common.Context);
    if (path.length === 0) {
      return;
    }
    await settingsStore.setCustomFontPath(path);
    this.customFontPath = path;
    FontManager.register(this.getUIContext(), path);
    AppStorage.set<number>('fontDataTick', Date.now());
    this.getUIContext().getPromptAction().showToast({ message: '自定义字体已启用' });
  }

  private async resetFont(): Promise<void> {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext) {
      FontManager.remove(hostContext as common.Context);
    }
    await settingsStore.setCustomFontPath('');
    this.customFontPath = '';
    AppStorage.set<number>('fontDataTick', Date.now());
    this.getUIContext().getPromptAction().showToast({ message: '已恢复默认字体' });
  }

  private applyColorMode(dark: boolean): void {
    this.darkMode = dark;
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext) {
        const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
        context.getApplicationContext().setColorMode(
          dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
               : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        );
      }
    } catch (error) {
      // Ignore on form factors without explicit color mode control.
    }
  }


  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0 ? FontManager.family() : 'sans-serif';
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
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 20 })

        Row() {
          Column() {
            Text('账号管理').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
            Text('本地 / Fever / Google Reader / FreshRSS').fontFamily(this.appFont())
              .fontSize(12).fontColor(this.secondaryColor()).margin({ top: 3 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text('→').fontFamily(this.appFont()).fontSize(18).fontColor('#2663D6')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .backgroundColor(this.surfaceColor())
        .margin({ bottom: 16 })
        .onClick(() => openAccounts())

        Scroll() {
          Column() {
            Text('外观').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor())
              .margin({ left: 4, bottom: 8 })
            Row() {
              Column() {
                Text('深色模式').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                Text('跟随应用设置').fontFamily(this.appFont()).fontSize(12).fontColor(this.secondaryColor()).margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ isOn: this.darkMode, type: ToggleType.Switch })
                .onChange((value: boolean) => {
                  settingsStore.setDarkMode(value);
                  this.applyColorMode(value);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.surfaceColor())

            Text('阅读').fontFamily(this.appFont()).fontSize(13).fontColor(this.secondaryColor())
              .margin({ left: 4, top: 24, bottom: 8 })
            Row() {
              Column() {
                Text('启动时同步').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                Text('打开应用时自动刷新订阅').fontFamily(this.appFont()).fontSize(12).fontColor(this.secondaryColor()).margin({ top: 3 })
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
            .backgroundColor(this.surfaceColor())

            Row() {
              Column() {
                Text('打开文章即标已读').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                Text('进入阅读页后标记为已读').fontFamily(this.appFont()).fontSize(12).fontColor(this.secondaryColor()).margin({ top: 3 })
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
            .backgroundColor(this.surfaceColor())

            Row() {
              Column() {
                Text('滚动标记已读').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                Text('滚动出屏幕的文章自动标为已读').fontFamily(this.appFont())
                  .fontSize(12).fontColor(this.secondaryColor()).margin({ top: 3 })
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
            .backgroundColor(this.surfaceColor())

            Column() {
              Row() {
                Text('每次拉取条数').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                  .layoutWeight(1)
                Row() {
                  Text(`${this.fetchBatchSize}`).fontFamily(this.appFont())
                    .fontSize(14).fontColor(this.secondaryColor())
                  Text('›').fontSize(18).fontColor(this.secondaryColor()).margin({ left: 4 })
                }
                .bindMenu(this.fetchBatchMenu(), { placement: Placement.BottomRight })
              }
              .width('100%')
              Text('同步时每批拉取并入库的文章数量')
                .fontFamily(this.appFont()).fontSize(12).fontColor(this.secondaryColor())
                .margin({ top: 6 })
                .alignSelf(ItemAlign.Start)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.surfaceColor())

            Column() {
              Row() {
                Text('保留文章时间').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                  .layoutWeight(1)
                Row() {
                  Text(this.keepDaysLabel()).fontFamily(this.appFont())
                    .fontSize(14).fontColor(this.secondaryColor())
                  Text('›').fontSize(18).fontColor(this.secondaryColor()).margin({ left: 4 })
                }
                .bindMenu(this.keepDaysMenu(), { placement: Placement.BottomRight })
              }
              .width('100%')
              Text('清理超过该时间的文章')
                .fontFamily(this.appFont()).fontSize(12).fontColor(this.secondaryColor())
                .margin({ top: 6 })
                .alignSelf(ItemAlign.Start)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.surfaceColor())

            Row() {
              Text('正文字号').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor()).layoutWeight(1)
              Row() {
                Text(this.fontSizeLabel()).fontFamily(this.appFont())
                  .fontSize(14).fontColor(this.secondaryColor())
                Text('›').fontSize(18).fontColor(this.secondaryColor()).margin({ left: 4 })
              }
              .bindMenu(this.fontSizeMenu(), { placement: Placement.BottomRight })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.surfaceColor())

            Column() {
              Row() {
                Column() {
                  Text('自定义字体').fontFamily(this.appFont()).fontSize(15).fontColor(this.textColor())
                  Text(this.customFontPath.length > 0 ? '已启用（重启应用完全生效）' : '当前使用系统默认字体').fontFamily(this.appFont())
                    .fontSize(12).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text('选择').fontFamily(this.appFont())
                  .fontSize(14)
                  .fontColor('#2663D6')
                  .padding({ left: 8, right: 8 })
                  .onClick(() => this.chooseFont())
                if (this.customFontPath.length > 0) {
                  Text('恢复').fontFamily(this.appFont())
                    .fontSize(14)
                    .fontColor(this.secondaryColor())
                    .padding({ right: 8 })
                    .onClick(() => this.resetFont())
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .backgroundColor(this.surfaceColor())
              .margin({ top: 16 })
            }
            .width('100%')

            Column() {
              Text('调试').fontFamily(this.appFont()).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.textColor())
              Text('清除全文缓存（重新打开文章将使用新的提取算法）')
                .fontFamily(this.appFont())
                .fontSize(13).fontColor('#2663D6')
                .margin({ top: 10 })
                .onClick(async () => {
                  await rssRepository.clearFullContentCache();
                  this.getUIContext().getPromptAction().showToast({ message: '全文缓存已清除' });
                })
              Text('关于').fontFamily(this.appFont()).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.textColor())
                .margin({ top: 20 })
              Text('ReadYou HarmonyOS 版 · v0.1.0').fontFamily(this.appFont())
                .fontSize(13).fontColor(this.secondaryColor()).margin({ top: 10 })
                .margin({ bottom: 16 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(this.surfaceColor())
            .margin({ top: 24 })
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 32 })
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
