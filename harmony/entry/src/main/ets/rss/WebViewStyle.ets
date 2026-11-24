import { readerAlignCss } from '../common/Constants';

/** ArkTS port of Android's WebViewStyle.get() CSS variable system.
 *  The variable map is the single source of truth: get() renders it into CSS,
 *  and the settings preview applies the very same map via runJavaScript, so a
 *  style change never needs to reload (and flash) the WebView document. */
export class WebViewStyle {
  static variables(
    dark: boolean, fontSize: number, fontFamily: string,
    pageMargin: number, lineSpacing: number,
    letterSpacing: number = 0.5, textAlign: number = 0
  ): Map<string, string> {
    const textColor: string = dark ? '#E8EAED' : '#191C1E';
    // CSS generic keywords must stay unquoted; only custom named fonts need
    // quoting. Quoting "sans-serif" turns it into a literal (missing) family.
    const generic: boolean = fontFamily === 'sans-serif' || fontFamily === 'serif'
      || fontFamily === 'monospace';
    const familyCss: string = generic
      ? `${fontFamily}, "HarmonyOS Sans SC", sans-serif`
      : `"${fontFamily}", "HarmonyOS Sans SC", sans-serif`;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('--font-family', familyCss);
    vars.set('--font-size', `${fontSize}px`);
    vars.set('--line-height', `${lineSpacing}`);
    vars.set('--letter-spacing', `${letterSpacing}px`);
    vars.set('--paragraph-gap', '1em');
    vars.set('--text-margin', `${pageMargin}px`);
    vars.set('--text-color', textColor);
    vars.set('--text-bold', 'normal');
    vars.set('--text-align', readerAlignCss(textAlign));
    vars.set('--bold-text-color', dark ? '#FFFFFF' : '#111417');
    vars.set('--link-text-color', dark ? '#8AB4F8' : '#2663D6');
    vars.set('--selection-text-color', textColor);
    vars.set('--selection-bg-color', dark ? '#5E636A' : '#C8E6C9');
    vars.set('--subhead-bold', '600');
    vars.set('--subhead-upper-case', 'none');
    vars.set('--img-margin', '0px');
    vars.set('--img-border-radius', '8px');
    vars.set('--blockquote-margin', '20px');
    vars.set('--blockquote-bg-color', 'transparent');
    vars.set('--blockquote-border-width', '3px');
    vars.set('--blockquote-border-color', `${textColor}55`);
    vars.set('--table-margin', '0px');
    vars.set('--table-cell-padding', '0.2em');
    vars.set('--code-text-color', dark ? '#E8EAED' : '#202124');
    vars.set('--code-bg-color', dark ? '#2A2E33' : '#F1F3F4');
    vars.set('--code-font-family', "Menlo, Monospace, 'Courier New'");
    vars.set('--code-font-size', '0.9em');
    vars.set('--table-row-even-bg', dark ? '#2A2E33' : '#F8F9FA');
    return vars;
  }

