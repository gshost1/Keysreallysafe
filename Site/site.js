// keysrs.com's own script: no network, no storage beyond the opt-out flag below.
// Loaded without defer so the platform is known before first paint and a
// Windows visitor never sees the Mac install box flash.

// Mac, or something that can't run Keysrs. iPadOS asks for the desktop site
// and says Macintosh, so touch points tell an iPad from a Mac. Anything we
// can't place stays "other" and gets the Mac page, the same as with no JS.
var platform = (function () {
  var ua = navigator.userAgent || "";
  if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "ios";
  if (/Android/.test(ua)) return "android";
  if (/Macintosh|Mac OS X/.test(ua)) return "mac";
  if (/Windows/.test(ua)) return "windows";
  if (/Linux|CrOS|X11/.test(ua)) return "linux";
  return "other";
})();
document.documentElement.setAttribute("data-platform", platform);

// Our own visits: open the site once with ?internal=1 and posthog.js stops
// loading in that browser; ?internal=0 undoes it.
(function () {
  var v = new URLSearchParams(location.search).get("internal");
  try {
    if (v === "1") localStorage.setItem("keysrs-internal", "1");
    else if (v === "0") localStorage.removeItem("keysrs-internal");
  } catch (e) {}
})();

document.addEventListener("click", function (e) {
  var b = e.target.closest("[data-copy]"); if (!b) return;
  var el = document.getElementById(b.getAttribute("data-copy")); if (!el) return;
  var text = el.textContent;
  function done(label) { b.textContent = label; setTimeout(function () { b.textContent = "Copy"; }, 1600); }
  // Without the clipboard API (old browsers, insecure origins) select the
  // text so one more keystroke copies it.
  function select() {
    var r = document.createRange(); r.selectNodeContents(el);
    var s = getSelection(); s.removeAllRanges(); s.addRange(r);
    done("Press ⌘C");
  }
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { done("Copied"); }, select);
  else select();
});
