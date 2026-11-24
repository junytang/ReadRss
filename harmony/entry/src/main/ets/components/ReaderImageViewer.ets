import { image } from '@kit.ImageKit';
import { ArticleImageConverter } from '../common/ArticleImageConverter';
import { Logger } from '../common/Logger';
import { FontManager } from '../common/FontManager';

/** Maximum pinch magnification, matching Android's telephoto ZoomSpec(4f). */
const MAX_ZOOM: number = 4;

/**
 * Full-screen image viewer for the reader. Shown when the article's WebView
 * reports an image tap through the readYouBridge.onImageClick callback.
 * Pinch to zoom (1x-4x), drag while zoomed, tap to dismiss. AVIF images were
 * already converted to JPEG bytes by ArticleImageConverter, so serve those
 * bytes to the native Image component instead of the virtual https URL (the
 * image decoder cannot decode AVIF, and the virtual URL only exists in WebView).
 */
@Component
export struct ReaderImageViewer {
  @Prop url: string = '';
  onClose: () => void = () => {};
  @StorageProp('fontScale') uiFontScale: number = 1;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @State pixelMap: image.PixelMap | undefined = undefined;
  @State zoomScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private gestureScale: number = 1;
  private gestureOffsetX: number = 0;
  private gestureOffsetY: number = 0;

  private fs(size: number): number { return size * this.uiFontScale; }

  private appFont(): string {
    return this.fontDataTick >= 0
      ? FontManager.familyFor(this.systemFontFamily) : 'sans-serif';
  }

  aboutToAppear(): void {
    this.loadConvertedImage();
  }

  private async loadConvertedImage(): Promise<void> {
    if (!ArticleImageConverter.isVirtualUrl(this.url)) {
      return; // normal http(s) image: ArkUI Image loads the URL directly
    }
    const bytes: ArrayBuffer | undefined = ArticleImageConverter.getBytes(
      ArticleImageConverter.keyFromUrl(this.url)
    );
    if (!bytes) {
      Logger.warn('Zoom image bytes already evicted');
      return;
    }
    try {
      this.pixelMap = await image.createImageSource(bytes).createPixelMap();
    } catch (error) {
      Logger.warn(`Decode zoom image failed: ${(error as Error).message}`);
    }
  }

  aboutToDisappear(): void {
    if (this.pixelMap) {
      this.pixelMap.release();
      this.pixelMap = undefined;
    }
  }

  private zoomBy(factor: number): void {
    this.zoomScale = Math.max(1, Math.min(MAX_ZOOM, factor));
    if (this.zoomScale === 1) {
      this.offsetX = 0;
      this.offsetY = 0;
    }
  }

  private handleTap(): void {
    if (this.zoomScale > 1) {
      this.zoomBy(1);
      return;
    }
    this.onClose();
  }

  @Builder
  imageContent(): void {
    if (this.pixelMap) {
      Image(this.pixelMap)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.offsetX, y: this.offsetY })
    } else {
      Image(this.url)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.offsetX, y: this.offsetY })
    }
  }

  build() {
    Column() {
      Row() {
        Text('点击关闭 · 双指缩放').fontFamily(this.appFont())
          .fontSize(this.fs(13))
          .fontColor('#E8EAED')
          .layoutWeight(1)
        Text('✕').fontFamily(this.appFont())
          .fontSize(this.fs(18))
          .fontColor('#E8EAED')
          .padding({ left: 12, right: 4 })
          .onClick(() => this.onClose())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 + this.topInset, bottom: 8 })
      .onClick(() => this.onClose())

      Column() {
        this.imageContent()
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => this.handleTap())
      .gesture(
        PinchGesture({ fingers: 2, distance: 1 })
          .onActionStart(() => { this.gestureScale = this.zoomScale; })
          .onActionUpdate((event: PinchGestureEvent) => {
            this.zoomBy(this.gestureScale * event.scale);
          })
      )
      .gesture(
        PanGesture({ fingers: 1, distance: 1 })
          .onActionStart(() => {
            this.gestureOffsetX = this.offsetX;
            this.gestureOffsetY = this.offsetY;
          })
          .onActionUpdate((event: PanGestureEvent) => {
            if (this.zoomScale <= 1) {
              return;
            }
            this.offsetX = this.gestureOffsetX + event.offsetX;
            this.offsetY = this.gestureOffsetY + event.offsetY;
          })
      )
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E6000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