  static get(
    dark: boolean, fontSize: number, fontFamily: string,
    pageMargin: number, lineSpacing: number,
    letterSpacing: number = 0.5, textAlign: number = 0
  ): string {
    const vars: Map<string, string> = WebViewStyle.variables(
      dark, fontSize, fontFamily, pageMargin, lineSpacing, letterSpacing, textAlign
    );
    let root: string = ':root {\n';
    vars.forEach((value: string, key: string): void => {
      root += `    ${key}: ${value};\n`;
    });
    root += '}';
    return root + `
main { padding-bottom: 96px; }
article {
    padding: 0;
    margin: 0;
    margin-left: var(--text-margin) !important;
    margin-right: var(--text-margin) !important;
    line-height: var(--line-height) !important;
    font-family: var(--font-family) !important;
    font-size: var(--font-size) !important;
    font-weight: var(--text-bold) !important;
    color: var(--text-color) !important;
}
body { margin: 0; padding: 0; }
::selection {
    background-color: var(--selection-bg-color) !important;
    color: var(--selection-text-color) !important;
}
h1, h2, h3, h4, h5, h6 {
    font-weight: var(--subhead-bold) !important;
    text-transform: var(--subhead-upper-case) !important;
    line-height: calc(min(1.2, var(--line-height))) !important;
    letter-spacing: var(--letter-spacing) !important;
    color: var(--bold-text-color) !important;
    text-align: var(--text-align) !important;
}
/* Heading sizes must stay below the article title. The browser defaults
   (h1=2em, h2=1.5em) made in-article subheadings larger than the title. */
h1 { font-size: calc(var(--font-size) * 1.2) !important; }
h2 { font-size: calc(var(--font-size) * 1.12) !important; }
h3 { font-size: calc(var(--font-size) * 1.05) !important; }
h4, h5, h6 { font-size: var(--font-size) !important; }
/* Article title rendered above the body in the WebView. */
h1.article-title {
    font-size: calc(var(--font-size) * 1.35) !important;
    text-align: center !important;
    /* Leave breathing room at the top instead of hugging the viewport edge. */
    margin-top: 0.8em !important;
    margin-bottom: 1em !important;
}
p {
    max-width: 100% !important;
    word-wrap: break-word !important;
    overflow-wrap: break-word !important;
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
    /* Explicit paragraph spacing so it matches the preview exactly.
       Adjacent margins collapse in CSS, so bottom 1em + next top 0 gives a
       reliable 1em gap between paragraphs. */
    margin-top: 0 !important;
    margin-bottom: var(--paragraph-gap) !important;
}
/* Empty paragraphs from feeds render as several blank lines in ArkWeb. */
p:empty { margin: 0 !important; line-height: 0 !important; }
span {
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
}
strong, b { font-weight: 600 !important; color: var(--bold-text-color) !important; }
a, a > strong {
    -webkit-tap-highlight-color: rgba(0,0,0,0);
    font-weight: 600 !important;
    color: var(--link-text-color) !important;
}
/* Only a link that is the sole content of its div is treated as a block
   (e.g. a "read more" link). Inline links mixed with text and <br> stay inline. */
div > a:only-child {
    display: block;
    -webkit-tap-highlight-color: rgba(0,0,0,0);
    font-weight: 600 !important;
    color: var(--link-text-color);
    line-height: var(--line-height);
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
}
iframe, video, embed, object, img {
    margin-top: 0.5em !important;
    margin-left: calc(0px - var(--text-margin) + var(--img-margin)) !important;
    margin-right: calc(0px - var(--text-margin) + var(--img-margin)) !important;
    max-width: calc(100% + 2 * var(--text-margin) - 2 * var(--img-margin)) !important;
    border-radius: var(--img-border-radius) !important;
}
img { height: auto !important; }
img.loaded { opacity: 1; }
img.thin {
    margin-top: 0.5em !important;
    margin-bottom: 0.5em !important;
    margin-left: unset !important;
    margin-right: unset !important;
    max-width: 100% !important;
}
p > img {
    margin-top: 0.5em !important;
    margin-bottom: 0.5em !important;
    margin-left: calc(0px - var(--text-margin) + var(--img-margin)) !important;
    margin-right: calc(0px - var(--text-margin) + var(--img-margin)) !important;
    max-width: calc(100% + 2 * var(--text-margin) - 2 * var(--img-margin)) !important;
    height: auto !important;
    border-radius: var(--img-border-radius) !important;
}
img + small {
    display: inline-block;
    line-height: calc(min(1.5, var(--line-height))) !important;
    letter-spacing: var(--letter-spacing) !important;
    margin-top: 0.4em !important;
    text-align: var(--text-align) !important;
}
ul, ol {
    padding-left: 0 !important;
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
}
li {
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    margin-left: 1.5em !important;
    text-align: var(--text-align) !important;
}
blockquote {
    margin-left: 0.5em !important;
    padding-left: 0.9em !important;
    background-color: var(--blockquote-bg-color) !important;
    border-left: var(--blockquote-border-width) solid var(--blockquote-border-color) !important;
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
}
blockquote blockquote { margin-right: 0 !important; }
blockquote img { max-width: 100% !important; left: 0 !important; }
table {
    display: block;
    width: 100% !important;
    border-collapse: collapse !important;
    margin-left: var(--table-margin) !important;
    margin-right: var(--table-margin) !important;
}
table th, table td {
    border: 1px solid var(--text-color) !important;
    padding: var(--table-cell-padding) !important;
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
}
table tr { display: block; }
table tr:nth-child(even) { background-color: var(--table-row-even-bg) !important; }
pre, code {
    color: var(--code-text-color) !important;
    background-color: var(--code-bg-color) !important;
    border-radius: 8px !important;
    padding: 2px 5px !important;
    margin: 2px !important;
    font-family: var(--code-font-family) !important;
    font-size: var(--code-font-size) !important;
}
pre { overflow: auto !important; }
code { display: inline-block !important; }
li code {
    white-space: pre-wrap !important;
    word-wrap: break-word !important;
    overflow-wrap: break-word !important;
    max-width: 100% !important;
}
figure {
    line-height: calc(min(1.5, var(--line-height))) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
    margin: 0 !important;
    font-size: 12px !important;
}
figure * { font-size: 1em !important; }
figure p, caption, figcaption { font-size: 12px !important; }
hr {
    border: 0 !important;
    height: 2px !important;
    background-color: var(--text-color) !important;
    opacity: 0.08 !important;
    border-radius: 2px;
}
`;
  }
}
