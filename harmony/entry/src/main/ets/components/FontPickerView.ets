import { common } from '@kit.AbilityKit';
import { FontManager } from '../common/FontManager';
import { goBack } from '../common/NavigationService';
import { settingsStore } from '../data/SettingsStore';

interface SystemFontOption {
  key: string;
  label: string;
}

const SYSTEM_FONTS: SystemFontOption[] = [
  { key: 'sans-serif', label: '系统默认（无衬线）' },
  { key: 'serif', label: '衬线字体' },
  { key: 'monospace', label: '等宽字体' },
];

/** Font picker shared by the article-list and reader style pages. */
@Component
export struct FontPickerView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @Prop target: string = 'article';
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('articleFontFamily') articleFontFamily: string = 'sans-serif';
  @StorageProp('readerFontFamily') readerFontFamily: string = 'sans-serif';
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @State customInstalled: boolean = false;
  @State customName: string = '';

  aboutToAppear(): void {
    this.customInstalled = settingsStore.get().customFontPath.length > 0;
    this.customName = settingsStore.get().customFontName;
  }

  private selected(): string {
    if (this.target === 'reader') {
      return this.readerFontFamily;
    }
    if (this.target === 'system') {
      return this.systemFontFamily;
    }
    return this.articleFontFamily;
  }

  private select(key: string): void {
    if (this.target === 'reader') {
      settingsStore.setReaderFontFamily(key);
    } else if (this.target === 'system') {
      settingsStore.setSystemFontFamily(key);
      FontManager.setSystemFamily(key);
      AppStorage.setOrCreate<number>('fontDataTick', Date.now());
    } else {
      settingsStore.setArticleFontFamily(key);
    }
    goBack();
  }

  private async addCustom(): Promise<void> {
    const hostContext = this.getUIContext().getHostContext();
    if (!hostContext) {
      return;
    }
    const path: string = await FontManager.pickAndInstall(hostContext as common.Context);
    if (path.length === 0) {
      return;
    }
    await settingsStore.setCustomFontPath(path, FontManager.fontName());
    FontManager.register(this.getUIContext(), path);
    AppStorage.setOrCreate<number>('fontDataTick', Date.now());
    this.customInstalled = true;
    this.customName = FontManager.fontName();
    this.select('custom');
  }

  private async removeCustom(): Promise<void> {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext) {
      FontManager.remove(hostContext as common.Context);
    }
    await settingsStore.setCustomFontPath('');
    AppStorage.setOrCreate<number>('fontDataTick', Date.now());
    this.customInstalled = false;
    this.customName = '';
    if (this.selected() === 'custom') {
      this.select('sans-serif');
    }
  }

  /** UI chrome follows the system-wide font selection. */
  private appFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  private surfaceColor(): string {
    return this.darkMode ? '#1F2226' : '#FFFFFF';
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Button() {
            Image($r('app.media.ic_back'))
              .width(19).height(19).fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38).height(38).backgroundColor(Color.White)
          .margin({ right: 8 })
          .onClick(() => goBack())
          Text('字体').fontSize(this.fs(19)).fontFamily(this.appFont()).fontWeight(FontWeight.Medium).fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 12 })

        Scroll() {
          Column() {
            Text('系统字体').fontSize(this.fs(13)).fontColor(this.secondaryColor())
              .margin({ left: 4, bottom: 8 })

            ForEach(SYSTEM_FONTS, (option: SystemFontOption) => {
              Row() {
                Text(option.label)
                  .fontFamily(option.key)
                  .fontSize(this.fs(15))
                  .fontColor(this.textColor())
                  .layoutWeight(1)
                if (this.selected() === option.key) {
                  Text('✓').fontSize(this.fs(16)).fontFamily(this.appFont()).fontColor('#2663D6')
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .backgroundColor(this.surfaceColor())
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.select(option.key))
            }, (option: SystemFontOption) => option.key)

            Text('自定义字体').fontSize(this.fs(13)).fontColor(this.secondaryColor())
              .margin({ left: 4, top: 24, bottom: 8 })
            if (this.customInstalled) {
              Row() {
                Text(this.customName.length > 0 ? this.customName : '自定义字体')
                  .fontFamily(FontManager.familyFor('custom'))
                  .fontSize(this.fs(15)).fontColor(this.textColor()).layoutWeight(1)
                if (this.selected() === 'custom') {
                  Text('✓').fontSize(this.fs(16)).fontFamily(this.appFont()).fontColor('#2663D6')
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .backgroundColor(this.surfaceColor())
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.select('custom'))

              Row() {
                Text('移除自定义字体').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .backgroundColor(this.surfaceColor())
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.removeCustom())
            }
            Row() {
              Text('从文件添加自定义字体（.ttf / .otf）').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor('#2663D6')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.surfaceColor())
            .alignItems(VerticalAlign.Center)
            .onClick(() => this.addCustom())
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, bottom: 32 + this.bottomInset })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.darkMode ? '#15171A' : '#F7F8FA')
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
