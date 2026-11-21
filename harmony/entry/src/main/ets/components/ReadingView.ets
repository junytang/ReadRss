import { webview } from '@kit.ArkWeb';
import { buffer } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { Article, ArticleNeighbors, Feed } from '../model/Models';
import { rssRepository } from '../rss/RssRepository';
import { HtmlBuilder } from '../rss/HtmlBuilder';
import { settingsStore } from '../data/SettingsStore';
import { Logger } from '../common/Logger';
import { FontManager } from '../common/FontManager';
import { FeedIcon } from '../common/FeedIcon';
import { ArticleImageConverter } from '../common/ArticleImageConverter';
import { ReaderFont } from '../common/ReaderFont';

/** Reader screen. Uses the same WebView rendering approach as the Android app. */
@Component
export struct ReadingView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @Prop articleId: string = '';
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('readerBodyFontSize') @Watch('onStyleChanged') readerBodyFontSize: number = 17;
  @StorageProp('readerPageMargin') @Watch('onStyleChanged') readerPageMargin: number = 16;
  @StorageProp('readerLineSpacing') @Watch('onStyleChanged') readerLineSpacing: number = 1.75;
  @StorageProp('readerFontFamily') @Watch('onStyleChanged') readerFontFamily: string = 'sans-serif';
  @State article: Article | undefined = undefined;
  @State html: string = '';
  @State isStarred: boolean = false;
  @State previousId: string = '';
  @State nextId: string = '';
  @State feedIconUrl: string = '';

  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    let article: Article | undefined = await rssRepository.ensureArticleContent(this.articleId);
    if (!article) {
      return;
    }
    // Render immediately from whatever body is cached; full content arrives in background.
    this.article = article;
    this.isStarred = article.isStarred;
    const feeds: Feed[] = await rssRepository.listFeeds();
    for (const feed of feeds) {
      if (feed.id === article.feedId) {
        this.feedIconUrl = FeedIcon.src(feed.iconUrl);
        break;
      }
    }
    this.html = await this.buildHtml(article);
    this.pushHtml();
    Logger.info(`Open article: cachedFull=${article.fullContent.length} cachedBody=${article.content.length}`);

    if (!rssRepository.hasCurrentFullContent(article) && article.link.length > 0) {
      rssRepository.ensureFullContent(this.articleId).then(async (updated: Article | undefined) => {
        if (updated && updated.fullContent.length > 0) {
          this.article = updated;
          this.html = await this.buildHtml(updated);
          this.pushHtml();
        }
      }).catch((error: Error) => {
        Logger.error(`Background full content failed: ${error.message}`);
      });
    }

    // Mark read optimistically: the list turns gray before the server replies.
    const currentArticle: Article = article;
    if (!currentArticle.isRead) {
      currentArticle.isRead = true;
      AppStorage.set<string>('lastChangedArticle', `${currentArticle.id}|read|true`);
      AppStorage.set<number>('readStatusTick', Date.now());
      rssRepository.markRead(currentArticle.id, true).catch((error: Error) => {
        currentArticle.isRead = false;
        AppStorage.set<string>('lastChangedArticle', `${currentArticle.id}|read|false`);
        AppStorage.set<number>('readStatusTick', Date.now());
        Logger.error(`Mark read on open failed: ${error.message}`);
      });
    }
    const neighbors: ArticleNeighbors = await rssRepository.neighborIds(article.id);
    this.previousId = neighbors.previous;
    this.nextId = neighbors.next;
  }

  /** Re-render the reader when its appearance settings change. */
  private async onStyleChanged(): Promise<void> {
    if (!this.article) {
      return;
    }
    this.html = await this.buildHtml(this.article);
    this.pushHtml();
  }

  /** ArkUI's getFont().registerFont only affects native Text, not ArkWeb, and
   *  data: URI fonts are not decoded here either. Load the font bytes into
   *  memory and expose them through a same-origin virtual URL intercepted by
   *  onInterceptRequest. */
  private customFontCss(): string {
    if (this.readerFontFamily !== 'custom') {
      return '';
    }
    const path: string = settingsStore.get().customFontPath;
    if (ReaderFont.load(path) === undefined) {
      return '';
    }
    return `@font-face { font-family: 'ReadYouCustom'; ` +
      `src: url('${ReaderFont.virtualUrl(this.article?.link ?? '')}') format('truetype'); }`;
  }

  private async buildHtml(article: Article): Promise<string> {
    const built: string = HtmlBuilder.build(
      article,
      this.darkMode,
      this.readerBodyFontSize,
      this.readerPageMargin,
      this.readerLineSpacing,
      FontManager.familyFor(this.readerFontFamily),
      this.customFontCss()
    );
    return await ArticleImageConverter.convertAvif(built);
  }

  private pushHtml(): void {
    if (this.html.length === 0) {
      return;
    }
    try {
      this.controller.setCustomUserAgent(
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
      );
      Logger.info(`Reader html length=${this.html.length} images=${(this.html.match(/<img/gi) ?? []).length}`);
      const baseUrl: string = this.article?.link ?? '';
      if (baseUrl.length > 0) {
        // With a website baseUrl the engine treats data as a plain string and
        // ignores base64 decoding, so pass the raw HTML as UTF-8. The site
        // origin also gives image requests the Referer needed by hotlink CDNs.
        this.controller.loadData(this.html, 'text/html', 'UTF-8', baseUrl, '');
      } else {
        const encoded: string = buffer.from(this.html, 'utf-8').toString('base64');
        this.controller.loadData(encoded, 'text/html', 'base64', '', '');
      }
      Logger.info(`Reader WebView loaded html length=${this.html.length}`);
    } catch (error) {
      Logger.warn(`WebView loadData retry: ${(error as Error).message}`);
    }
  }

  private toggleStar(): void {
    const next: boolean = !this.isStarred;
    this.isStarred = next;
    AppStorage.set<string>('lastChangedArticle', `${this.articleId}|starred|${next}`);
    AppStorage.set<number>('readStatusTick', Date.now());
    this.getUIContext().getPromptAction().showToast({ message: next ? '已收藏' : '已取消收藏' });
    rssRepository.markStarred(this.articleId, next).catch((error: Error) => {
      this.isStarred = !next;
      AppStorage.set<string>('lastChangedArticle', `${this.articleId}|starred|${!next}`);
      AppStorage.set<number>('readStatusTick', Date.now());
      Logger.error(`Toggle starred failed: ${error.message}`);
    });
  }

  private openOriginal(): void {
    const link: string = this.article?.link ?? '';
    if (link.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这篇文章没有原文链接' });
      return;
    }
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext) {
        const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
        context.startAbility({ action: 'ohos.want.action.viewData', uri: link });
      }
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `无法打开链接：${(error as Error).message}` });
    }
  }

  private async copyLink(): Promise<void> {
    const link: string = this.article?.link ?? '';
    if (link.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这篇文章没有原文链接' });
      return;
    }
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
      await pasteboard.getSystemPasteboard().setData(pasteData);
      this.getUIContext().getPromptAction().showToast({ message: '链接已复制' });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `复制失败：${(error as Error).message}` });
    }
  }

  private async shareArticle(): Promise<void> {
    const link: string = this.article?.link ?? '';
    if (link.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这篇文章没有原文链接' });
      return;
    }
    try {
      const title: string = this.article?.title ?? '';
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: link,
        title: title,
        description: title,
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `分享失败：${(error as Error).message}` });
    }
  }

  private appFont(): string {
    // Reading the tick here makes font changes trigger a component rebuild.
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  private dateText(): string {
    const time: number = this.article?.publishedAt ?? 0;
    if (time <= 0) {
      return '';
    }
    const date: Date = new Date(time);
    return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()} ${date.getHours()}:${date.getMinutes().toString().padStart(2, '0')}`;
  }

  build() {
    NavDestination() {
      Column() {
        Column() {
          Row() {
            if (this.feedIconUrl.length > 0) {
              Image(this.feedIconUrl)
                .width(14)
                .height(14)
                .borderRadius(3)
                .margin({ right: 5 })
            } else {
              Image($r('app.media.app_icon'))
                .width(14)
                .height(14)
                .borderRadius(3)
                .margin({ right: 5 })
            }
            Text(this.article?.feedTitle ?? '').fontFamily(this.appFont())
              .fontSize(this.fs(12))
              .fontColor(this.darkMode ? '#9AA0A6' : '#5E636A')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 160 })
            if (this.dateText().length > 0) {
              Text('  ·  ' + this.dateText()).fontFamily(this.appFont())
                .fontSize(this.fs(12))
                .fontColor(this.darkMode ? '#9AA0A6' : '#5E636A')
            }
            Blank()
            Button() {
              Image($r('app.media.ic_more'))
                .width(20)
                .height(20)
                .fillColor(this.darkMode ? '#E8EAED' : '#1A1C1E')
            }
            .type(ButtonType.Circle)
            .width(32)
            .height(32)
            .backgroundColor(Color.Transparent)
            .margin({ left: 4 })
            .bindMenu([
              { value: '用浏览器打开', action: () => this.openOriginal() },
              { value: '复制链接', action: () => this.copyLink() },
              { value: '分享', action: () => this.shareArticle() },
            ])
          }
          .width('100%')
          Text(this.article?.title ?? '').fontFamily(this.appFont())
            .fontSize(this.fs(20))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.darkMode ? '#E8EAED' : '#1A1C1E')
            .width('100%')
            .margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 18, right: 18, top: 12, bottom: 12 })

        if (this.html.length > 0) {
          Web({ src: '', controller: this.controller })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(true)
            .width('100%')
            .layoutWeight(1)
            .padding({ bottom: 16 })
            .backgroundColor(this.darkMode ? '#15171A' : '#FFFFFF')
            .onAppear(() => this.pushHtml())
            .onControllerAttached(() => this.pushHtml())
            .onInterceptRequest((event) => {
              const url: string = event ? event.request.getRequestUrl() : '';
              if (ArticleImageConverter.isVirtualUrl(url)) {
                const key: string = ArticleImageConverter.keyFromUrl(url);
                const bytes: ArrayBuffer | undefined = ArticleImageConverter.getBytes(key);
                if (bytes) {
                  const response: WebResourceResponse = new WebResourceResponse();
                  response.setResponseData(bytes);
                  response.setResponseMimeType('image/jpeg');
                  response.setResponseCode(200);
                  response.setReasonMessage('OK');
                  response.setResponseIsReady(true);
                  return response;
                }
              }
              if (ReaderFont.isVirtualUrl(url)) {
                const bytes: ArrayBuffer | undefined = ReaderFont.getBytes();
                if (bytes) {
                  const response: WebResourceResponse = new WebResourceResponse();
                  response.setResponseData(bytes);
                  response.setResponseMimeType('font/ttf');
                  response.setResponseCode(200);
                  response.setReasonMessage('OK');
                  response.setResponseIsReady(true);
                  return response;
                }
              }
              return null;
            })
        } else {
          Column() {
            Text('正在加载文章…').fontFamily(this.appFont())
              .fontSize(this.fs(15))
              .fontColor(this.darkMode ? '#9AA0A6' : '#5E636A')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.darkMode ? '#15171A' : '#FFFFFF')
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
