# Padding & Navigation Fix

This document explains why the **Next/Prev buttons appeared broken** in the EPUB
reader (`html_code/index.html`) and how the issue was fixed by simplifying the
reader code, and documents the **native percentage margin** that was added
afterwards to keep the text away from the edges of the reading area — without
re-introducing the fragility.

---

## Background

`html_code/index.html` is the reader/editor UI loaded by the Nim host through a
WebView2 (via the virtual host `https://appassets/index.html`). Rendering is
handled by the bundled **epub.js** build (`html_code/epub.js`), which paginates
chapters using CSS multi-columns inside per-chapter iframes.

A previous commit added a "Pad %" toolbar field that applied a *custom
percentage padding* to the currently displayed chapter.

## The problem

The Next button (and sometimes Prev) stopped working reliably: clicking it
appeared to do nothing.

**Root cause:** the custom padding feature fought epub.js's own pagination
engine:

1. It overrode `padding`, `column-width` and `column-gap` on the iframe `<body>`
   with inline `!important` styles.
2. A `MutationObserver` (`watchChapterPadding`) re-applied those values every
   time epub.js rewrote them (epub.js re-formats on every resize/render).
3. A helper (`resizeIframesToContent`) manually widened the iframes so the
   extra-wide content wouldn't be clipped.

The problem is that epub.js *itself* observes size changes: `Contents`
attaches a `ResizeObserver` to the iframe `documentElement` and, on any change,
re-checks its size and re-formats the document (`Contents.RESIZE` →
`Layout.format`). So every manual override triggered epub.js to re-layout and
reset the scroll position **right after** `next()`/`prev()` had scrolled — the
page appeared frozen. In spread mode the large padding could also push content
past the fixed-width iframe, clipping whole pages.

In short: two layout systems (epub.js + the custom hack) fought over the same
CSS properties, and epub.js always won by re-rendering.

## The fix

The reader was simplified so that **epub.js alone owns the layout**:

- **Removed** the entire custom padding system:
  - `applyChapterPadding()`, `watchChapterPadding()`, the `padObservers`
    `WeakMap` and the `MutationObserver` loop
  - `resizeIframesToContent()` (manual iframe widening)
  - the "Pad %" toolbar input, its CSS and its change handler
- **Removed** ~170 lines of ad-hoc DEBUG instrumentation (`dbg`,
  `dbgLayoutInfo`, `dbgState`, `dbgVisibleParas`, `dbgColumns`, ...).
- **Simplified navigation**: the two bespoke click handlers were replaced by a
  single `navigate(dir)` helper that simply calls
  `rendition.prev()` / `rendition.next()` — epub.js already handles in-chapter
  column scrolling and chapter transitions natively.

### Robustness improvements added along the way

- **Book-boundary button state:** Prev/Next now disable automatically at the
  start/end of the book, using `location.atStart` / `location.atEnd` (verified
  to exist in the bundled epub.js build). A disabled Next at the end of a book
  no longer looks like a broken button.
- **Error feedback:** navigation promise rejection is surfaced in the status
  bar via `.catch()` instead of failing silently.
- **Double-click guard:** a 200 ms debounce avoids accidentally skipping two
  pages on a fast double-click.
- **Clean book switches:** the in-context editor popover is closed when opening
  another book.

## Verification

- The extracted script passes `node --check` (syntax-valid).
- The diff against a backup of the previous version was reviewed: only the
  intended removals/simplifications; every preserved feature (Nim bridge,
  library sidebar, package file browser, view/edit tabs, HTML editor, save,
  in-context paragraph editing) is byte-identical.
- `index.html` is loaded at runtime by the WebView (it is not compiled into the
  `.exe`), so no rebuild is required — just restart the app.

## Solution adopted: percentage margin on `.epub-container`

To keep a comfortable margin between the text and the edge of the reading
area, the margin is applied **on epub.js's own container element** — the
`.epub-container` div that epub.js creates inside `#viewer` — not on the iframe
bodies.

`html_code/index.html`:

```css
.epub-container {
  touch-action: none;
  box-sizing: border-box;   /* essential: the container is width/height 100% */
  padding: 3% 3%;           /* margin around the pages (current default) */
}
```

Why this is safe (verified in the bundled epub.js build):

- epub.js's `DOMElement.size()` reads the computed padding of `.epub-container`
  and **subtracts it from the measured stage size** before `Layout.calculate()`
  runs (epub.js:3783-3811). `columnWidth`, `gap` and `delta` are therefore
  derived from the *reduced* area, so the page-step math stays exact — this
  padding hook is a first-class part of epub.js's design.
