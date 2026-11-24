import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ArticleImageConverter } from '../common/ArticleImageConverter';
import { Logger } from '../common/Logger';
import { FontManager } from '../common/FontManager';
import { ToastUtil } from '../common/ToastUtil';
import { ImageRect } from '../common/ImageFit';

/** Maximum pinch magnification, matching Android's telephoto ZoomSpec(4f). */
const MAX_ZOOM: number = 4;

/** ArkTS needs an explicit type for object literals used as HTTP headers. */
interface ImageRequestHeaders {
  'User-Agent': string;
  'Referer'?: string;
}

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
  // Article URL sent as Referer so hotlink-protected images can be downloaded
  // for saving (and decoded here instead of relying on ArkUI's URL loader).
  @Prop referer: string = '';
  // Rect of the tapped image in the article, in window vp coordinates.
  @Prop originRect: ImageRect = { x: 0, y: 0, width: 0, height: 0 };
  onClose: () => void = () => {};
  @StorageProp('fontScale') uiFontScale: number = 1;
  @StorageProp('systemFontFamily') systemFontFamily: string = 'sans-serif';
  @StorageProp('fontDataTick') fontDataTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @State pixelMap: image.PixelMap | undefined = undefined;
  private imageBytes: ArrayBuffer | undefined = undefined;
  private imageWidth: number = 0;
  private imageHeight: number = 0;
  private areaWidth: number = 0;
  private areaHeight: number = 0;
  private openAnimated: boolean = false;
  // Backdrop fades in with the image so the black layer does not blank out the
  // article (and hide the zoom animation) on the first frame.
  @State backdropAlpha: number = 0;
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
    this.loadImage();
  }

  /** Decode every image (AVIF virtual URL or remote URL) to a PixelMap so we
   *  know its intrinsic size and can size the component to fit the viewport. */
  private async loadImage(): Promise<void> {
    let bytes: ArrayBuffer | undefined = undefined;
    if (ArticleImageConverter.isVirtualUrl(this.url)) {
      bytes = ArticleImageConverter.getBytes(ArticleImageConverter.keyFromUrl(this.url));
      if (!bytes) {
        Logger.warn('Zoom image bytes already evicted');
        return;
      }
    } else {
      const request: http.HttpRequest = http.createHttp();
      try {
        let header: ImageRequestHeaders = { 'User-Agent': 'ReadYou-Harmony' };
        if (this.referer.length > 0) {
          header = { 'Referer': this.referer, 'User-Agent': 'ReadYou-Harmony' };
        }
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          readTimeout: 15000,
          header: header,
        };
        const response: http.HttpResponse = await request.request(this.url, options);
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
      return;
    }
    this.imageBytes = bytes;
    try {
      const source: image.ImageSource = image.createImageSource(bytes);
      const info: image.ImageInfo = source.getImageInfoSync();
      this.imageWidth = info.size.width;
      this.imageHeight = info.size.height;
      this.pixelMap = await source.createPixelMap();
      this.tryAnimateOpen();
    } catch (error) {
      Logger.warn(`Decode zoom image failed: ${(error as Error).message}`);
    }
  }

  /** Animate from the tapped article image to the full-screen position. The
   *  final layout is a full-screen Contain box; scale/translate are only the
   *  transient starting transform and are animated back to identity. */
  private tryAnimateOpen(): void {
    if (this.openAnimated || !this.pixelMap) {
      return;
    }
    if (this.areaWidth <= 0 || this.areaHeight <= 0
      || this.originRect.width <= 0 || this.originRect.height <= 0) {
      // Nothing to animate from — show the backdrop immediately.
      this.openAnimated = true;
      this.backdropAlpha = 1;
      return;
    }
    // Final image size = full-screen Contain result, computed from the real
    // screen size (not the measured Stack area, which can be wrong). Allow
    // upscaling: articles often stretch a small image to full width, and the
    // no-upscale fit made the "start" bigger than the final image -> shrink.
    let screenW: number = 0;
    let screenH: number = 0;
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      screenW = this.getUIContext().px2vp(screen.width);
      screenH = this.getUIContext().px2vp(screen.height);
    } catch (error) {
      Logger.warn(`Screen size unavailable for zoom animation: ${(error as Error).message}`);
      this.openAnimated = true;
      this.backdropAlpha = 1;
      return;
    }
    const imgW: number = this.getUIContext().px2vp(this.imageWidth);
    const imgH: number = this.getUIContext().px2vp(this.imageHeight);
    if (imgW <= 0 || imgH <= 0 || screenW <= 0 || screenH <= 0) {
      this.openAnimated = true;
      this.backdropAlpha = 1;
      return;
    }
    const fitScale: number = Math.min(screenW / imgW, screenH / imgH);
    const finalW: number = imgW * fitScale;
    const finalH: number = imgH * fitScale;
    this.openAnimated = true;
    const startScale: number = Math.max(0.05, Math.min(4, this.originRect.width / finalW));
    const originCenterX: number = this.originRect.x + this.originRect.width / 2;
    const originCenterY: number = this.originRect.y + this.originRect.height / 2;
    const finalCenterX: number = screenW / 2;
    const finalCenterY: number = screenH / 2;
    // Seed the transform + transparent backdrop before the next paint, then
    // animate both to their final values in the same frame.
    this.zoomScale = startScale;
    this.offsetX = originCenterX - finalCenterX;
    this.offsetY = originCenterY - finalCenterY;
    this.backdropAlpha = 0;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.zoomScale = 1;
      this.offsetX = 0;
      this.offsetY = 0;
      this.backdropAlpha = 1;
    });
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
    // Reuse the bytes decoded on open (already carries the article Referer),
    // so saving never depends on a second network round trip.
    const bytes: ArrayBuffer | undefined = this.imageBytes;
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
    // Full-screen Image box with Contain: ArkUI centres the decoded bitmap
    // inside the box. No manual area/density math — that produced a tiny image
    // and a wrong offset on the real device.
    if (this.pixelMap) {
      Image(this.pixelMap)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.offsetX, y: this.offsetY })
    }
    // No URL placeholder: before decode it showed a second, differently-sized
    // image for a frame, which is what made the viewer flash on open.
  }

  build() {
    Stack() {
      // Backdrop is a separate layer whose opacity is animated together with
      // the image transform. It must not be the Stack's own backgroundColor:
      // that paints instantly and would cover the article before the zoom
      // animation has a chance to show it.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#FF000000')
        .opacity(this.backdropAlpha)
        .hitTestBehavior(HitTestMode.None)

      // Full-screen, definite-size layer. Contain inside the Image centres the
      // bitmap; the wrapper itself fills the screen so Stack alignment is moot.
      Column() {
        this.imageContent()
      }
      .width('100%')
      .height('100%')
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

      // Header is also absolutely positioned so it cannot be affected by the
      // Stack's alignment either.
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
      .position({ x: 0, y: 0 })
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.TopStart)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.areaWidth = newValue.width as number;
      this.areaHeight = newValue.height as number;
      this.tryAnimateOpen();
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
