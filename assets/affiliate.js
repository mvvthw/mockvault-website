// Affiliate attribution: capture ?ref=CODE, persist in cookie + localStorage,
// fire one click ping per browser session, and append client_reference_id to
// every Stripe checkout link so the webhook can attribute the sale.
(function () {
  "use strict";

  var SUPABASE_URL = "https://mbdftnypfdhvdgdgkhjc.supabase.co";
  var SUPABASE_KEY = "sb_publishable_it_Px7Rhk4DHtNJ3_qYpNA_YvFMpXLP";
  var RPC_URL      = SUPABASE_URL + "/rest/v1/rpc/track_affiliate_click";

  var COOKIE_NAME    = "mv_ref";
  var COOKIE_MAX_AGE = 60 * 24 * 60 * 60; // 60 days
  var STORAGE_KEY    = "mv_ref";
  var SESSION_PINGED = "mv_ref_pinged";
  var STRIPE_HOST    = "buy.stripe.com";

  function readQueryParam(name) {
    try {
      var params = new URLSearchParams(window.location.search);
      var v = params.get(name);
      return v ? v.trim() : null;
    } catch (e) { return null; }
  }

  function normalize(code) {
    if (!code) return null;
    var c = String(code).trim().toUpperCase();
    // Match the SQL alphabet (A-Z minus I/L/O/U + 2-9). Anything else = ignore.
    if (!/^[A-HJ-KMNP-TV-Z2-9]{4,16}$/.test(c)) return null;
    return c;
  }

  function setCookie(value) {
    try {
      document.cookie =
        COOKIE_NAME + "=" + encodeURIComponent(value) +
        "; max-age=" + COOKIE_MAX_AGE +
        "; path=/; SameSite=Lax" +
        (location.protocol === "https:" ? "; Secure" : "");
    } catch (e) {}
  }

  function readCookie() {
    try {
      var match = document.cookie.match(new RegExp("(?:^|; )" + COOKIE_NAME + "=([^;]*)"));
      return match ? decodeURIComponent(match[1]) : null;
    } catch (e) { return null; }
  }

  function readStored() {
    try { return localStorage.getItem(STORAGE_KEY); }
    catch (e) { return null; }
  }

  function persist(code) {
    setCookie(code);
    try { localStorage.setItem(STORAGE_KEY, code); } catch (e) {}
  }

  function getCode() {
    return normalize(readCookie() || readStored());
  }

  function pingClickOnce(code) {
    if (!code) return;
    try {
      if (sessionStorage.getItem(SESSION_PINGED) === code) return;
      sessionStorage.setItem(SESSION_PINGED, code);
    } catch (e) {}

    try {
      fetch(RPC_URL, {
        method: "POST",
        headers: {
          "Content-Type":  "application/json",
          "apikey":        SUPABASE_KEY,
          "Authorization": "Bearer " + SUPABASE_KEY
        },
        body: JSON.stringify({
          p_code: code,
          p_path: location.pathname || "/"
        }),
        keepalive: true,
        credentials: "omit",
        mode: "cors"
      }).catch(function () {});
    } catch (e) {}
  }

  function decorateStripeUrl(href, code) {
    try {
      var url = new URL(href, location.href);
      if (url.host !== STRIPE_HOST) return href;
      url.searchParams.set("client_reference_id", code);
      return url.toString();
    } catch (e) {
      return href;
    }
  }

  function decorateAllStripeLinks(code) {
    if (!code) return;
    var anchors = document.querySelectorAll('a[href*="' + STRIPE_HOST + '"]');
    for (var i = 0; i < anchors.length; i++) {
      var a = anchors[i];
      var orig = a.getAttribute("href");
      if (!orig) continue;
      var next = decorateStripeUrl(orig, code);
      if (next !== orig) a.setAttribute("href", next);
    }
  }

  // Intercept clicks too — covers links added/mutated after page load and
  // anything our static rewrite might have missed (e.g. images/inline JS).
  function attachClickRewriter() {
    document.addEventListener("click", function (e) {
      var code = getCode();
      if (!code) return;
      var a = e.target && e.target.closest && e.target.closest('a[href*="' + STRIPE_HOST + '"]');
      if (!a) return;
      var orig = a.getAttribute("href");
      if (!orig) return;
      var next = decorateStripeUrl(orig, code);
      if (next !== orig) a.setAttribute("href", next);
    }, true);
  }

  function init() {
    var fromQuery = normalize(readQueryParam("ref"));
    if (fromQuery) persist(fromQuery);

    var code = getCode();
    pingClickOnce(code);
    decorateAllStripeLinks(code);
    attachClickRewriter();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }

  // Tiny public API for the account page to re-use the same code source.
  window.mv = window.mv || {};
  window.mv.getAffiliateCode = getCode;
})();
