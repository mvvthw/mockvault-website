(function () {
  "use strict";

  var SUPABASE_URL = "https://mbdftnypfdhvdgdgkhjc.supabase.co";
  var SUPABASE_KEY = "sb_publishable_it_Px7Rhk4DHtNJ3_qYpNA_YvFMpXLP";
  var RPC_URL      = SUPABASE_URL + "/rest/v1/rpc/track_event";

  if (navigator.doNotTrack === "1" || window.doNotTrack === "1") return;

  function readAuthToken() {
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (k && k.indexOf("sb-") === 0 && k.indexOf("-auth-token") === k.length - 11) {
          var raw = localStorage.getItem(k);
          if (!raw) continue;
          var parsed = JSON.parse(raw);
          if (parsed && parsed.access_token) return parsed.access_token;
        }
      }
    } catch (e) {}
    return null;
  }

  function track(eventName, props) {
    if (!eventName) return;
    var token = readAuthToken();
    var body = JSON.stringify({
      p_event_name: eventName,
      p_path:       location.pathname || "/",
      p_referrer:   document.referrer || null,
      p_props:      props || null
    });
    try {
      fetch(RPC_URL, {
        method: "POST",
        headers: {
          "Content-Type":  "application/json",
          "apikey":        SUPABASE_KEY,
          "Authorization": "Bearer " + (token || SUPABASE_KEY)
        },
        body: body,
        keepalive: true,
        credentials: "omit",
        mode: "cors"
      }).catch(function () {});
    } catch (e) {}
  }

  // Public API.
  window.mv = window.mv || {};
  window.mv.track = track;

  // Auto-track external CTA clicks (Stripe / Gumroad).
  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest && e.target.closest("a[href]");
    if (!a) return;
    var href = a.getAttribute("href") || "";
    if (
      href.indexOf("buy.stripe.com")   !== -1 ||
      href.indexOf("checkout.stripe")  !== -1 ||
      href.indexOf("gumroad.com")      !== -1
    ) {
      track("cta_click", { href: href, label: (a.textContent || "").trim().slice(0, 80) });
    }
  }, true);

  function firePageview() {
    track("pageview");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", firePageview, { once: true });
  } else {
    firePageview();
  }
})();
