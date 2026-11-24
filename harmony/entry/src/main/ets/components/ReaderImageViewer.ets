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
  // In a Parallel gesture group a long press can also produce a Tap on release.
  // Suppress that tap so the viewer does not close while the save dialog opens.
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
    Stack() {
      // Full-screen definite-size layer: the image is centred in the viewport,
      // not in the area left over below the header (layoutWeight used to make
      // percentage heights resolve unpredictably and push the image upward).
      Column() {
        this.imageContent()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      // ONE parallel group. With separate .gesture() calls the 1-pixel Pan
      // consumed the touch before LongPress could fire, and the trailing
      // onClick then dismissed the viewer. Parallel recognition lets each
      // gesture work independently; longPressHandled filters the follow-up tap.
      .gesture(
        GestureGroup(GestureMode.Parallel,
          LongPressGesture().onAction(() => {
            this.longPressHandled = true;
            this.saveToGallery();
          }),
          PinchGesture({ fingers: 2, distance: 1 })
            .onActionStart(() => { this.gestureScale = this.zoomScale; })
            .onActionUpdate((event: PinchGestureEvent) => {
              this.zoomBy(this.gestureScale * event.scale);
            }),
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
            }),
          TapGesture().onAction(() => {
            if (this.longPressHandled) {
              this.longPressHandled = false;
              return;
            }
            this.handleTap();
          })
        )
      )

      // Header floats above the image; its own close button still receives taps.
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
      .onClick(() => this.onClose())
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E6000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
