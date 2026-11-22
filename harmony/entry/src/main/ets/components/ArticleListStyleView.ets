import { FontManager } from '../common/FontManager';
import { goBack, openFontPicker } from '../common/NavigationService';
import { settingsStore } from '../data/SettingsStore';
import { Article } from '../model/Models';
import { ArticleRowView } from './ArticleRowView';
import {
  DESC_LONG, DESC_NONE, DESC_SHORT,
  SWIPE_NONE, SWIPE_TOGGLE_READ, SWIPE_TOGGLE_STARRED,
} from '../common/Constants';

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
  // Article-list behavior settings. Kept as local @State so taps always update
  // the controls/preview immediately; setters persist + publish to AppStorage
  // for the article list. Initialized from the store in aboutToAppear.
  @State sortEarliest: boolean = false;
  @State swipeStart: number = SWIPE_TOGGLE_STARRED;
  @State swipeEnd: number = SWIPE_TOGGLE_READ;
  @State showFeedIcon: boolean = true;
  @State showFeedName: boolean = true;
  @State showArticleImage: boolean = false;
  @State descLength: number = DESC_LONG;

  aboutToAppear(): void {
    this.fontKey = settingsStore.get().articleFontFamily;
    const s = settingsStore.get();
    this.sortEarliest = s.sortUnreadEarliest;
    this.swipeStart = s.swipeStartAction;
    this.swipeEnd = s.swipeEndAction;
    this.showFeedIcon = s.showFeedIcon;
    this.showFeedName = s.showFeedName;
    this.showArticleImage = s.showArticleImage;
    this.descLength = s.articleDescLength;
  }

  onFontChanged(): void {
    this.fontKey = this.fontKeyProp;
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

  /** Fixed preview: reuses the exact same row component as the real list, so
   *  the preview can never drift from what the article list renders. */
  @Builder
  previewRow(): void {
    ArticleRowView({
      article: {
        id: 'preview', feedId: 'preview', feedTitle: '示例订阅源',
        title: '这是一篇文章的标题，用来预览标题字号的实际效果',
        author: '', link: '',
        summary: '这是摘要文字，用来预览摘要字号。RSS 文章通常会有一段简要介绍，这里作为占位内容展示实际效果。',
        content: '', fullContent: '', imageUrl: 'preview',
        publishedAt: 0, isRead: false, isStarred: false,
      } as Article,
      feedIconSrc: '',
      dateTextOverride: '11-21',
      preview: true,
    })
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

  /** Icon resource for a swipe action (Android icon-based options). */
  private swipeIcon(action: number): Resource {
    if (action === SWIPE_TOGGLE_READ) {
      return $r('app.media.ic_mark_read');
    }
    if (action === SWIPE_TOGGLE_STARRED) {
      return $r('app.media.ic_filter_star');
    }
    return $r('app.media.ic_filter_all');
  }

  private swipeLabel(action: number): string {
    if (action === SWIPE_TOGGLE_READ) return '标已读/未读';
    if (action === SWIPE_TOGGLE_STARRED) return '收藏/取消收藏';
    return '无';
  }

  private descLabel(): string {
    if (this.descLength === DESC_NONE) return '不显示';
    if (this.descLength === DESC_LONG) return '长（3 行）';
    return '短（2 行）';
  }

  private sortLabel(): string {
    return this.sortEarliest ? '最早在前' : '最新在前';
  }

  /** Surface used for the option buttons (a subtle raised chip). */
  private chipColor(selected: boolean): string {
    if (selected) return this.darkMode ? '#2A2D31' : '#E8EEFB';
    return this.darkMode ? '#26292D' : '#F1F3F5';
  }

  private chipText(selected: boolean): string {
    return selected ? '#2663D6' : this.secondaryColor();
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

        // Fixed preview: stays visible and live-updates while settings scroll below.
        Column() {
          Text('预览').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
            .width('100%').textAlign(TextAlign.Start)
            .padding({ left: 16, bottom: 8 })
          this.previewRow()
        }
        .width('100%')
        // Match the Scroll content's left/right 12 so the preview card and its
        // "预览" label line up with 字号与字体 and the setting cards below.
        .padding({ left: 12, right: 12, top: 4, bottom: 8 })

        Scroll() {
          Column() {
            Text('字号与字体').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start)
              .padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })

            // Grouped card with dividers between rows.
            Column() {
              // Label + slider + value all on one row.
              Row() {
                Text('标题字号').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(96 * this.fontScale).maxLines(1)
                Slider({ value: this.titleSize, min: 12, max: 26, step: 1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.titleSize = value;
                    settingsStore.setArticleTitleFontSize(value);
                  })
                Text(`${this.titleSize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(24)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Text('摘要字号').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(96 * this.fontScale).maxLines(1)
                Slider({ value: this.summarySize, min: 11, max: 24, step: 1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.summarySize = value;
                    settingsStore.setArticleSummaryFontSize(value);
                  })
                Text(`${this.summarySize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(24)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Text('订阅源与时间').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  .width(96 * this.fontScale).maxLines(1)
                Slider({ value: this.metaSize, min: 10, max: 20, step: 1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.metaSize = value;
                    settingsStore.setArticleMetaFontSize(value);
                  })
                Text(`${this.metaSize}`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(24)
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
              .onClick(() => openFontPicker('article'))
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)

            Text('排序与显示').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start)
              .padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })

            Column() {
              // Display toggles.
              Row() {
                Text('显示订阅源图标').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
                Toggle({ isOn: this.showFeedIcon, type: ToggleType.Switch })
                  .onChange((value: boolean) => {
                    this.showFeedIcon = value;
                    settingsStore.setShowFeedIcon(value);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })

              this.divider()

              Row() {
                Text('显示订阅源名称').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
                Toggle({ isOn: this.showFeedName, type: ToggleType.Switch })
                  .onChange((value: boolean) => {
                    this.showFeedName = value;
                    settingsStore.setShowFeedName(value);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })

              this.divider()

              Row() {
                Text('显示文章图片').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).layoutWeight(1)
                Toggle({ isOn: this.showArticleImage, type: ToggleType.Switch })
                  .onChange((value: boolean) => {
                    this.showArticleImage = value;
                    settingsStore.setShowArticleImage(value);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })

              this.divider()

              // Summary length — options inlined so @State drives the selected chip.
              Row() {
                Column() {
                  Text('摘要长度').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text(this.descLabel()).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  ForEach([DESC_NONE, DESC_SHORT, DESC_LONG], (value: number, idx: number) => {
                    Text(value === DESC_NONE ? '无' : (value === DESC_SHORT ? '短' : '长'))
                      .fontSize(this.fs(15))
                      .fontFamily(this.appFont())
                      .fontColor(this.chipText(this.descLength === value))
                      .width(44).height(44)
                      .textAlign(TextAlign.Center)
                      .backgroundColor(this.chipColor(this.descLength === value))
                      .borderRadius(12)
                      .margin({ left: idx === 0 ? 0 : 8 })
                      .onClick(() => {
                        this.descLength = value;
                        settingsStore.setArticleDescLength(value);
                      })
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })

              this.divider()

              // Unread sort — moved to right after summary length.
              Row() {
                Column() {
                  Text('未读排序').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text(this.sortLabel()).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  ForEach([false, true], (earliest: boolean, idx: number) => {
                    Text(earliest ? '最早' : '最新')
                      .fontSize(this.fs(15))
                      .fontFamily(this.appFont())
                      .fontColor(this.chipText(this.sortEarliest === earliest))
                      .width(52).height(44)
                      .textAlign(TextAlign.Center)
                      .backgroundColor(this.chipColor(this.sortEarliest === earliest))
                      .borderRadius(12)
                      .margin({ left: idx === 0 ? 0 : 8 })
                      .onClick(() => {
                        this.sortEarliest = earliest;
                        settingsStore.setSortUnreadEarliest(earliest);
                      })
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .borderRadius(10)

            Text('滑动动作').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start)
              .padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })

            Column() {
              Row() {
                Column() {
                  Text('向右滑').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text(this.swipeLabel(this.swipeStart)).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                // Icon chips, inlined so @State drives the selected state.
                Row() {
                  ForEach([SWIPE_NONE, SWIPE_TOGGLE_READ, SWIPE_TOGGLE_STARRED], (value: number, idx: number) => {
                    Row() {
                      Image(this.swipeIcon(value))
                        .width(22).height(22)
                        .fillColor(this.chipText(this.swipeStart === value))
                    }
                    .width(44).height(44)
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(this.chipColor(this.swipeStart === value))
                    .borderRadius(12)
                    .margin({ left: idx === 0 ? 0 : 8 })
                    .onClick(() => {
                      this.swipeStart = value;
                      settingsStore.setSwipeStartAction(value);
                    })
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })

              this.divider()

              Row() {
                Column() {
                  Text('向左滑').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text(this.swipeLabel(this.swipeEnd)).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  ForEach([SWIPE_NONE, SWIPE_TOGGLE_READ, SWIPE_TOGGLE_STARRED], (value: number, idx: number) => {
                    Row() {
                      Image(this.swipeIcon(value))
                        .width(22).height(22)
                        .fillColor(this.chipText(this.swipeEnd === value))
                    }
                    .width(44).height(44)
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(this.chipColor(this.swipeEnd === value))
                    .borderRadius(12)
                    .margin({ left: idx === 0 ? 0 : 8 })
                    .onClick(() => {
                      this.swipeEnd = value;
                      settingsStore.setSwipeEndAction(value);
                    })
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
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
