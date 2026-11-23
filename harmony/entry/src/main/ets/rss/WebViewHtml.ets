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
window.addEventListener("scroll", setupImages);
// The reader HTML is injected as a whole, so every <img> already exists when
// this script runs; the old setInterval(setupImages, 800) just re-scanned all
// images forever after onload was already attached, keeping the WebView busy.
// Watch for genuine DOM changes instead (e.g. dynamically inserted images) and
// drop the permanent 800ms wake-up.
if (window.MutationObserver) {
  var imgObserver = new MutationObserver(function() { setupImages(); });
  imgObserver.observe(document.body, { childList: true, subtree: true });
}`;

  static fill(style: string, baseHref: string, body: string): string {
    let result: string = WebViewHtml.HTML;
    result = result.replace('%s', style);
    result = result.replace('%s', baseHref);
    result = result.replace('%s', body);
    result = result.replace('%s', WebViewHtml.SCRIPT);
    return result;
  }
}
