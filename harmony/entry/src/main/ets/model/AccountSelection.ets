/**
 * Pure helper for carrying a list selection across accounts. Feed/group ids
 * are account-scoped (`dbId(account.id, ...)`) and even differ between a
 * GReader and a Miniflux account on the SAME server (different id spaces), so
 * the raw id cannot be reused. Match by stable identity instead: feed URL and
 * group name. If the target no longer exists, fall back to "全部" (no ids).
 */

export interface SelectionFeed {
  id: string;
  url: string;
  title: string;
}

export interface SelectionGroup {
  id: string;
  name: string;
}

export interface SelectionResult {
  feedId: string;
  groupId: string;
}

export function remapSelectionToAccount(
  feedId: string,
  groupId: string,
  previousFeeds: SelectionFeed[],
  previousGroups: SelectionGroup[],
  nextFeeds: SelectionFeed[],
  nextGroups: SelectionGroup[]
): SelectionResult {
  const empty: SelectionResult = { feedId: '', groupId: '' };
  if (groupId.length > 0) {
    let name: string = '';
    for (const group of previousGroups) {
      if (group.id === groupId) {
        name = group.name;
        break;
      }
    }
    if (name.length === 0) {
      return empty;
    }
    const normalizedName: string = normalizeIdentity(name);
    for (const group of nextGroups) {
      if (normalizeIdentity(group.name) === normalizedName) {
        return { feedId: '', groupId: group.id };
      }
    }
    return empty;
  }
  if (feedId.length > 0) {
    let url: string = '';
    let title: string = '';
    for (const feed of previousFeeds) {
      if (feed.id === feedId) {
        url = normalizeIdentity(feed.url);
        title = normalizeIdentity(feed.title);
        break;
      }
    }
    // All comparisons go through normalizeIdentity(): FreshRSS/GReader can
    // return full-width characters (e.g. "／"), other protocols half-width.
    // Prefer exact URL, then normalised title, then an unqualified URL suffix
    // (path + query, ignoring scheme/host/trailing slash).
    const urlSuffix: string = urlPathSuffix(url);
    if (url.length > 0) {
      for (const feed of nextFeeds) {
        if (normalizeIdentity(feed.url) === url) {
          return { feedId: feed.id, groupId: '' };
        }
      }
    }
    if (title.length > 0) {
      for (const feed of nextFeeds) {
        if (normalizeIdentity(feed.title) === title) {
          return { feedId: feed.id, groupId: '' };
        }
      }
    }
    if (urlSuffix.length > 1) {
      for (const feed of nextFeeds) {
        if (urlPathSuffix(normalizeIdentity(feed.url)) === urlSuffix) {
          return { feedId: feed.id, groupId: '' };
        }
      }
    }
  }
  return empty;
}

/** path + query only, ignoring scheme/host. Input is already normalised. */
function urlPathSuffix(normalizedUrl: string): string {
  const scheme: number = normalizedUrl.indexOf('://');
  const path: number = scheme >= 0 ? normalizedUrl.indexOf('/', scheme + 3) : -1;
  return path >= 0 ? normalizedUrl.substring(path) : normalizedUrl;
}

/** Full-width -> half-width (same mapping as XmlParser.normalizeFullWidth),
 *  ideographic space -> space, trim, case-fold and drop trailing slashes so a
 *  source survives account switches across GReader / FreshRSS / Miniflux /
 *  Fever / Local. Kept self-contained so the helper stays pure. */
function normalizeIdentity(value: string): string {
  let out: string = '';
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code >= 0xFF01 && code <= 0xFF5E) {
      out += String.fromCharCode(code - 0xFEE0);
    } else if (code === 0x3000) {
      out += ' ';
    } else {
      out += value.charAt(i);
    }
  }
  out = out.replace(/\s+/g, '').toLowerCase();
  while (out.length > 1 && out.charAt(out.length - 1) === '/') {
    out = out.substring(0, out.length - 1);
  }
  return out;
}
