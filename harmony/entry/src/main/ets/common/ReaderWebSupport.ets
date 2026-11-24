import { ReaderFont } from './ReaderFont';

/**
 * Shared ArkWeb support for every surface that renders reader HTML: the
 * ReadingView and the live preview in ReaderStyleView. Both must load the same
 * @font-face CSS and serve the same virtual font URL, otherwise the preview can
 * silently differ from the real reader when a custom font is installed.
 */
export class ReaderWebSupport {
  /** @font-face rule for the selected reader font; empty for system fonts. */
  static fontCss(fontKey: string, fontPath: string): string {
    if (fontKey !== 'custom' || !ReaderFont.exists(fontPath)) {
      return '';
    }
    return `@font-face { font-family: 'ReadYouCustom'; ` +
      `src: url('${ReaderFont.virtualUrl(fontPath)}') format('truetype'); }`;
  }

  static isFontUrl(url: string): boolean {
    return ReaderFont.isVirtualUrl(url);
  }

  /** Font bytes for a virtual URL, or undefined for any other request. */
  static fontBytes(url: string, fontPath: string): ArrayBuffer | undefined {
    if (!ReaderFont.isVirtualUrl(url)) {
      return undefined;
    }
    return ReaderFont.load(fontPath);
  }
}
