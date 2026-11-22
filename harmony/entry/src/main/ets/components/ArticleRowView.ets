import { Article } from '../model/Models';
import { DESC_LONG, DESC_NONE, DESC_SHORT } from '../common/Constants';
import { FontManager } from '../common/FontManager';

/**
 * Shared article-row layout used by BOTH the real article list
 * (ArticleListView.articleItem) and the Settings > Article List live preview.
 * A single implementation keeps the preview from drifting away from the list.
 *
 * All display settings are read from AppStorage (@StorageProp) so any change
 * applies live in both places without prop-drilling or stale @Builder values.
 */
@Component
export struct ArticleRowView {
  @Prop article: Article;
  // Resolved feed-icon src; empty falls back to app_icon (matches real list).
  @Prop feedIconSrc: string = '';
  // Preview passes a fixed date label; the real list formats publishedAt.
  @Prop dateTextOverride: string = '';
  // Preview uses a placeholder thumbnail instead of article.imageUrl.
  @Prop preview: boolean = false;
  // Optional; when set, the row reacts to long press (real list only).
  onLongPress: () => void = () => {};

  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontScale') fontScale: number = 1;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('articleTitleFontSize') articleTitleFontSize: number = 17;
  @StorageProp('articleSummaryFontSize') articleSummaryFontSize: number = 15;
  @StorageProp('articleMetaFontSize') articleMetaFontSize: number = 13;
  @StorageProp('articleFontFamily') articleFontFamily: string = 'sans-serif';
  @StorageProp('articleDescLength') articleDescLength: number = DESC_SHORT;
  @StorageProp('showFeedIcon') showFeedIcon: boolean = true;
  @StorageProp('showFeedName') showFeedName: boolean = true;
  @StorageProp('showArticleImage') showArticleImage: boolean = true;

  private fs(size: number): number { return size * this.fontScale; }

  private listFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.articleFontFamily) : 'sans-serif';
  }

  private appFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  private textColor(): string { return this.darkMode ? '#E8EAED' : '#1A1C1E'; }
  private secondaryColor(): string { return this.darkMode ? '#9AA0A6' : '#5E636A'; }
  private readColor(): string { return this.darkMode ? '#6B7076' : '#9AA0A6'; }
  private surfaceColor(): string { return this.darkMode ? '#1F2226' : '#FFFFFF'; }

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

  private dateText(): string {
    return this.dateTextOverride.length > 0
      ? this.dateTextOverride : this.formatDate(this.article.publishedAt);
  }

  build() {
    Column() {
      // Content row: text block + optional thumbnail (only this row is squeezed).
      Row() {
        Column() {
          Text(this.article.title).fontFamily(this.listFont())
            .fontSize(this.articleTitleFontSize * this.fontScale)
            .fontWeight(this.article.isRead ? FontWeight.Normal : FontWeight.Medium)
            .fontColor(this.article.isRead ? this.readColor() : this.textColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // Summary length follows the "摘要长度" setting.
          if (this.articleDescLength !== DESC_NONE && this.article.summary.length > 0) {
            Text(this.article.summary).fontFamily(this.listFont())
              .fontSize(this.articleSummaryFontSize * this.fontScale)
              .fontColor(this.article.isRead ? this.readColor() : this.secondaryColor())
              .maxLines(this.articleDescLength === DESC_LONG ? 3 : 2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 * this.fontScale })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // Optional thumbnail on the right.
        if (this.showArticleImage) {
          if (this.preview) {
            Image($r('app.media.app_icon'))
              .width(64).height(64).borderRadius(6)
              .objectFit(ImageFit.Cover).margin({ left: 10 })
              .syncLoad(true)
          } else if (this.article.imageUrl.length > 0) {
            Image(this.article.imageUrl)
              .width(64).height(64).borderRadius(6)
              .objectFit(ImageFit.Cover).margin({ left: 10 })
              .syncLoad(false)
          }
        }
      }
      .width('100%')

      // Full-width meta row so the date right-aligns with/without a thumbnail.
      Row() {
        if (this.showFeedIcon) {
          if (this.feedIconSrc.length > 0) {
            Image(this.feedIconSrc)
              .width(14).height(14).borderRadius(3).syncLoad(true).margin({ right: 4 })
          } else {
            Image($r('app.media.app_icon'))
              .width(14).height(14).borderRadius(3).syncLoad(true).margin({ right: 4 })
          }
        }
        if (this.showFeedName) {
          Text(this.article.feedTitle).fontFamily(this.listFont())
            .fontSize(this.articleMetaFontSize * this.fontScale)
            .fontColor(this.article.isRead ? this.readColor() : this.secondaryColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Blank()
        }
        if (this.article.isStarred) {
          Text('★').fontFamily(this.appFont()).fontSize(this.fs(12)).fontColor('#F9A825')
            .margin({ right: 6 })
        }
        Text(this.dateText()).fontFamily(this.listFont())
          .fontSize(this.articleMetaFontSize * this.fontScale)
          .fontColor(this.article.isRead ? this.readColor() : this.secondaryColor())
      }
      .width('100%')
      .margin({ top: 6 * this.fontScale })
    }
    .width('100%')
    .padding({
      left: 16, right: 16,
      top: 14 * this.fontScale, bottom: 14 * this.fontScale,
    })
    .backgroundColor(this.surfaceColor())
    .gesture(LongPressGesture().onAction(() => this.onLongPress()))
  }
}
