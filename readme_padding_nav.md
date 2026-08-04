# Padding & Navigation Fix

This document explains why the **Next/Prev buttons appeared broken** in the EPUB
reader (`html_code/index.html`) and how the issue was fixed by simplifying the
reader code. It also sketches how a *native* percentage-padding feature could be
added cleanly in the future, without re-introducing the fragility.

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

## Future: native percentage padding

If percentage padding is ever re-introduced, it should be done **natively**,
without fighting epub.js. Options, from simplest to most invasive:

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
