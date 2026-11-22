import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { FontManager } from '../common/FontManager';
import { goBack, openFontPicker } from '../common/NavigationService';
import { settingsStore } from '../data/SettingsStore';

/** System-wide appearance: text scale, font family and dark mode. */
@Component
export struct SystemStyleView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') @Watch('onFontChanged') fontKeyProp: string = 'sans-serif';
  @State fontScaleValue: number = 1.0;
  @State fontKey: string = 'sans-serif';

  aboutToAppear(): void {
    const settings = settingsStore.get();
    this.fontScaleValue = settings.systemFontScale;
    this.fontKey = settings.systemFontFamily;
  }

  onFontChanged(): void {
    this.fontKey = this.fontKeyProp;
  }

  /** UI chrome follows the system-wide font selection. */
  private appFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.fontKeyProp) : 'sans-serif';
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

  private fontLabel(): string {
    if (this.fontKey === 'serif') return '衬线字体';
    if (this.fontKey === 'monospace') return '等宽字体';
    if (this.fontKey === 'custom') {
      const name: string = settingsStore.get().customFontName;
      return name.length > 0 ? name : '自定义字体';
    }
    return '系统默认';
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

  private applyScale(value: number): void {
    this.fontScaleValue = value;
    // Persist only. Views apply the scale explicitly by multiplying their
    // font sizes; setFontSizeScale does not re-layout already-rendered text.
    settingsStore.setSystemFontScale(value);
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
          Text('系统').fontSize(this.fs(19)).fontFamily(this.appFont()).fontWeight(FontWeight.Medium).fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 12 })

        Scroll() {
          Column() {
            Text('显示').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start).padding({ left: 16, bottom: 8 })
              .margin({ top: 16 })
            Column() {
              Row() {
                Column() {
                  Text('深色模式').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text('跟随应用设置').fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
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
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)

            Text('字体').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start).padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })
            Column() {
              Row() {
                Text('字号').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(72)
                Slider({ value: this.fontScaleValue, min: 0.8, max: 1.4, step: 0.05, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => { this.applyScale(value); })
                Text(`${Math.round(this.fontScaleValue * 100)}%`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(44)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Column() {
                  Text('字体').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text(this.fontLabel()).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Image($r('sys.media.ohos_ic_public_arrow_right'))
                  .width(18).height(18).fillColor(this.secondaryColor())
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => openFontPicker('system'))
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, bottom: 48 + this.bottomInset })
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
