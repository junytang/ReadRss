import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ArticleImageConverter } from '../common/ArticleImageConverter';
import { Logger } from '../common/Logger';
import { FontManager } from '../common/FontManager';
import { ToastUtil } from '../common/ToastUtil';

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
  // Long press is driven by a touch timer, not GestureGroup: on this device a
  // GestureGroup swallowed both LongPress and Pinch while leaving only Tap.
  private longPressTimer: number = -1;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  // A tap follows a long press on release; ignore it so the viewer stays open
  // while the gallery dialog is shown.
  private longPressHandled: boolean = false;

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
    this.cancelLongPress();
    if (this.pixelMap) {
      this.pixelMap.release();
      this.pixelMap = undefined;
    }
  }

  private cancelLongPress(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  /** Timer-based long press: independent of ArkUI's gesture arbitration, which
   *  on some builds lets Tap win over LongPress/Pinch in the same group. */
  private handleImageTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    if (event.touches.length > 1) {
      // A second finger means pinch zoom, never a long press.
      this.cancelLongPress();
      return;
    }
    const touch: TouchObject = event.touches[0];
    if (event.type === TouchType.Down) {
      this.touchStartX = touch.x;
      this.touchStartY = touch.y;
      this.longPressHandled = false;
      this.cancelLongPress();
      this.longPressTimer = setTimeout((): void => {
        this.longPressTimer = -1;
        this.longPressHandled = true;
        this.saveToGallery();
      }, 500);
    } else if (event.type === TouchType.Move) {
      // A deliberate pan/pinch is not a long press.
      if (Math.abs(touch.x - this.touchStartX) > 10
        || Math.abs(touch.y - this.touchStartY) > 10) {
        this.cancelLongPress();
      }
    } else {
      this.cancelLongPress();
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

  /** Long press downloads the image to the system gallery. The authorization
   *  pop-up grants a temporary write URI, so no WRITE_IMAGEVIDEO permission is
   *  needed (Android asks nothing either). */
  private async saveToGallery(): Promise<void> {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    let bytes: ArrayBuffer | undefined = undefined;
    if (ArticleImageConverter.isVirtualUrl(this.url)) {
      bytes = ArticleImageConverter.getBytes(ArticleImageConverter.keyFromUrl(this.url));
    } else {
      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(this.url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          readTimeout: 15000,
        });
        if (response.responseCode === 200) {
          bytes = response.result as ArrayBuffer;
        }
      } catch (error) {
        Logger.warn(`Fetch zoom image failed: ${(error as Error).message}`);
      } finally {
        request.destroy();
      }
    }
    if (!bytes) {
      ToastUtil.show(this.getUIContext(), '图片尚未加载完成');
      return;
    }

    const sandboxPath: string = `${context.cacheDir}/readyou_zoom_${Date.now()}.jpg`;
    try {
      const file = fs.openSync(sandboxPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        fs.truncateSync(file.fd, 0);
        fs.writeSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const configs: photoAccessHelper.PhotoCreationConfig[] = [{
        title: 'ReadRss',
        fileNameExtension: 'jpg',
        photoType: photoAccessHelper.PhotoType.IMAGE,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT,
      }];
      // User confirms in the system dialog; the returned URI is writable.
      const targets: string[] = await helper.showAssetsCreationDialog([sandboxPath], configs);
      if (targets.length === 0) {
        return; // user cancelled
      }
      const source = await fs.open(sandboxPath, fs.OpenMode.READ_ONLY);
      try {
        const target = await fs.open(targets[0], fs.OpenMode.WRITE_ONLY);
        try {
          await fs.copyFile(source.fd, target.fd);
        } finally {
          await fs.close(target.fd);
        }
      } finally {
        await fs.close(source.fd);
      }
      ToastUtil.show(this.getUIContext(), '已保存到图库');
    } catch (error) {
      Logger.error(`Save zoom image failed: ${(error as Error).message}`);
      ToastUtil.show(this.getUIContext(), '保存失败');
    } finally {
      try {
        fs.unlinkSync(sandboxPath);
      } catch (error) {
        // Best effort: temp file in cacheDir is harmless if removal fails.
      }
    }
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
      // Header is a normal first child, so it stays pinned to the top. Putting
      // it in the Stack before made Stack's default centre alignment push it
      // to the middle of the screen.
      Row() {
        Text('点击关闭 · 双指缩放 · 长按保存').fontFamily(this.appFont())
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
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 12 + this.topInset, bottom: 8 })

      // The image area fills the rest; Stack's explicit centre alignment
      // centres the image both vertically and horizontally.
      Stack() {
        this.imageContent()
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Center)
      .onTouch((event: TouchEvent) => this.handleImageTouch(event))
      .onClick(() => {
        if (this.longPressHandled) {
          this.longPressHandled = false;
          return;
        }
        this.handleTap();
      })
      .gesture(
        PinchGesture({ fingers: 2, distance: 1 })
          .onActionStart(() => { this.gestureScale = this.zoomScale; })
          .onActionUpdate((event: PinchGestureEvent) => {
            this.zoomBy(this.gestureScale * event.scale);
          })
      )
      .gesture(
        PanGesture({ fingers: 1, distance: 8 })
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
