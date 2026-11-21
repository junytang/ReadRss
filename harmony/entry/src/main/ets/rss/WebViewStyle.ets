/** ArkTS port of Android's WebViewStyle.get() CSS variable system. */
export class WebViewStyle {
  static get(dark: boolean, fontSize: number, fontFamily: string): string {
    const textColor: string = dark ? '#E8EAED' : '#191C1E';
    const boldColor: string = dark ? '#FFFFFF' : '#111417';
    const linkColor: string = dark ? '#8AB4F8' : '#2663D6';
    const codeColor: string = dark ? '#E8EAED' : '#202124';
    const codeBg: string = dark ? '#2A2E33' : '#F1F3F4';
    const selectionBg: string = dark ? '#5E636A' : '#C8E6C9';

    return `
:root {
    --font-family: ${fontFamily};
    --font-size: ${fontSize}px;
    --line-height: 1.75;
    --letter-spacing: 0px;
    --text-margin: 16px;
    --text-color: ${textColor};
    --text-bold: normal;
    --text-align: left;
    --bold-text-color: ${boldColor};
    --link-text-color: ${linkColor};
    --selection-text-color: ${textColor};
    --selection-bg-color: ${selectionBg};
    --subhead-bold: 600;
    --subhead-upper-case: none;
    --img-margin: 0px;
    --img-border-radius: 8px;
    --blockquote-margin: 20px;
    --blockquote-bg-color: transparent;
    --blockquote-border-width: 3px;
    --blockquote-border-color: ${textColor}55;
    --table-margin: 0px;
    --table-cell-padding: 0.2em;
    --code-text-color: ${codeColor};
    --code-bg-color: ${codeBg};
    --code-font-family: Menlo, Monospace, 'Courier New';
    --code-font-size: 0.9em;
}
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
p {
    max-width: 100% !important;
    word-wrap: break-word !important;
    overflow-wrap: break-word !important;
    line-height: var(--line-height) !important;
    letter-spacing: var(--letter-spacing) !important;
    text-align: var(--text-align) !important;
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
table tr:nth-child(even) { background-color: ${dark ? '#2A2E33' : '#F8F9FA'} !important; }
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
