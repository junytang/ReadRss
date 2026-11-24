import { webview } from '@kit.ArkWeb';
import { buffer } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { Article, ArticleNeighbors } from '../model/Models';
import { rssRepository } from '../rss/RssRepository';
import { HtmlBuilder } from '../rss/HtmlBuilder';
import { goBack } from '../common/NavigationService';
import { ArticleScope } from '../common/Constants';
import { settingsStore } from '../data/SettingsStore';
import { Logger } from '../common/Logger';
import { FontManager } from '../common/FontManager';
import { FeedIcon } from '../common/FeedIcon';
import { ArticleImageConverter } from '../common/ArticleImageConverter';
import { ReaderWebSupport } from '../common/ReaderWebSupport';
import { readStatusStore } from '../rss/ReadStatusStore';
import { ToastUtil } from '../common/ToastUtil';
import { ReaderImageViewer } from './ReaderImageViewer';

/** Minimum vertical pull (vp) at a scroll edge that switches articles. Applies
 *  to both pull-down (previous) and pull-up (next). Large enough that ordinary
 *  overscroll bounces never switch articles. */
const PULL_TRIGGER_VP: number = 140;

/** Extra lift (vp) for the bottom hint so its centred position stays clear of
 *  the system navigation bar even when the exposed gap is shallow. */
const PULL_HINT_LIFT: number = 24;

/** The page reports its own exact scroll boundaries to ArkTS. This avoids
 *  guessing from getPageHeight()/yOffset, which could mark mid-article as the
 *  bottom and make a normal scroll switch articles. A class (not an interface
 *  literal) is required so ArkTS accepts it as a JS bridge target. */
class ReaderBridgeHandler {
  private readonly onBoundary: (atTop: boolean, atBottom: boolean) => void;
  private readonly onReady: () => void;
  private readonly onImage: (url: string) => void;

  constructor(
    callback: (atTop: boolean, atBottom: boolean) => void, onReady: () => void,
    onImage: (url: string) => void
  ) {
    this.onBoundary = callback;
    this.onReady = onReady;
    this.onImage = onImage;
  }

  onScrollBoundary(atTop: boolean, atBottom: boolean): void {
    this.onBoundary(atTop, atBottom);
  }

  /** Called by the page script once its document is rendered and visible. */
  onPageReady(): void {
    this.onReady();
  }

  onImageClick(url: string): void {
    this.onImage(url);
  }
}

