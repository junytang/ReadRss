#!/usr/bin/env python3
"""Reference implementation of ReadYou's generic full-text extraction algorithm.

Kept in sync with ArkTS:
  harmony/entry/src/main/ets/rss/HtmlDom.ets        (parse/stats/best/drill)
  harmony/entry/src/main/ets/rss/FullContentFetcher.ets (maskScripts/stripChrome/clean)

Run: python3 verify.py
"""
import json
import re
import sys
import os

VOID = ['br', 'hr', 'img', 'input', 'meta', 'link', 'source', 'wbr']
BLOCK = {'div', 'article', 'section', 'main'}
CHROME_TAGS = {'script', 'style', 'noscript', 'nav', 'header', 'footer',
               'aside', 'form', 'iframe', 'svg', 'button'}
CHROME_CLASS = re.compile(
    r'header|footer|nav|sidebar|menu|comment|share|related|recommend|'
    r'advert|promo|pagination|breadcrumb|toolbar|login|copyright|meta|'
    r'notice|guide|ads|tools|rightbar|leftbar|pro-campaign|pro-unit|campaign|adsbygoogle')


class Node:
    def __init__(self, tag, attrs=''):
        self.tag = tag
        self.attrs = attrs
        self.children = []
        self.text = ''


def parse(html):
    root = Node('#document')
    stack = [root]
    i = 0
    while i < len(html):
        if html.startswith('<!--', i):
            end = html.find('-->', i + 4)
            i = len(html) if end < 0 else end + 3
            continue
        if html[i] != '<':
            nxt = html.find('<', i)
            raw = html[i:nxt] if nxt >= 0 else html[i:]
            text = re.sub(r'\s+', ' ', raw).strip()
            if text:
                tn = Node('#text')
                tn.text = text
                stack[-1].children.append(tn)
            i = nxt if nxt >= 0 else len(html)
            continue
        gt = html.find('>', i + 1)
        if gt < 0:
            break
        raw = html[i + 1:gt].strip()
        i = gt + 1
        if raw.startswith('/'):
            close = raw[1:].strip().lower()
            for k in range(len(stack) - 1, 0, -1):
                if stack[k].tag == close:
                    del stack[k:]
                    break
            continue
        if raw.startswith('!') or raw.startswith('?'):
            continue
        self_closing = raw.endswith('/')
        if self_closing:
            raw = raw[:-1].strip()
        m = re.search(r'\s', raw)
        tag = (raw[:m.start()] if m else raw).lower()
        attrs = raw[m.start():] if m else ''
        node = Node(tag, attrs)
        stack[-1].children.append(node)
        if not self_closing and tag not in VOID:
            stack.append(node)
    return root


def mask_scripts(html):
    """Blank out script/style/noscript bodies, preserving string length."""
    out = html
    for tag in ('script', 'style', 'noscript'):
        frm = 0
        while True:
            low = out.lower()
            start = low.find('<' + tag, frm)
            if start < 0:
                break
            end = low.find('</' + tag, start)
            if end < 0:
                break
            close_end = out.find('>', end)
            if close_end < 0:
                break
            out = out[:start] + ' ' * (close_end - start + 1) + out[close_end + 1:]
            frm = start
    return out


def text_len(n):
    return len(n.text) + sum(text_len(c) for c in n.children)


def class_id(n):
    out = ''
    for m in re.finditer(r'\b(?:class|id)\s*=\s*(["\'])([^"\']*)\1', n.attrs, re.I):
        out += ' ' + m.group(2)
    return out.lower()


def stats(n):
    t = len(n.text)
    lt = tc = img = 0
    if n.tag == 'a':
        lt = text_len(n)
    if n.tag == 'p':
        tc = 1
    if n.tag == 'img':
        img = 1
    br = 1 if n.tag == 'br' else 0
    for c in n.children:
        s = stats(c)
        t += s[0]; lt += s[1]; tc += s[2]; img += s[3]; br += s[4]
    return (t, lt, tc, img, br)


