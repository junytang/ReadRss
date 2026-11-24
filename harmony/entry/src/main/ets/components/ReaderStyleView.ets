import { webview } from '@kit.ArkWeb';
import { buffer } from '@kit.ArkTS';
import { FontManager } from '../common/FontManager';
import { goBack, openFontPicker } from '../common/NavigationService';
import { settingsStore } from '../data/SettingsStore';
import { HtmlBuilder } from '../rss/HtmlBuilder';
import { WebViewStyle } from '../rss/WebViewStyle';
import { WebViewHtml } from '../rss/WebViewHtml';
import { ReaderWebSupport } from '../common/ReaderWebSupport';
import { Logger } from '../common/Logger';
import {
  READ_ALIGN_VALUES, readerAlignLabel, READER_LETTER_SPACING_DEFAULT,
} from '../common/Constants';

/** Appearance settings for the full-text reader, with a live preview on top.
 *  The preview is a real WebView loading HtmlBuilder output with the very same
 *  settings object the reader uses — no separately mirrored ArkUI Text styles. */
@Component
export struct ReaderStyleView {
  @StorageProp('fontScale') uiFontScale: number = 1;
  // Scale fixed UI font sizes with the system font size setting.
  private fs(size: number): number { return size * this.uiFontScale; }

  @StorageLink('darkMode') @Watch('onPreviewChanged') darkMode: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @StorageProp('fontDataTick') @Watch('onFontFileChanged') fontDataTick: number = 0;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('readerFontFamily') @Watch('onFontChanged') fontKeyProp: string = 'sans-serif';
  // Same AppStorage keys the reader HTML uses, so preview/real share one source.
  @StorageProp('readerBodyFontSize') @Watch('onPreviewChanged') bodySize: number = 17;
  @StorageProp('readerPageMargin') @Watch('onPreviewChanged') pageMargin: number = 16;
  @StorageProp('readerLineSpacing') @Watch('onPreviewChanged') lineSpacing: number = 1.75;
  @StorageProp('readingTextLetterSpacing') @Watch('onPreviewChanged') letterSpacing: number =
    READER_LETTER_SPACING_DEFAULT;
  @StorageProp('readingTextAlign') @Watch('onPreviewChanged') textAlign: number = 0;
  @State fontKey: string = 'sans-serif';
  @State previewHtml: string = '';
  private previewController: webview.WebviewController = new webview.WebviewController();
  private previewAttached: boolean = false;
  private previewReady: boolean = false;
  private lastPreviewHtml: string = '';

  aboutToAppear(): void {
    this.fontKey = settingsStore.get().readerFontFamily;
    this.previewHtml = this.buildPreviewHtml();
  }

  /** Apply settings to the already-loaded document by rewriting its CSS
   *  variables. Reloading the whole HTML on every slider frame cleared the
   *  document and produced a visible white flash; runJavaScript keeps the
   *  rendered page alive and only recomputes styles. */
  private refreshPreview(): void {
    if (!this.previewReady) {
      // Not loaded yet — the initial document will be built from live values.
      this.previewHtml = this.buildPreviewHtml();
      return;
    }
    const vars: Map<string, string> = WebViewStyle.variables(
      this.darkMode, this.bodySize, FontManager.familyFor(this.fontKey),
      this.pageMargin, this.lineSpacing, this.letterSpacing, this.textAlign
    );
    this.previewController.runJavaScript(WebViewHtml.applyVariables(vars))
      .catch((error: Error) => {
        Logger.warn(`Preview style update skipped: ${error.message}`);
      });
  }

  onFontChanged(): void {
    this.fontKey = this.fontKeyProp;
    this.refreshPreview();
  }

  onPreviewChanged(): void {
    this.refreshPreview();
  }

