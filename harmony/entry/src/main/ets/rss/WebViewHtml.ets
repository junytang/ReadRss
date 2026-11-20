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
  static readonly SCRIPT: string = `function collapseEmptyParagraphs() {
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
setInterval(setupImages, 800);`;

  static fill(style: string, baseHref: string, body: string): string {
    let result: string = WebViewHtml.HTML;
    result = result.replace('%s', style);
    result = result.replace('%s', baseHref);
    result = result.replace('%s', body);
    result = result.replace('%s', WebViewHtml.SCRIPT);
    return result;
  }
}
