import { FontManager } from '../common/FontManager';
import { goBack, openFontPicker } from '../common/NavigationService';
import { settingsStore } from '../data/SettingsStore';

/** Appearance settings for article list rows, with a live preview on top. */
@Component
export struct ArticleListStyleView {
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('fontScale') fontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.fontScale; }
  @StorageProp('articleFontFamily') @Watch('onFontChanged') fontKeyProp: string = 'sans-serif';
  // Read from the same AppStorage keys as the real article rows, so the preview
  // can never drift from what the list actually renders.
  @StorageProp('articleTitleFontSize') titleSize: number = 17;
  @StorageProp('articleSummaryFontSize') summarySize: number = 15;
  @StorageProp('articleMetaFontSize') metaSize: number = 13;
  @State fontKey: string = 'sans-serif';

  aboutToAppear(): void {
    this.fontKey = settingsStore.get().articleFontFamily;
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
          Text('文章列表').fontSize(this.fs(19)).fontFamily(this.appFont()).fontWeight(FontWeight.Medium).fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 12 })

        Scroll() {
          Column() {
            Text('预览').fontSize(this.fs(13)).fontColor(this.secondaryColor())
              .margin({ left: 4, bottom: 8 })

            // Same structure as a real article row: icon + source on the left,
            // date on the right, title and summary taking full width above.
            Row() {
              Column() {
                Text('这是一篇文章的标题，用来预览标题字号的实际效果')
                  .fontFamily(this.fontFamily())
                  .fontSize(this.titleSize * this.fontScale)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.textColor())
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .alignSelf(ItemAlign.Start)
                Text('这是摘要文字，用来预览摘要字号。RSS 文章通常会有一段简要介绍，这里作为占位内容展示实际效果。')
                  .fontFamily(this.fontFamily())
                  .fontSize(this.summarySize * this.fontScale)
                  .fontColor(this.secondaryColor())
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 6 * this.fontScale })
                  .width('100%')
                  .alignSelf(ItemAlign.Start)
                Row() {
                  Image($r('app.media.app_icon'))
                    .width(14).height(14).borderRadius(3)
                    .syncLoad(true)
                    .margin({ right: 4 })
                  Text('示例订阅源')
                    .fontFamily(this.fontFamily())
                    .fontSize(this.metaSize * this.fontScale)
                    .fontColor(this.secondaryColor())
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .alignSelf(ItemAlign.Start)
                  Text('11-21')
                    .fontFamily(this.fontFamily())
                    .fontSize(this.metaSize * this.fontScale)
                    .fontColor(this.secondaryColor())
                    .alignSelf(ItemAlign.Start)
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
            .borderRadius(10)

            Text('字号与字体').fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .margin({ left: 4, top: 24, bottom: 8 })

            Column() {
              Row() {
                Text('标题字号').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
                Text(`${this.titleSize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              }
              .width('100%')
              Slider({
                value: this.titleSize, min: 12, max: 26, step: 1, style: SliderStyle.OutSet,
              })
                .width('100%')
                .onChange((value: number) => {
                  this.titleSize = value;
                  settingsStore.setArticleTitleFontSize(value);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 6 })
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.surfaceColor())

            Column() {
              Row() {
                Text('摘要字号').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
                Text(`${this.summarySize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              }
              .width('100%')
              Slider({
                value: this.summarySize, min: 11, max: 24, step: 1, style: SliderStyle.OutSet,
              })
                .width('100%')
                .onChange((value: number) => {
                  this.summarySize = value;
                  settingsStore.setArticleSummaryFontSize(value);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 6 })
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.surfaceColor())

            Column() {
              Row() {
                Text('订阅源与时间').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
                Text(`${this.metaSize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              }
              .width('100%')
              Slider({
                value: this.metaSize, min: 10, max: 20, step: 1, style: SliderStyle.OutSet,
              })
                .width('100%')
                .onChange((value: number) => {
                  this.metaSize = value;
                  settingsStore.setArticleMetaFontSize(value);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 6 })
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.surfaceColor())

            Row() {
              Column() {
                Text('字体').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                Text(this.fontLabel()).fontSize(this.fs(12)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Text('›').fontSize(this.fs(18)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.surfaceColor())
            .onClick(() => openFontPicker('article'))
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
