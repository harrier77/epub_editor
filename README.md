# EPUB Editor (Nim + WebView2)

Standalone EPUB editor and reader for Windows, built with Nim and WebView2.
Same features as the Flask/Python version (`epub.js/reader`), with the Nim
backend managing files directly on disk (no HTTP server).

## Build

```bash
nim c -d:release epub_app.nim
```

## Features

### Content zoom (A+ / A- / 100%)

The **A+**, **A-** and **100%** buttons zoom the EPUB reading content in
and out without affecting the browser chrome (toolbar, tabs, sidebars) or
overflowing the viewport.

#### Current strategy — CSS zoom on `#viewer`

```css
#viewer {
  flex: 1;
  overflow: auto;
  zoom: var(--app-zoom, 1);
}
```

CSS `zoom` is applied **only** to the `#viewer` element. Because `#viewer`
is a flex child with `flex:1`, its layout box is determined by the flex
algorithm and **does not change** when CSS `zoom` is applied to it —
`zoom` only affects visual rendering, not layout metrics
(`clientWidth`/`offsetWidth`). The other elements (toolbar, sidebar, tabs)
receive no counter-zoom: they remain visually unchanged by construction.

epub.js measures the container via `clientWidth`/`offsetWidth`, which
return CSS-pixel dimensions **before** the element's own CSS `zoom` is
applied, so column pagination remains correct at every zoom level. When
zoomed content extends beyond the viewer box, `overflow: auto` allows
scrolling.

No WebView2 `setZoom` call is needed.

#### Previous strategy — WebView2 zoom + counter-zoom

The original implementation used WebView2's native zoom
(`window.chrome.webview.postMessage` → `setZoom`), which zooms the
**entire page** (equivalent to CSS `zoom` on `:root`). To keep the
browser chrome unchanged, a counter-zoom (`zoom: 1/Z`) was applied to
every fixed element (toolbar, tabs, sidebar, editor panel):

```css
:root {
  --chrome-zoom: 1;
}
#toolbar, #tabs, #status, #editorPanel,
#sidebar, #librarySidebar, #metaEditor, #buildReport {
  zoom: var(--chrome-zoom);
}
```

```javascript
// WebView2 zooms THE ENTIRE PAGE
api.setZoom({ factor: z }).then(() => rendition.resize());
```

**It worked just as well**: the CSS counter-zoom on chrome elements kept
them visually unchanged, epub.js adapted correctly with
`rendition.resize()`, and column pagination remained coherent.

The only practical difference was that `body { height: 100dvh }` was also
zoomed, causing the body's CSS-pixel height to grow proportionally to the
zoom factor — a minor vertical overflow, mitigated by `overflow: hidden`
on the body. With the current strategy (CSS zoom on `#viewer`), the body
is not zoomed and the issue does not arise.

The WebView2 strategy was removed because it required an asynchronous IPC
call to the backend (`api.setZoom`) and a frame wait before
`rendition.resize()`. The CSS version is synchronous, does not depend on
the backend, and replicates exactly the solution validated in the
Flask/Python version.

#### Flask/Python variant (epub.js/reader)

The Flask version went through the same evolution: initial zoom on `:root`
with counter-zoom, then migration to CSS zoom on `#viewer`. The Flask
README describes the problem in detail:

> The original implementation applied CSS `zoom` to `documentElement`
> (`:root`), which scaled the **entire page** including `<body>` (whose
> `height:100dvh` also scaled), forcing the viewer to grow beyond the
> screen. [...] The fix moves the CSS `zoom` from `:root` to the
> `#viewer` element only.

The Nim version adopts the same solution.

---

### Single page / two-page spread

The **Single page / Two pages** button switches at runtime between
`rendition.spread("none")` and `rendition.spread("auto")`.

### Container max width

The **Max page width** selector sets the reading area's max width as a
percentage of the screen (30%–100%).

### EPUB package browser (Sigil-style)

The **📂** button opens a sidebar listing all files in the EPUB, grouped
by type. Spine documents are clickable and navigate the reader.

### Chapter HTML editor

Two tabs, **📖 Read** and **✏️ Edit HTML**, switch between the paginated
viewer and a code editor showing the current chapter's XHTML source.

- **💾 Save** rewrites the entry in the `.epub` file (or in the folder
  for folder books) and re-renders the chapter without reloading the book.

### In-context editing

Clicking a paragraph in the viewer prepares a floating popover with the
selected block's HTML. The edit is saved directly to the file and the
viewer updates to the modified paragraph (via CFI).

### Reading theme

The **Yellow** and **Black** buttons change the reading text background
without affecting the chrome. The theme is injected via an epub.js
content hook and persists across chapter changes.

### Chapter reload

The **⟳ Reload** button (folder books only) re-reads the current chapter
from disk, useful for seeing translations saved by the translator without
reopening the book.

### OPF metadata editor

The **⚙ Metadata** button (folder books only) opens a modal with the
OPF XML for editing title, language, and other metadata.

### EPUB build

The **📦 Build EPUB** button assembles a well-formatted EPUB from the
translated folder (STORED mimetype, German fallback for untranslated
chapters, dc:language → it).

### Navigation

- **‹ Previous / Next ›** buttons
- **← / →** keyboard arrows
- Horizontal swipe on touch

## Structure

```
epub_app.nim        Nim backend: file management, WebView2 ⟷ JS bridge
html_code/
  index.html        UI (toolbar, viewer, tabs, editor, sidebar)
  epub.js           epub.js library
  jszip.min.js      epub.js dependency (loaded BEFORE epub.js)
  style.css         (optional, any external styles)
```
