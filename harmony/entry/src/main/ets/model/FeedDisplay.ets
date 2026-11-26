/**
 * Normalise feed names / URLs at display time. FreshRSS (through its GReader
 * compatibility API) often returns the feed URL AS the feed name, and may
 * use full-width characters (e.g. "／" instead of "/", "：" instead of ":").
 * Normal display text keeps its original full-width punctuation; only URL-like
 * values are converted to half-width so slashes and colons render correctly.
 */
export function normalizeFeedText(value: string): string {
  if (value.length === 0) {
    return value;
  }
  // First convert just the URL delimiters; this may reveal a URL.
  let delimiters: string = '';
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code === 0xFF0F) {
      delimiters += '/';
    } else if (code === 0xFF1A) {
      delimiters += ':';
    } else if (code === 0x3000) {
      delimiters += ' ';
    } else {
      delimiters += value.charAt(i);
    }
  }
  if (delimiters.indexOf('://') < 0 && delimiters.indexOf('www.') !== 0
    && delimiters.charAt(0) !== '/') {
    // Ordinary title: keep its original characters.
    return value;
  }
  // URL-like: full-width -> half-width (same mapping as XmlParser), trim.
  let out: string = '';
  for (let i: number = 0; i < delimiters.length; i++) {
    const code: number = delimiters.charCodeAt(i);
    if (code >= 0xFF01 && code <= 0xFF5E) {
      out += String.fromCharCode(code - 0xFEE0);
    } else {
      out += delimiters.charAt(i);
    }
  }
  return out.trim();
}