def content_score(n):
    t, lt, tc, img, br = stats(n)
    penalty = 200 if CHROME_CLASS.search(class_id(n)) else 0
    # <br>-rich inline text is a strong article signal; it also exempts the
    # link-heavy penalty because link lists inside posts are normal.
    # Rich-text signals: <p> paragraphs, several <br>, or embedded images.
    # Only penalise link-heavy no-paragraph nodes when none of these apply.
    rich = tc > 0 or br >= 2 or img >= 2
    if not rich:
        link_ratio = lt / t if t > 0 else 0
        if tc == 0 and link_ratio > 0.2:
            penalty += 200
    return t - lt * 2 + tc * 30 + img * 10 + (br * 15 if br >= 3 else 0) - penalty


def strip_chrome(n):
    kept = []
    for c in n.children:
        if c.tag in CHROME_TAGS:
            continue
        if CHROME_CLASS.search(class_id(c)):
            continue
        strip_chrome(c)
        kept.append(c)
    n.children = kept


def find_body(n):
    if n.tag == 'body':
        return n
    for c in n.children:
        r = find_body(c)
        if r:
            return r
    return None


def best(root):
    best_node = None
    best_score = -1e18
    stack = [root]
    while stack:
        n = stack.pop()
        st = stats(n)
        if n.tag in BLOCK and (st[0] >= 1 or st[3] >= 1):
            score = content_score(n)
            if score > best_score:
                best_score = score
                best_node = n
        stack.extend(n.children)
    return best_node


def drill(n):
    cur = n
    cur_score = content_score(cur)
    while True:
        bc, bs = None, -1e18
        for c in cur.children:
            if c.tag not in BLOCK or (text_len(c) < 1 and stats(c)[3] < 1):
                continue
            s = content_score(c)
            if s > bs:
                bs, bc = s, c
        # If the best child is text-only while a sibling holds images, stop on
        # the parent: it already contains the complete text+image article body.
        best_img = stats(bc)[3] if bc is not None else 0
        if best_img == 0:
            # A sibling holding a group of images (>=2) means this parent is
            # the text+image article body; a lone icon (avatar/logo) is not.
            sibling_image_group = any(
                c.tag in BLOCK and stats(c)[3] >= 1 and stats(c)[0] < 10
                for c in cur.children)
            if sibling_image_group:
                break
        # A child with embedded images is a strong sign of the real article
        # body; allow descending even when its score is somewhat lower.
        threshold = 0.5 if best_img >= 2 else 0.7
        if bc is None or bs < cur_score * threshold:
            break
        cur, cur_score = bc, bs
    return cur


VOID_TAGS = {'br', 'hr', 'img', 'input', 'meta', 'link', 'source', 'wbr'}

def tohtml(n):
    if n.tag == '#text':
        return n.text
    out = '<' + n.tag + n.attrs + '>' + n.text
    for c in n.children:
        out += tohtml(c)
    if n.tag not in VOID_TAGS:
        out += '</' + n.tag + '>'
    return out

def extract(html):
    cleaned = re.sub(r'<!--[\s\S]*?-->', '', html)
    cleaned = mask_scripts(cleaned)
    root = parse(cleaned)
    body = find_body(root)
    if body is None:
        body = root
    strip_chrome(body)
    found = best(body)
    return drill(found if found else body)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, 'cases.json'), encoding='utf-8') as f:
        cases = json.load(f)
    failed = 0
    for case in cases:
        path = os.path.join(here, case['file'])
        with open(path, encoding='utf-8') as f:
            html = f.read()
        node = extract(html)
        selected = (node.tag + ' ' + node.attrs) if node else ''
        ok = node is not None and case['container'] in selected.lower()
        print(('PASS' if ok else 'FAIL') + ' | ' + case['name'])
        if not ok:
            failed += 1
            print('       expected container substring: ' + case['container'])
            print('       selected: ' + selected[:160])
    print('\n%d/%d passed' % (len(cases) - failed, len(cases)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