  /** Installing/removing a custom font changes the @font-face URL, which a
   *  variable update cannot express. Reload once for this rare case. */
  onFontFileChanged(): void {
    this.previewHtml = this.buildPreviewHtml();
    this.pushPreviewHtml(true);
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

  /** Option chip colors, matching ArticleListStyleView for a consistent look. */
  private chipColor(selected: boolean): string {
    if (selected) return this.darkMode ? '#2A2D31' : '#E8EEFB';
    return this.darkMode ? '#26292D' : '#F1F3F5';
  }

  private chipText(selected: boolean): string {
    return selected ? '#2663D6' : this.secondaryColor();
  }

  /** Build the preview with the exact reader pipeline: same HtmlBuilder, same
   *  WebViewStyle variables, same WebViewHtml script and same custom-font CSS. */
  private buildPreviewHtml(): string {
    return HtmlBuilder.buildPreview(
      this.darkMode, this.bodySize, this.pageMargin, this.lineSpacing,
      FontManager.familyFor(this.fontKey), this.letterSpacing, this.textAlign,
      // Always include @font-face when a custom font is installed, so switching
      // to/from it later is just a --font-family variable update (no reload).
      ReaderWebSupport.fontCss('custom', settingsStore.get().customFontPath)
    );
  }

  private pushPreviewHtml(force: boolean = false): void {
    if (!this.previewAttached || this.previewHtml.length === 0
      || (!force && this.previewHtml === this.lastPreviewHtml)) {
      return;
    }
    this.lastPreviewHtml = this.previewHtml;
    try {
      // No base URL: use base64 so the document is not treated as a site load.
      const encoded: string = buffer.from(this.previewHtml, 'utf-8').toString('base64');
      this.previewController.loadData(encoded, 'text/html', 'base64', '', '');
    } catch (error) {
      // Preview is best-effort; settings themselves are already persisted.
    }
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
        Column() {
          Text('预览').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
            .width('100%').textAlign(TextAlign.Start)
            .padding({ left: 16, bottom: 8 })
          Web({ src: '', controller: this.previewController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(true)
            .width('100%')
            .height(200)
            .backgroundColor(this.darkMode ? '#15171A' : '#FFFFFF')
            .borderRadius(10)
            .onControllerAttached(() => {
              this.previewAttached = true;
              this.pushPreviewHtml();
            })
            .onPageEnd(() => {
              this.previewReady = true;
              // A setting may have changed while the first document was still
              // loading; those changes only touched previewHtml, so apply them
              // once now instead of leaving stale styles on screen.
              if (this.previewHtml !== this.lastPreviewHtml) {
                this.pushPreviewHtml();
              }
            })
            .onInterceptRequest((event) => {
              const url: string = event ? event.request.getRequestUrl() : '';
              const bytes: ArrayBuffer | undefined =
                ReaderWebSupport.fontBytes(url, settingsStore.get().customFontPath);
              if (bytes) {
                const response: WebResourceResponse = new WebResourceResponse();
                response.setResponseData(bytes);
                response.setResponseMimeType('font/ttf');
                response.setResponseCode(200);
                response.setReasonMessage('OK');
                response.setResponseHeader([
                  { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
                  { headerKey: 'Cache-Control', headerValue: 'public, max-age=31536000' },
                ]);
                response.setResponseIsReady(true);
                return response;
              }
              return null;
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 8 })

        Scroll() {
          Column() {
            Text('排版').fontSize(this.fs(14)).fontFamily(this.appFont()).fontColor(this.secondaryColor())
              .width('100%').textAlign(TextAlign.Start)
              .padding({ left: 16, bottom: 8 })
              .margin({ top: 24 })

            Column() {
              Row() {
                Text('正文字号').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(72)
                Slider({ value: this.bodySize, min: 12, max: 30, step: 1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.bodySize = value;
                    settingsStore.setReaderBodyFontSize(value);
                    this.refreshPreview();
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
                    this.refreshPreview();
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
                    this.refreshPreview();
                  })
                Text(this.lineSpacing.toFixed(2)).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(32)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Text('字符间距').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor()).width(72)
                Slider({ value: this.letterSpacing, min: 0, max: 3, step: 0.1, style: SliderStyle.OutSet })
                  .layoutWeight(1)
                  .margin({ left: 12, right: 12 })
                  .onChange((value: number) => {
                    this.letterSpacing = value;
                    settingsStore.setReadingTextLetterSpacing(value);
                    this.refreshPreview();
                  })
                Text(`${this.letterSpacing.toFixed(1)}px`).fontSize(this.fs(13)).fontFamily(this.appFont()).fontColor(this.secondaryColor()).width(42)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)

              this.divider()

              Row() {
                Column() {
                  Text('对齐').fontSize(this.fs(15)).fontFamily(this.appFont()).fontColor(this.textColor())
                  Text(readerAlignLabel(this.textAlign)).fontSize(this.fs(13)).fontFamily(this.appFont())
                    .fontColor(this.secondaryColor()).margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  ForEach(READ_ALIGN_VALUES, (value: number, idx: number) => {
                    Text(idx === 3 ? '两端' : (idx === 0 ? '左' : (idx === 1 ? '右' : '中')))
                      .fontSize(this.fs(15))
                      .fontFamily(this.appFont())
                      .fontColor(this.chipText(this.textAlign === value))
                      .width(idx === 3 ? 46 : 40).height(40)
                      .textAlign(TextAlign.Center)
                      .backgroundColor(this.chipColor(this.textAlign === value))
                      .borderRadius(12)
                      .margin({ left: idx === 0 ? 0 : 6 })
                      .onClick(() => {
                        this.textAlign = value;
                        settingsStore.setReadingTextAlign(value);
                        this.refreshPreview();
                      })
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
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
