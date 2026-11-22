import { FontManager } from '../common/FontManager';
import { goBack, openFontPicker } from '../common/NavigationService';
import { settingsStore } from '../data/SettingsStore';

/** Appearance settings for the full-text reader, with a live preview on top. */
@Component
export struct ReaderStyleView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('readerFontFamily') @Watch('onFontChanged') fontKeyProp: string = 'sans-serif';
  // Same AppStorage keys the reader HTML uses, to avoid preview/real drift.
  @StorageProp('readerBodyFontSize') bodySize: number = 17;
  @StorageProp('readerPageMargin') pageMargin: number = 16;
  @StorageProp('readerLineSpacing') lineSpacing: number = 1.75;
  @State fontKey: string = 'sans-serif';

  aboutToAppear(): void {
    this.fontKey = settingsStore.get().readerFontFamily;
  }

  onFontChanged(): void {
    this.fontKey = this.fontKeyProp;
  }

  private fontFamily(): string {
    // Reading fontDataTick makes custom-font registration refresh the preview.
    return this.fontDataTick >= 0 ? FontManager.familyFor(this.fontKey) : 'sans-serif';
  }

  /** UI chrome follows the system-wide font selection. */
  private appFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
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

  private surfaceColor(): string {
    return this.darkMode ? '#1F2226' : '#FFFFFF';
  }

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  // Match WebViewStyle.get() so the preview uses the reader's exact colors.
  private readerTextColor(): string {
    return this.darkMode ? '#E8EAED' : '#191C1E';
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
              .width(19).height(19).fillColor('#1A1C1E')
          }
          .type(ButtonType.Circle)
          .width(38).height(38).backgroundColor(Color.White)
          .margin({ right: 8 })
          .onClick(() => goBack())
          Text('全文阅读').fontSize(this.fs(19)).fontFamily(this.appFont()).fontWeight(FontWeight.Medium).fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 12 })

        // Fixed preview: stays visible and live-updates while settings scroll below.
        // Matching left/right 12 so the label and card align with sections below.
        Column() {
          Text('预览').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
            .width('100%').textAlign(TextAlign.Start)
            .padding({ left: 16, bottom: 8 })
          // Fixed-height Scroll: when the body text grows, the preview scrolls
          // internally instead of being clipped, so all text stays viewable while
          // the settings Scroll below is never squeezed to zero (unreachable sliders).
          Scroll() {
            Column() {
              // Real articles render the body as plain paragraphs at exactly
              // the configured font-size / line-height (CSS: font-size: Npx,
              // line-height: M). The preview must use the same values — no
              // simulated heading, which would be larger than real body text.
              // Reader CSS sets p margin to 1em bottom / 0 top (adjacent
              // margins collapse to a single 1em gap). Mirror that here: a
              // single bottom margin per paragraph, no top margin.
              Text('第一段占位文字，用来实时预览正文字号、行距和字体。调整下方滑块，这里会立即按照实际全文阅读的样式变化。')
                .fontFamily(this.fontFamily())
                .fontSize(this.bodySize)
                .fontColor(this.readerTextColor())
                .lineHeight(this.bodySize * this.lineSpacing)
                .margin({ bottom: this.bodySize })
                .alignSelf(ItemAlign.Start)
              Text('第二段占位文字。全文阅读的正文会以设置的字号、页边距和行距显示，段落之间保留一个字号的间距。')
                .fontFamily(this.fontFamily())
                .fontSize(this.bodySize)
                .fontColor(this.readerTextColor())
                .lineHeight(this.bodySize * this.lineSpacing)
                .margin({ bottom: this.bodySize })
                .alignSelf(ItemAlign.Start)
              Text('第三段占位文字，同样使用正文样式。行距变化会直接影响整段文字的疏密程度。')
                .fontFamily(this.fontFamily())
                .fontSize(this.bodySize)
                .fontColor(this.readerTextColor())
                .lineHeight(this.bodySize * this.lineSpacing)
                .alignSelf(ItemAlign.Start)
            }
            .width('100%')
            .padding({
              left: this.pageMargin, right: this.pageMargin, top: this.pageMargin, bottom: this.pageMargin,
            })
          }
          .width('100%')
          .height(200)
          .backgroundColor(this.surfaceColor())
          .borderRadius(10)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 8 })

        Scroll() {
          Column() {
            Text('排版').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start)
              .padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })

            // Grouped card with dividers between rows; label + slider + value on one row.
            Column() {
              Row() {
                Text('正文字号').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(72)
                Slider({ value: this.bodySize, min: 12, max: 30, step: 1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.bodySize = value;
                    settingsStore.setReaderBodyFontSize(value);
                  })
                Text(`${this.bodySize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(24)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Text('页边距').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(72)
                Slider({ value: this.pageMargin, min: 0, max: 40, step: 1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.pageMargin = value;
                    settingsStore.setReaderPageMargin(value);
                  })
                Text(`${this.pageMargin}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(24)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Text('行距').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(72)
                Slider({ value: this.lineSpacing, min: 1.0, max: 2.5, step: 0.05, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.lineSpacing = value;
                    settingsStore.setReaderLineSpacing(value);
                  })
                Text(this.lineSpacing.toFixed(2)).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(32)
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
              .onClick(() => openFontPicker('reader'))
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
