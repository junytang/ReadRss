/** ArkTS port of Android's WebViewHtml.HTML template. */
export class WebViewHtml {
  static readonly HTML: string = `<!DOCTYPE html>
<html dir="auto">
<head>
<meta name="viewport" content="initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, width=device-width, viewport-fit=cover" />
<meta content="text/html; charset=utf-8" http-equiv="content-type" />
<style type="text/css">
%s
</style>
<base href="%s" />
</head>
<body>
<main>
<article>
%s
</article>
</main>
<script>
%s
</script>
</body>
</html>`;

  /** Minimal port of WebViewScript.get() (image load states). */
  static readonly SCRIPT: string = `(function(){
  // Avoid a flash of unstyled text: a custom @font-face is served asynchronously
  // through onInterceptRequest, so keep the document hidden until fonts settle,
  // with a timeout fallback in case the Font Loading API is unavailable.
  var root = document.documentElement;
  root.style.visibility = 'hidden';
  var revealed = false;
  function reveal() {
    if (revealed) return;
    revealed = true;
    root.style.visibility = 'visible';
    // Tell native that THIS document (the one whose script is running) is
    // rendered and visible. Because the callback comes from the new document,
    // it cannot be a stale onPageEnd from a previous load - safe to gate the
    // prev/next slide-in on this signal.
    if (window.readYouBridge && window.readYouBridge.onPageReady) {
      try { window.readYouBridge.onPageReady(); } catch (e) {}
    }
  }
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(reveal, reveal);
    setTimeout(reveal, 1200);
  } else { reveal(); }
})();
function collapseEmptyParagraphs() {
    var ps = document.querySelectorAll("article p");
    for (var i = 0; i < ps.length; i++) {
        var p = ps[i];
        if (p.textContent.trim() !== "") continue;
        if (p.querySelector("img, video, iframe, table, pre, svg, hr")) continue;
        if (p.parentNode) p.parentNode.removeChild(p);
    }
}
collapseEmptyParagraphs();
function setupImages() {
    var images = document.querySelectorAll("img");
    images.forEach(function(img) {
        var lazy = img.getAttribute("data-original") || img.getAttribute("data-src") || img.getAttribute("data-lazy-src");
        if (lazy && lazy !== img.getAttribute("src")) { img.src = lazy; }
        if (!img.onload) {
            img.onload = function() {
                img.classList.add("loaded");
                if (img.width < 412) { img.classList.add("thin"); }
            };
            img.onerror = function() { console.error("Failed to load image:", img.src); };
        }
    });
}
setupImages();
// Tap an image (not part of a link) to open the native full-screen viewer.
// The bridge method is optional so the settings preview, which uses the same
// HTML/CSS pipeline but registers no bridge, is unaffected.
function setupImageClicks() {
    var images = document.querySelectorAll("article img");
    images.forEach(function(img) {
        if (img.getAttribute("data-ry-zoom")) return;
        img.setAttribute("data-ry-zoom", "1");
        img.style.cursor = "zoom-in";
        img.addEventListener("click", function(ev) {
            if (img.closest && img.closest("a")) return;
            ev.preventDefault();
            if (window.readYouBridge && window.readYouBridge.onImageClick) {
                try {
                    var r = img.getBoundingClientRect();
                    window.readYouBridge.onImageClick(
                        img.currentSrc || img.src, r.left, r.top, r.width, r.height
                    );
                } catch (e) {}
            }
        });
    });
}
setupImageClicks();
// Tell native that an article link was followed, so the reader's back button
// walks the WebView history before popping the reader page.
function setupLinkClicks() {
    var links = document.querySelectorAll("article a");
    links.forEach(function(a) {
        if (a.getAttribute("data-ry-link")) return;
        a.setAttribute("data-ry-link", "1");
        a.addEventListener("click", function() {
            if (window.readYouBridge && window.readYouBridge.onLinkClick) {
                try { window.readYouBridge.onLinkClick(); } catch (e) {}
            }
        });
    });
}
setupLinkClicks();
window.addEventListener("scroll", setupImages);
// The reader HTML is injected as a whole, so every <img> already exists when
// this script runs; the old setInterval(setupImages, 800) just re-scanned all
// images forever after onload was already attached, keeping the WebView busy.
// Watch for genuine DOM changes instead (e.g. dynamically inserted images) and
// drop the permanent 800ms wake-up.
if (window.MutationObserver) {
  var imgObserver = new MutationObserver(function() { setupImages(); setupImageClicks(); setupLinkClicks(); });
  imgObserver.observe(document.body, { childList: true, subtree: true });
}`;

  /**
   * Build the script that updates reader CSS variables in an already-loaded
   * document. Using this instead of loadData() keeps the WebView's rendering
   * context alive, so the live preview does not flash white on every change.
   * The values come from WebViewStyle.variables() — the same map that produced
   * the document's original :root block.
   */
  static applyVariables(vars: Map<string, string>): string {
    let script: string = '(function(){var s=document.documentElement.style;';
    vars.forEach((value: string, key: string): void => {
      script += `s.setProperty(${JSON.stringify(key)},${JSON.stringify(value)});`;
    });
    script += '})()';
    return script;
  }

  static fill(style: string, baseHref: string, body: string): string {
    // Function replacers avoid String.replace's `$&` / `$'` substitution
    // semantics, which would corrupt article HTML containing those sequences.
    let result: string = WebViewHtml.HTML;
    result = result.replace('%s', (): string => style);
    result = result.replace('%s', (): string => baseHref);
    result = result.replace('%s', (): string => body);
    result = result.replace('%s', (): string => WebViewHtml.SCRIPT);
    return result;
  }
}
