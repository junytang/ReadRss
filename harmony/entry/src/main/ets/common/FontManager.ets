import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const FONT_NAME: string = 'ReadYouCustom';
let activeFamily: string = 'sans-serif';
const FONT_FILE: string = 'readyou-custom-font.ttf';

/** Custom font installation and registration (Android has no direct equivalent). */
export class FontManager {
  static fontPath(context: common.Context): string {
    return `${context.filesDir}/${FONT_FILE}`;
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
   * Registers the custom font. Also registers under "sans-serif" (ArkUI's default
   * family) so existing Text components without an explicit fontFamily pick it up.
   */
  static register(uiContext: UIContext, path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      const src: string = `file://${path}`;
      uiContext.getFont().registerFont({ familyName: FONT_NAME, familySrc: src });
      activeFamily = FONT_NAME;
      Logger.info(`Custom font registered: ${path}`);
    } catch (error) {
      Logger.error(`Register font failed: ${(error as Error).message}`);
    }
  }

  static remove(context: common.Context): void {
    activeFamily = 'sans-serif';
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
}