- `box-sizing: border-box` is required because the container is created with
  `width: 100%` / `height: 100%` (`renderTo("viewer", { width: "100%",
  height: "100%" })`). Without it the padding would inflate the container past
  the viewer and `#viewer { overflow: hidden }` would clip the right side.
- The pages (flex items inside the container, which epub.js lays out
  horizontally) are placed inside the content box, so the whole reading area is
  inset from the viewer edges.
- The iframe-body padding that epub.js applies itself (20px top/bottom,
  `gap/2` left/right, epub.js:6669-6672) is untouched — no `!important`, no
  MutationObserver, no manual iframe resizing, so there is no feedback loop
  with epub.js's `ResizeObserver`.
- On window resize / `widthSelect` change, the app already calls
  `rendition.resize()`, which re-reads the stage size (epub.js:4956) — the
  percentage margin scales automatically.

Percentages are relative to the container's *width* (CSS spec), so the margin
scales with the window. On the default 900px viewer, 3% ≈ 27px per side. The
horizontal value was reduced from 7% to **3%** during testing (a wide
horizontal inset made column re-pagination feel off); `3% 3%` is the current
default — tune the two numbers to taste.

## Reader zoom: browser zoom on the reading area only

A real **browser zoom** (WebView2 `ZoomFactor`) is applied to the whole page,
and the fixed chrome (toolbar, tabs, status bar, sidebars, HTML editor panel)
is counter-zoomed back with CSS `zoom: 1/Z` so it stays visually unchanged.
`#viewer` stays at CSS zoom 1, so epub.js measures
(`clientWidth`/`offsetWidth`, `getBoundingClientRect`) in CSS pixels that are
consistent with the zoom — the geometry lesson from the padding incident is
not violated (no body padding/columns overrides, no manual iframe resizing).

### How it works

- Toolbar buttons `A−`, `A+` and the percentage (click = reset to 100%) call
  the Nim bridge (`api.setZoom`).
- `epub_app.nim` clamps the factor (0.75–2.0) and calls the new
  `mio_setZoomFactor` proc in **`webview2_nim`** (`miowebview2.nim`), which
  sets `ICoreWebView2Controller::put_ZoomFactor`. Note: `webview2_nim` lives
  outside this repository (`nim.cfg` points to it); the change there is
  additive.
- On the callback the frontend sets two CSS variables on `:root`:
  - `--app-zoom` — the factor (e.g. `1.25`);
  - `--chrome-zoom` — `1 / Z` (e.g. `0.8`).

  `#toolbar, #tabs, #status, #editorPanel, #sidebar, #librarySidebar` use
  `zoom: var(--chrome-zoom)`. `#viewer` and `#inlineEditor` are **excluded**:
  the popover positions itself with the reading-content rects, which are
  already zoom-consistent.
- After one animation frame (so the CSS-px measurements are updated) the app
  calls `rendition.resize()` — the same native path used on window resize and
  `widthSelect` — so epub.js re-paginates for the new CSS-px stage size.
  Result: true browser-zoom behavior (text, images and layout scale; the text
  reflows into more/fewer pages), while the chrome keeps its size.

### Notes

- Range 75%–200%, step 25%; the value is kept for the session only.
- The `.epub-container` percentage margins stay **visually constant** under
  zoom: they resolve against the CSS-px stage, which shrinks as the zoom grows.
- The zoom is a WebView2-level setting (whole page), but the counter-zoom makes
  the UI chrome look unchanged.
- Requires a rebuild (`compila.bat`) because the bridge and the
  `miowebview2.nim` proc are compiled into `epub_app.exe`.

## Alternatives not adopted

The solution above is the simplest native option. If the margin ever needs to
live *inside* each page (a per-page gutter rather than around the whole reading
area), the remaining options are:

1. **`rendition.themes`** — inject a user stylesheet that epub.js applies on
   every render. Caveat: epub.js writes the layout paddings as *inline*
   `!important` styles, which beat stylesheet rules, so body padding can still
   conflict. Themes are a good fit for content styling, not for layout geometry.
2. **Patch `Layout.calculate` / `Contents.columns`** — the only approach where a
   custom padding can remain pixel-exact with pagination: recompute `delta`,
   `column-width`, `column-gap` and padding coherently, so the column step stays
   aligned with epub.js's scroll math (`delta`), and let epub.js size the
   iframes itself (never touch them manually).
3. **Use built-in spacing instead** — rely on the `spread` gap and
   `minSpreadWidth` settings for visual separation rather than body padding.

Whatever the approach, the two golden rules from this incident are:

- **Never** mutate `padding`/`column-*` on the iframe body behind epub.js's back.
- **Never** resize iframes manually — epub.js's internal observers will fight
  back.