/** Reader screen. Uses the same WebView rendering approach as the Android app. */
@Component
export struct ReadingView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @Prop articleId: string = '';
  // Scope of the list this article was opened from; prev/next follow it.
  @Prop scope: ArticleScope = { feedId: '', groupId: '', filter: '', searchText: '' };
  @StorageLink('darkMode') darkMode: boolean = false;
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @StorageProp('readerBodyFontSize') @Watch('onStyleChanged') readerBodyFontSize: number = 17;
  @StorageProp('readerPageMargin') @Watch('onStyleChanged') readerPageMargin: number = 16;
  @StorageProp('readerLineSpacing') @Watch('onStyleChanged') readerLineSpacing: number = 1.75;
  @StorageProp('readerFontFamily') @Watch('onStyleChanged') readerFontFamily: string = 'sans-serif';
  @StorageProp('readingTextLetterSpacing') @Watch('onStyleChanged') letterSpacing: number = 0.5;
  @StorageProp('readingTextAlign') @Watch('onStyleChanged') textAlign: number = 0;
  @State article: Article | undefined = undefined;
  @State html: string = '';
  @State isStarred: boolean = false;
  @State previousId: string = '';
  @State nextId: string = '';
  @State feedIconUrl: string = '';
  // Pull-to-switch state: only a pull starting at the WebView's very top or
  // very bottom is eligible, and only a large enough release switches article.
  @State pullHint: string = '';
  // Which edge the hint is shown at. Short articles are at top AND bottom at
  // once, so this must follow the gesture direction, not the boundary flags.
  @State pullAtBottom: boolean = false;
  // Rubber-band offset of the whole WebView, so the page follows the finger.
  @State pullOffset: number = 0;
  private webHeight: number = 0;
  private pageMaxScroll: number = 0;
  private atTopNow: boolean = true;
  private atBottomNow: boolean = false;
  private boundaryReported: boolean = false;
  @State zoomImageUrl: string = '';
  private bridge: ReaderBridgeHandler = new ReaderBridgeHandler(
    (atTop: boolean, atBottom: boolean): void => {
      this.boundaryReported = true;
      this.atTopNow = atTop;
      this.atBottomNow = atBottom;
    },
    (): void => this.onPageRendered(),
    (url: string): void => {
      if (url.length > 0) {
        this.zoomImageUrl = url;
      }
    }
  );
  private pullStartY: number = 0;
  private lastPullY: number = 0;
  private pullFromTop: boolean = false;
  private pullFromBottom: boolean = false;
  private pullTracking: boolean = false;
  // The route param seeds this, but prev/next switches articles in place
  // (like Android) instead of pushing a new destination. @Prop is one-way
  // synced from the parent, so keep a local mutable copy for in-place switches.
  @State currentArticleId: string = '';

  // Prev/next page-switch animation. The WebView container slides out one way
  // while the new content is swapped in at the peak, then slides in from the
  // opposite edge. `switching` freezes touch handling during the transition.
  @State switchOffset: number = 0;
  private switching: boolean = false;
  // Resolved when the WebView finishes rendering a page. Used by the page-turn
  // animation to wait for the new article's content before sliding it in;
  // loadData() itself is async, so awaiting load() is not enough.
  private pageRenderedResolve?: () => void;
  // Coalesce style-setting changes: a slider's onChange fires on every frame,
  // but each change rebuilds the whole HTML and reloads the WebView. Debounce to
  // a single re-render after the user stops dragging.
  private styleTimer: number = -1;
  // pushHtml has three callers (renderHtml / onAppear / onControllerAttached).
  // Before the controller is attached loadData is lost; after attach all three
  // would push the same HTML. Guard on attach state + last-pushed HTML so the
  // same document is loaded exactly once (a new article/style changes `html`).
  private controllerAttached: boolean = false;
  private lastPushedHtml: string = '';

  private controller: webview.WebviewController = new webview.WebviewController();
  // buildHtml is async (AVIF conversion). Guard so a stale render (e.g. an
  // older style change finishing after a newer one) cannot overwrite the HTML.
  private htmlSeq: number = 0;
  // Guard rapid prev/next taps: discard results from a superseded article load.
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.currentArticleId = this.articleId;
    this.load();
  }

  private async load(): Promise<void> {
    const seq: number = ++this.loadSeq;
    const articleId: string = this.currentArticleId;
    let article: Article | undefined = await rssRepository.ensureArticleContent(articleId);
    if (!article || seq !== this.loadSeq) {
      return;
    }
    // Render immediately from whatever body is cached; full content arrives in background.
    this.article = article;
    this.isStarred = article.isStarred;
    // One row lookup instead of listing every feed to find this article's icon.
    this.feedIconUrl = FeedIcon.src(await rssRepository.feedIconUrl(article.feedId));
    if (seq !== this.loadSeq) {
      return;
    }
    await this.renderHtml(article);
    Logger.info(`Open article: cachedFull=${article.fullContent.length} cachedBody=${article.content.length}`);

    if (!rssRepository.hasCurrentFullContent(article) && article.link.length > 0) {
      // Pass the loaded article through: re-reading it by id would marshal the
      // whole body a second time.
      rssRepository.ensureFullContentFor(article).then(async (updated: Article | undefined) => {
        if (seq !== this.loadSeq) {
          return; // user already switched to another article
        }
        if (updated && updated.fullContent.length > 0) {
          this.article = updated;
          await this.renderHtml(updated);
        }
      }).catch((error: Error) => {
        Logger.error(`Background full content failed: ${error.message}`);
      });
    }

    // Mark read locally; the store commits + pushes in the background with
    // bounded retry, so no rollback bookkeeping is needed here.
    const currentArticle: Article = article;
    if (settingsStore.get().markReadOnOpen && !currentArticle.isRead) {
      currentArticle.isRead = true;
      readStatusStore.markRead(
        currentArticle.id, false, true, currentArticle.feedId, this.scope.groupId
      );
    }
    const neighbors: ArticleNeighbors = await rssRepository.neighborIds(
      currentArticle, this.scope.feedId, this.scope.filter,
      this.scope.groupId, this.scope.searchText
    );
    if (seq !== this.loadSeq) {
      return;
    }
    this.previousId = neighbors.previous;
    this.nextId = neighbors.next;
  }

  /** Switch to an adjacent article in place, matching Android's onLoadArticle:
   *  keep the same NavDestination so Back always returns to the article list.
   *  Page-turn animation: `toPrevious` slides the old page DOWN and out, then
   *  the new page enters from the TOP; `toNext` is the reverse. */
  private async openNeighbor(id: string, toPrevious: boolean): Promise<void> {
    if (this.switching || id.length === 0 || id === this.currentArticleId) {
      return;
    }
    this.switching = true;
    const outSign: number = toPrevious ? 1 : -1;
    const screenH: number = AppStorage.get<number>('windowHeightVp') ?? 800;
    const dist: number = screenH > 0 ? screenH : 800;

    // Phase 1: slide the current content out.
    this.pullHint = '';
    this.pullOffset = 0;
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseIn }, () => {
      this.switchOffset = outSign * dist;
    });
    await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 190); });

    // Phase 2: off-screen, swap content and jump to the opposite edge (no anim).
    // Start waiting for the WebView paint BEFORE load() triggers loadData();
    // awaiting load() alone is not enough because loadData renders asynchronously.
    // Otherwise the slide-in would carry the OLD article and only swap after it.
    const rendered: Promise<void> = this.waitForPageRender();
    this.switchOffset = -outSign * dist;
    this.currentArticleId = id;
    this.previousId = '';
    this.nextId = '';
    this.isStarred = false;
    this.pageMaxScroll = 0;
    this.atTopNow = true;
    this.atBottomNow = false;
    this.boundaryReported = false;
    await this.load();
    await rendered;

    // Phase 3: slide the new content in to rest.
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
      this.switchOffset = 0;
    });
    await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 230); });
    this.switching = false;
  }

  /** Fallback only: used until the page's own JS bridge reports a boundary.
   *  Once reported, the precise DOM-based state always wins — a rough native
   *  estimate here could otherwise mark mid-article as "bottom" and make a
   *  normal scroll switch articles. */
  private onWebScroll(event: OnScrollEvent): void {
    if (this.boundaryReported) {
      return;
    }
    const y: number = event.yOffset;
    if (this.pageMaxScroll <= 0) {
      try {
        this.pageMaxScroll = Math.max(0, this.controller.getPageHeight() - this.webHeight);
      } catch (error) {
        this.pageMaxScroll = 0;
      }
    }
    this.atTopNow = y <= 20;
    this.atBottomNow = this.pageMaxScroll <= 40
      ? true
      : y >= this.pageMaxScroll - 40;
  }

  /** Inject a scroll listener once per loaded page. The page knows its own
   *  scrollTop/scrollHeight exactly and reports real edge state via the bridge,
   *  so pull-to-switch can only be armed at a genuine top or bottom. */
  private onWebPageEnd(): void {
    const script: string =
      '(function(){' +
      'if(window.__ryBoundaryReady)return;' +
      'window.__ryBoundaryReady=true;' +
      'function u(){' +
      'var d=document.documentElement,b=document.body;' +
      'var t=window.pageYOffset||d.scrollTop||b.scrollTop||0;' +
      'var h=window.innerHeight;' +
      'var s=Math.max(d.scrollHeight,b.scrollHeight);' +
      'if(window.readYouBridge&&window.readYouBridge.onScrollBoundary){' +
      'window.readYouBridge.onScrollBoundary(t<=2,t+h>=s-2);' +
      '}}' +
      'window.addEventListener("scroll",u,{passive:true});' +
      'window.addEventListener("resize",u,{passive:true});' +
      'u();' +
      '})();';
    this.controller.runJavaScript(script).catch(() => {
      // JS bridge unavailable; onWebScroll keeps the native fallback working.
    });
  }

  /** Called from the page script (via readYouBridge.onPageReady) when the newly
   *  loaded document is rendered and visible. This is the deterministic signal
   *  for the page-turn animation: unlike native onPageEnd it cannot be a stale
   *  event from a previous load. */
  private onPageRendered(): void {
    const done: (() => void) | undefined = this.pageRenderedResolve;
    if (done) {
      this.pageRenderedResolve = undefined;
      done();
    }
  }

  /** Wait until the WebView's own script reports the new page is rendered.
   *  Timeout fallback in case the script/bridge fails to fire on this build. */
  private waitForPageRender(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (): void => {
        if (settled) return;
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        this.pageRenderedResolve = undefined;
        resolve();
      };
      this.pageRenderedResolve = finish;
      // Align with the page script's 1200ms visibility fallback (plus margin).
      timer = setTimeout(finish, 1300);
    });
  }

  /** Pull down at the top -> previous (newer) article; pull up at the bottom ->
   *  next (older) article. The page follows the finger with damping, and only
   *  a release beyond PULL_TRIGGER_VP switches articles. */
  private onWebTouch(event: TouchEvent): void {
    // Ignore all touch input while a page-turn animation is running.
    if (this.switching) {
      return;
    }
    const touches: TouchObject[] = event.changedTouches;
    // On Up some WebViews report an empty changedTouches; use the last known
    // position so the release is still evaluated instead of being dropped.
    const y: number = touches.length > 0 ? touches[0].y : this.lastPullY;
    if (event.type === TouchType.Down) {
      // A fresh gesture must start from a clean state. A previous spring-back
      // animation may still be running during rapid consecutive pulls; let the
      // new gesture own pullOffset instead of fighting the old animation.
      this.pullOffset = 0;
      this.pullStartY = y;
      this.lastPullY = y;
      // A short article is simultaneously at top and bottom. Keep both flags
      // independent so pull-down still means "previous" and pull-up "next";
      // the gesture direction decides which one applies.
      this.pullFromTop = this.atTopNow;
      this.pullFromBottom = this.atBottomNow;
      this.pullTracking = this.pullFromTop || this.pullFromBottom;
      // Do not show the hint at touch-down: pullOffset is still 0, so a bottom
      // hint would sit at the very bottom of the screen (over the nav bar) with
      // no exposed gap yet. The first Move reveals the direction and position.
      this.pullHint = '';
    } else if (event.type === TouchType.Move && this.pullTracking) {
      this.lastPullY = y;
      const delta: number = y - this.pullStartY;
      let hint: string = '';
      if (this.pullFromTop && delta > 0) {
        this.pullAtBottom = false;
        this.pullOffset = Math.min(delta * 0.5, 160);
        // Only promise a switch when a neighbor actually exists.
        if (this.previousId.length === 0) {
          hint = '已经是第一篇';
        } else {
          hint = delta >= PULL_TRIGGER_VP ? '释放查看上一篇' : '下拉查看上一篇';
        }
      } else if (this.pullFromBottom && delta < 0) {
        this.pullAtBottom = true;
        this.pullOffset = Math.max(delta * 0.5, -160);
        if (this.nextId.length === 0) {
          hint = '已经是最后一篇';
        } else {
          hint = -delta >= PULL_TRIGGER_VP ? '释放查看下一篇' : '上拉查看下一篇';
        }
      } else {
        // Direction reversed: the user resumed normal reading, so stop the pull.
        this.pullOffset = 0;
      }
      if (this.pullHint !== hint) {
        this.pullHint = hint;
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const delta: number = y - this.pullStartY;
      const wasTracking: boolean = this.pullTracking;
      const fromTop: boolean = this.pullFromTop;
      const fromBottom: boolean = this.pullFromBottom;
      this.pullHint = '';
      this.pullTracking = false;
      if (event.type === TouchType.Cancel || !wasTracking) {
        this.pullOffset = 0;
        return;
      }
      const switchPrev: boolean =
        fromTop && delta >= PULL_TRIGGER_VP && this.previousId.length > 0;
      const switchNext: boolean =
        fromBottom && delta <= -PULL_TRIGGER_VP && this.nextId.length > 0;
      if (switchPrev || switchNext) {
        // Reset immediately. Animating here would keep mutating pullOffset for
        // 220ms and wipe the hint of a quickly-following consecutive pull.
        this.pullOffset = 0;
        this.openNeighbor(switchPrev ? this.previousId : this.nextId, switchPrev);
      } else {
        // Not far enough: spring the page back with an animation.
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.pullOffset = 0;
        });
      }
    }
  }

  /** Re-render the reader when its appearance settings change. Debounced so
   *  dragging a settings slider rebuilds/reloads the WebView only once. */
  private async onStyleChanged(): Promise<void> {
    if (!this.article) {
      return;
    }
    if (this.styleTimer >= 0) {
      clearTimeout(this.styleTimer);
    }
    this.styleTimer = setTimeout(() => {
      this.styleTimer = -1;
      if (this.article) {
        this.renderHtml(this.article);
      }
    }, 150);
  }

  /** Build HTML async and apply it only if no newer render superseded it. */
  private async renderHtml(article: Article): Promise<void> {
    const seq: number = ++this.htmlSeq;
    const html: string = await this.buildHtml(article);
    if (seq !== this.htmlSeq) {
      return; // a newer style/content render won; discard this stale result
    }
    this.html = html;
    this.pushHtml();
  }

  /** ArkUI's getFont().registerFont only affects native Text, not ArkWeb, and
   *  data: URI fonts are not decoded here either. Serve the font bytes through
   *  a single fixed virtual URL intercepted by onInterceptRequest; the response
   *  carries CORS + long-lived cache headers so ArkWeb keeps only one copy. */
  private customFontCss(): string {
    // Shared with the live preview so both surfaces load the same font CSS.
    return ReaderWebSupport.fontCss(this.readerFontFamily, settingsStore.get().customFontPath);
  }

  private async buildHtml(article: Article): Promise<string> {
    const built: string = HtmlBuilder.build(
      article,
      this.darkMode,
      this.readerBodyFontSize,
      this.readerPageMargin,
      this.readerLineSpacing,
      FontManager.familyFor(this.readerFontFamily),
      this.letterSpacing,
      this.textAlign,
      this.customFontCss()
    );
    return await ArticleImageConverter.convertAvif(built);
  }

  private pushHtml(): void {
    // Skip before the controller is attached (loadData would be discarded) and
    // skip when the HTML is unchanged (onAppear / onControllerAttached both call
    // this for the same document). A new article or style change alters `html`.
    if (!this.controllerAttached || this.html.length === 0 || this.html === this.lastPushedHtml) {
      return;
    }
    this.lastPushedHtml = this.html;
    try {
      Logger.info(`Reader html length=${this.html.length}`);
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
    const id: string = this.currentArticleId;
    this.isStarred = next;
    ToastUtil.show(this.getUIContext(), next ? '已收藏' : '已取消收藏');
    readStatusStore.markStarred(id, next, !next, this.article?.feedId ?? '');
  }

  private openOriginal(): void {
    const link: string = this.article?.link ?? '';
    if (link.length === 0) {
      ToastUtil.show(this.getUIContext(), '这篇文章没有原文链接');
      return;
    }
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext) {
        const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
        context.startAbility({ action: 'ohos.want.action.viewData', uri: link });
      }
    } catch (error) {
      ToastUtil.show(this.getUIContext(), `无法打开链接：${(error as Error).message}`);
    }
  }

  private async copyLink(): Promise<void> {
    const link: string = this.article?.link ?? '';
    if (link.length === 0) {
      ToastUtil.show(this.getUIContext(), '这篇文章没有原文链接');
      return;
    }
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
      await pasteboard.getSystemPasteboard().setData(pasteData);
      ToastUtil.show(this.getUIContext(), '链接已复制');
    } catch (error) {
      ToastUtil.show(this.getUIContext(), `复制失败：${(error as Error).message}`);
    }
  }

  private async shareArticle(): Promise<void> {
    const link: string = this.article?.link ?? '';
    if (link.length === 0) {
      ToastUtil.show(this.getUIContext(), '这篇文章没有原文链接');
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
      ToastUtil.show(this.getUIContext(), `分享失败：${(error as Error).message}`);
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
      Stack() {
      Column() {
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
                .width(19)
                .height(19)
                .fillColor('#1A1C1E')
            }
            .type(ButtonType.Circle)
            .width(38)
            .height(38)
            .backgroundColor(Color.White)
            .margin({ left: 8 })
            .bindMenu([
              {
                // Action icon: filled star = collect, outline = uncollect.
                value: this.isStarred ? '取消收藏' : '标记为收藏',
                icon: this.isStarred ? $r('app.media.ic_star_outline') : $r('app.media.ic_filter_star'),
                action: () => this.toggleStar(),
              },
              {
                value: '用浏览器打开',
                icon: $r('app.media.ic_open_browser'),
                action: () => this.openOriginal(),
              },
              {
                value: '复制链接',
                icon: $r('app.media.ic_copy_link'),
                action: () => this.copyLink(),
              },
              {
                value: '分享',
                icon: $r('app.media.ic_share'),
                action: () => this.shareArticle(),
              },
            ])
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 16, top: 14, bottom: 20 })

        if (this.html.length > 0) {
          Stack() {
            // Inner layer follows the finger; the outer layer stays fixed so
            // the hint sits in the exposed space instead of covering text.
            Stack() {
              Web({ src: '', controller: this.controller })
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(true)
              .width('100%')
              .height('100%')
              .padding({ bottom: 16 })
              .backgroundColor(this.darkMode ? '#15171A' : '#FFFFFF')
              .onAppear(() => this.pushHtml())
              .onControllerAttached(() => {
                this.controller.setCustomUserAgent(
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
                );
                this.controller.registerJavaScriptProxy(
                  this.bridge, 'readYouBridge', ['onScrollBoundary', 'onPageReady', 'onImageClick']
                );
                // Mark attached BEFORE pushHtml so the pending HTML (possibly
                // rendered while the controller was not ready) finally loads.
                this.controllerAttached = true;
                this.pushHtml();
              })
              .onAreaChange((oldValue: Area, newValue: Area) => {
                this.webHeight = newValue.height as number;
              })
              .onTouch((event: TouchEvent) => this.onWebTouch(event))
              .onScroll((event: OnScrollEvent) => this.onWebScroll(event))
              .onPageEnd(() => this.onWebPageEnd())
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
              if (ReaderWebSupport.isFontUrl(url)) {
                // Read on demand instead of keeping a 22MB buffer resident.
                const bytes: ArrayBuffer | undefined =
                  ReaderWebSupport.fontBytes(url, settingsStore.get().customFontPath);
                if (bytes) {
                  const response: WebResourceResponse = new WebResourceResponse();
                  response.setResponseData(bytes);
                  response.setResponseMimeType('font/ttf');
                  response.setResponseCode(200);
                  response.setReasonMessage('OK');
                  // Fixed URL is cross-origin to the article, so @font-face
                  // needs CORS; the cache header makes ArkWeb reuse the one
                  // parsed copy across articles instead of fetching per page.
                  response.setResponseHeader([
                    { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
                    { headerKey: 'Cache-Control', headerValue: 'public, max-age=31536000' },
                  ]);
                  response.setResponseIsReady(true);
                  return response;
                }
              }
              return null;
            })
            }
            .width('100%')
            .height('100%')
            .translate({ y: this.pullOffset + this.switchOffset })

            // Pull hint, like pull-to-refresh. Non-interactive so the touch
            // still reaches the WebView underneath. It lives in the fixed
            // outer Stack, centred in the space exposed by the rubber band.
            if (this.pullHint.length > 0) {
              Column() {
                Text(this.pullHint)
                  .fontFamily(this.appFont())
                  .fontSize(this.fs(14))
                  .fontColor(this.darkMode ? '#E8EAED' : '#1A1C1E')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .borderRadius(18)
                  .backgroundColor(this.darkMode ? '#2A2D31' : '#FFFFFF')
              }
              .width('100%')
              .height('100%')
              .justifyContent(this.pullAtBottom ? FlexAlign.End : FlexAlign.Start)
              .alignItems(HorizontalAlign.Center)
              // Both directions centre the hint in the exposed gap by following
              // pullOffset with the same |offset|/2 - halfHeight formula.
              // Pull-up additionally keeps a floor at bottomInset + 48 (the
              // known-good spot above the nav bar) plus a manual lift, so a
              // shallow early gap can never drop the hint behind the nav bar.
              .padding({
                top: this.pullAtBottom ? 0 : Math.max(0, this.pullOffset / 2 - 16),
                bottom: this.pullAtBottom
                  ? Math.max(
                      this.bottomInset + 48,
                      -this.pullOffset / 2 - 16 + PULL_HINT_LIFT
                    )
                  : 0,
              })
              .hitTestBehavior(HitTestMode.None)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(this.darkMode ? '#15171A' : '#FFFFFF')
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

      // Full-screen image viewer is above the article; taps and pinch gestures
      // never reach the WebView while it is shown.
      if (this.zoomImageUrl.length > 0) {
        ReaderImageViewer({
          url: this.zoomImageUrl,
          referer: this.article?.link ?? '',
          onClose: (): void => { this.zoomImageUrl = ''; },
        })
          // A custom component has no implicit size. Without an explicit
          // 100%x100% on the component itself, its root Column's height('100%')
          // resolves against a content-sized wrapper and the image area
          // collapses / shifts instead of filling the screen.
          .width('100%')
          .height('100%')
      }
      }
      .alignContent(Alignment.TopStart)
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
