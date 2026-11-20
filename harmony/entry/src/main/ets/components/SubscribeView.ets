import { FeedSuggestion, SUGGESTED_FEEDS } from '../common/Constants';
import { rssRepository } from '../rss/RssRepository';
import { goBack } from '../common/NavigationService';
import { FontManager } from '../common/FontManager';

/** Add-subscription screen: URL entry plus a few suggested feeds. */
@Component
export struct SubscribeView {
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @State url: string = '';
  @State isSubmitting: boolean = false;
  @State errorMessage: string = '';

  private textColor(): string {
    return this.darkMode ? '#E8EAED' : '#1A1C1E';
  }

  private secondaryColor(): string {
    return this.darkMode ? '#9AA0A6' : '#5E636A';
  }

  private async submit(url: string): Promise<void> {
    if (url.trim().length === 0 || this.isSubmitting) {
      return;
    }
    this.isSubmitting = true;
    this.errorMessage = '';
    try {
      await rssRepository.subscribe(url);
      this.getUIContext().getPromptAction().showToast({ message: '订阅成功' });
      goBack();
    } catch (error) {
      this.errorMessage = `订阅失败：${(error as Error).message}`;
    } finally {
      this.isSubmitting = false;
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
          Text('添加订阅').fontFamily(this.appFont())
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 20 })

        Column() {
          Text('RSS / Atom 地址').fontFamily(this.appFont())
            .fontSize(14)
            .fontColor(this.secondaryColor())
            .alignSelf(ItemAlign.Start)

          TextInput({ placeholder: 'https://example.com/feed.xml' })
            .width('100%')
            .height(46)
            .margin({ top: 10 })
            .fontSize(15)
            .backgroundColor(this.darkMode ? '#1F2226' : '#FFFFFF')
            .fontColor(this.textColor())
            .onChange((value: string) => {
              this.url = value;
            })

          if (this.errorMessage.length > 0) {
            Text(this.errorMessage).fontFamily(this.appFont())
              .fontSize(13)
              .fontColor('#D93025')
              .margin({ top: 10 })
              .alignSelf(ItemAlign.Start)
          }

          Button(this.isSubmitting ? '正在抓取…' : '订阅')
            .width('100%')
            .height(44)
            .margin({ top: 20 })
            .enabled(!this.isSubmitting)
            .onClick(() => this.submit(this.url))

          Text('推荐订阅').fontFamily(this.appFont())
            .fontSize(14)
            .fontColor(this.secondaryColor())
            .margin({ top: 32, bottom: 8 })
            .alignSelf(ItemAlign.Start)

          ForEach(SUGGESTED_FEEDS, (suggestion: FeedSuggestion) => {
            Row() {
              Column() {
                Text(suggestion.title).fontFamily(this.appFont())
                  .fontSize(15)
                  .fontColor(this.textColor())
                Text(suggestion.url).fontFamily(this.appFont())
                  .fontSize(11)
                  .fontColor(this.secondaryColor())
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Text('→').fontFamily(this.appFont()).fontSize(18).fontColor('#2663D6')
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.url = suggestion.url;
              this.submit(suggestion.url);
            })
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
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
