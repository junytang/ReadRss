import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { text } from '@kit.ArkGraphics2D';
import { Logger } from './Logger';

const FONT_NAME: string = 'ReadYouCustom';
let activeFamily: string = 'sans-serif';
let customRegistered: boolean = false;
let customFontName: string = '';
const FONT_FILE: string = 'readyou-custom-font.ttf';

/** Custom font installation and registration (Android has no direct equivalent). */
export class FontManager {
  static fontPath(context: common.Context): string {
    return `${context.filesDir}/${FONT_FILE}`;
  }

  /** Original file name of the installed custom font, for display in settings. */
  static fontName(): string {
    return customFontName;
  }

  /** Opens the system file picker, copies the chosen TTF/OTF into the app sandbox. */
  static async pickAndInstall(context: common.Context): Promise<string> {
    try {
      const options: picker.DocumentSelectOptions = {
        fileSuffixFilters: ['.ttf', '.otf'],
        maxSelectNumber: 1,
      };
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.select(options);
      if (uris.length === 0) {
        return '';
      }
      const rawName: string = decodeURIComponent(uris[0]);
      const slash: number = rawName.lastIndexOf('/');
      customFontName = slash >= 0 ? rawName.substring(slash + 1) : rawName;
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      try {
        const destination = fs.openSync(
          FontManager.fontPath(context),
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE
        );
        try {
          fs.truncateSync(destination.fd, 0);
          fs.copyFileSync(source.fd, destination.fd);
        } finally {
          fs.closeSync(destination);
        }
      } finally {
        fs.closeSync(source);
      }
      return FontManager.fontPath(context);
    } catch (error) {
      Logger.error(`Pick font failed: ${(error as Error).message}`);
      return '';
    }
  }

  /**
   * Loads the custom font synchronously so its glyphs are ready before the first
   * paint. The SDK's getFont().registerFont() is asynchronous — text renders with
   * a fallback font, then reflows once the font loads (a visible jitter on cold
   * start). text.FontCollection.loadFontSync() (the SDK-recommended replacement)
   * registers the same family name synchronously, eliminating that reflow.
   */
  static register(uiContext: UIContext, path: string): void {
    if (path.length === 0) {
      return;
    }
    const src: string = `file://${path}`;
    try {
      text.FontCollection.getGlobalInstance().loadFontSync(FONT_NAME, src);
      customRegistered = true;
      activeFamily = FONT_NAME;
      Logger.info(`Custom font loaded synchronously: ${path}`);
    } catch (error) {
      // Fallback for devices where the text-engine API is unavailable.
      try {
        uiContext.getFont().registerFont({ familyName: FONT_NAME, familySrc: src });
        customRegistered = true;
        activeFamily = FONT_NAME;
        Logger.info(`Custom font registered (async fallback): ${path}`);
      } catch (innerError) {
        Logger.error(`Register font failed: ${(innerError as Error).message}`);
      }
    }
  }

  static remove(context: common.Context): void {
    customRegistered = false;
    customFontName = '';
    activeFamily = 'sans-serif';
    try {
      text.FontCollection.getGlobalInstance().unloadFontSync(FONT_NAME);
    } catch (error) {
      Logger.warn(`Unload font skipped: ${(error as Error).message}`);
    }
    try {
      fs.unlinkSync(FontManager.fontPath(context));
    } catch (error) {
      Logger.error(`Remove font failed: ${(error as Error).message}`);
    }
  }

  /** Font family explicitly applied to every Text component. */
  static family(): string {
    return activeFamily;
  }

  /** Resolve a stored font key to an ArkUI family name. 'custom' maps to the
   *  installed font, falling back to the system default when unavailable. */
  static familyFor(key: string): string {
    if (key === 'custom') {
      return customRegistered ? FONT_NAME : 'sans-serif';
    }
    return key.length > 0 ? key : 'sans-serif';
  }

  static isCustomInstalled(): boolean {
    return customRegistered;
  }

  /** Apply the chosen system-wide font family to all native Text components. */
  static setSystemFamily(key: string): void {
    activeFamily = FontManager.familyFor(key);
  }
}
