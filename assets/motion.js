/* ══════════════════════════════════════════════════════════════
   ContractIQ — motion behaviour
   ──────────────────────────────────────────────────────────────
   No dependencies, no build step: this has to work as a static
   file on shared hosting or GitHub Pages.

   Everything is progressive. If this script fails to load or is
   blocked (a locked-down corporate browser, for instance) the
   site is fully readable — reveal elements are un-hidden by the
   no-js fallback at the bottom.
   ══════════════════════════════════════════════════════════════ */
(function () {
  "use strict";

  var reduce = window.matchMedia &&
               window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ── 1 · Mark reveal targets ───────────────────────────────
     Done in JS so the markup stays clean and any page picks the
     behaviour up automatically.                                 */
  function tagReveals() {
    var groups = [
      { sel: ".sec-head", cls: "reveal" },
      { sel: ".hcard", cls: "reveal reveal-pop", stagger: true },
      { sel: ".feat", cls: "reveal reveal-pop", stagger: true },
      { sel: ".plan", cls: "reveal reveal-pop", stagger: true },
      { sel: ".ed", cls: "reveal reveal-pop", stagger: true },
      { sel: ".stat", cls: "reveal", stagger: true },
      { sel: ".prose h2", cls: "reveal" },
      { sel: ".foot-col", cls: "reveal", stagger: true }
    ];
    groups.forEach(function (g) {
      var nodes = document.querySelectorAll(g.sel);
      // Stagger resets per parent so a second grid doesn't inherit
      // a huge delay from the first.
      var counters = new Map();
      Array.prototype.forEach.call(nodes, function (el) {
        if (el.closest(".nav")) return;              // never animate the nav
        g.cls.split(" ").forEach(function (c) { el.classList.add(c); });
        if (g.stagger) {
          var p = el.parentElement;
          var n = counters.get(p) || 0;
          el.style.setProperty("--i", Math.min(n, 8));
          counters.set(p, n + 1);
        }
      });
    });
  }

  /* ── 2 · Reveal on scroll ─────────────────────────────────── */
  function observeReveals() {
    var targets = document.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window)) {
      Array.prototype.forEach.call(targets, function (el) { el.classList.add("is-in"); });
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        e.target.classList.add("is-in");
        io.unobserve(e.target);            // reveal once, then stop watching
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.06 });
    Array.prototype.forEach.call(targets, function (el) { io.observe(el); });
  }

  /* ── 3 · Floating hexagons in the hero ─────────────────────
     The hexagon is the brand mark, so the ambient shapes are
     hexagons. Sizes and positions are fixed per index rather
     than random, so the composition is deliberate and identical
     on every load.                                              */
  var HEXES = [
    { top: "14%", left: "6%",  size: 118, dur: "19s", delay: "0s",   rise: "-30px", spin: "9deg",  op: .5 },
    { top: "58%", left: "13%", size: 74,  dur: "23s", delay: "-4s",  rise: "24px",  spin: "-7deg", op: .38 },
    { top: "22%", left: "82%", size: 152, dur: "26s", delay: "-9s",  rise: "-22px", spin: "-6deg", op: .42 },
    { top: "66%", left: "74%", size: 92,  dur: "21s", delay: "-2s",  rise: "28px",  spin: "10deg", op: .34 },
    { top: "40%", left: "45%", size: 62,  dur: "17s", delay: "-6s",  rise: "-18px", spin: "12deg", op: .22 },
    { top: "78%", left: "36%", size: 108, dur: "29s", delay: "-12s", rise: "-26px", spin: "-9deg", op: .26 }
  ];

  function addFloaters() {
    var heroes = document.querySelectorAll(".hero, .page-hero");
    Array.prototype.forEach.call(heroes, function (hero) {
      if (hero.querySelector(".ciq-float")) return;
      var wrap = document.createElement("div");
      wrap.className = "ciq-float";
      wrap.setAttribute("aria-hidden", "true");
      HEXES.forEach(function (h) {
        var el = document.createElement("span");
        el.className = "ciq-hex";
        el.style.cssText =
          "top:" + h.top + ";left:" + h.left + ";width:" + h.size + "px;height:" +
          Math.round(h.size * 1.09) + "px;opacity:" + h.op + ";";
        el.style.setProperty("--dur", h.dur);
        el.style.setProperty("--delay", h.delay);
        el.style.setProperty("--rise", h.rise);
        el.style.setProperty("--spin", h.spin);
        wrap.appendChild(el);
      });
      hero.insertBefore(wrap, hero.firstChild);
    });
  }

  /* ── 4 · Pointer parallax on the hero hexagons ─────────────
     rAF-throttled and translate-only. Skipped on touch, where
     there is no hover pointer to track and it would just cost
     battery.                                                    */
  function heroParallax() {
    if (!window.matchMedia("(hover: hover) and (pointer: fine)").matches) return;
    var hero = document.querySelector(".hero, .page-hero");
    if (!hero) return;
    var hexes = hero.querySelectorAll(".ciq-hex");
    if (!hexes.length) return;
    var tx = 0, ty = 0, queued = false;

    hero.addEventListener("pointermove", function (e) {
      var r = hero.getBoundingClientRect();
      tx = (e.clientX - r.left) / r.width - 0.5;
      ty = (e.clientY - r.top) / r.height - 0.5;
      if (queued) return;
      queued = true;
      requestAnimationFrame(function () {
        Array.prototype.forEach.call(hexes, function (el, i) {
          var depth = 6 + (i % 3) * 7;               // layered depth
          el.style.translate = (tx * depth).toFixed(2) + "px " +
                               (ty * depth).toFixed(2) + "px";
        });
        queued = false;
      });
    }, { passive: true });

    hero.addEventListener("pointerleave", function () {
      Array.prototype.forEach.call(hexes, function (el) { el.style.translate = "0px 0px"; });
    }, { passive: true });
  }

  /* ── 5 · Sticky nav state + scroll progress ────────────────── */
  function scrollChrome() {
    var nav = document.querySelector(".nav");
    var bar = document.createElement("div");
    bar.id = "ciq-progress";
    document.body.appendChild(bar);
    var queued = false;

    function paint() {
      var y = window.scrollY || document.documentElement.scrollTop;
      if (nav) nav.classList.toggle("is-stuck", y > 24);
      var h = document.documentElement.scrollHeight - window.innerHeight;
      bar.style.width = (h > 0 ? Math.min(100, (y / h) * 100) : 0) + "%";
      queued = false;
    }
    window.addEventListener("scroll", function () {
      if (queued) return;
      queued = true;
      requestAnimationFrame(paint);
    }, { passive: true });
    paint();
  }

  /* ── 6 · Count-up for figures ──────────────────────────────
     Only touches elements explicitly marked data-count, so it
     can never mangle body copy or a price.                       */
  function countUps() {
    var els = document.querySelectorAll("[data-count]");
    if (!els.length || !("IntersectionObserver" in window)) return;
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        var el = e.target;
        io.unobserve(el);
        var target = parseFloat(el.getAttribute("data-count"));
        var prefix = el.getAttribute("data-prefix") || "";
        var suffix = el.getAttribute("data-suffix") || "";
        var dp = parseInt(el.getAttribute("data-dp") || "0", 10);
        var dur = 1250, t0 = performance.now();
        el.classList.add("ciq-num");
        (function step(now) {
          var p = Math.min(1, (now - t0) / dur);
          var eased = 1 - Math.pow(1 - p, 3);       // ease-out cubic
          var v = target * eased;
          el.textContent = prefix +
            v.toLocaleString("en-GB", { minimumFractionDigits: dp, maximumFractionDigits: dp }) +
            suffix;
          if (p < 1) requestAnimationFrame(step);
        })(t0);
      });
    }, { threshold: 0.4 });
    Array.prototype.forEach.call(els, function (el) { io.observe(el); });
  }

  /* ── 7 · Soft page exit ───────────────────────────────────
     Only for same-origin .html links, and only where the browser
     lacks View Transitions (otherwise we'd double up). Modifier
     clicks and new-tab intent are left alone.                    */
  function pageExit() {
    if (document.startViewTransition) return;        // browser handles it
    document.addEventListener("click", function (e) {
      var a = e.target.closest && e.target.closest("a");
      if (!a) return;
      var href = a.getAttribute("href") || "";
      if (!/\.html($|[?#])/.test(href)) return;
      if (a.target === "_blank" || a.hasAttribute("download")) return;
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
      e.preventDefault();
      document.body.classList.add("ciq-leaving");
      setTimeout(function () { window.location.href = href; }, 190);
    });
  }

  /* ── boot ─────────────────────────────────────────────────── */
  function init() {
    document.documentElement.classList.add("ciq-motion");
    if (reduce) {
      // Nothing animates, but content must still be visible.
      tagReveals();
      document.querySelectorAll(".reveal").forEach(function (el) { el.classList.add("is-in"); });
      return;
    }
    tagReveals();
    addFloaters();
    observeReveals();
    heroParallax();
    scrollChrome();
    countUps();
    pageExit();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
