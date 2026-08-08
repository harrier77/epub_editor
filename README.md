# Standalone EPUB reader (Nim + WebView2)

**Serverless** desktop application that displays `.epub` files in a WebView2
window, reusing the same `epub.js` library from the original Flask project
(`\epub.js\reader`).

The interface (HTML/CSS/JS) is the same as the Flask one, only duplicated and
adapted for the Nim bridge. No HTTP: the `html_code/` folder is served by
WebView2 through a **virtual host** (`https://appassets/`).

---

## Project structure

```
epub_editor/
├── epub_app.nim      # Nim application (entry point)
├── epub_app.exe      # already compiled executable
├── compila.bat       # build script
├── nim.cfg           # Nim configuration (path to webview2_nim)
├── README.md         # this file
├── plan.md           # original project document
└── html_code/        # frontend + books (served via virtual host)
    ├── index.html    # reader interface (with Nim↔JS bridge)
    ├── epub.js       # EPUB reading library
    ├── jszip.min.js  # epub.js dependency (browser-side unzip)
    └── book.epub     # example book (put your .epub files here)
```

---

## How it works

The flow is the same as Flask, but without a server:

1. **Startup** – Nim scans the `html_code/` folder looking for `.epub` files.
2. **Titles** – for each book Nim opens the ZIP with **zippy**, reads
   `META-INF/container.xml` to find the OPF path, then extracts `<dc:title>`
   (equivalent of the `epub_title()` function in `app.py`).
3. **Virtual hosts** – `mio_registerVirtualHost` maps:
   - `https://appassets/` → the `html_code/` folder (frontend + `.epub` books);
   - `https://ext/` → the **unpacked EPUB folder** (translator output,
     `META-INF/` + `OEBPS/`), served from disk on every request.
4. **Navigation** – the window loads `https://appassets/index.html`.
5. **Library** – `index.html` calls the bridge `api.listBooks()` → Nim replies
   with `[{name, title, url, size, type?}, ...]`. The unpacked EPUB folder
   appears **first**, as a `type: "folder"` book (`url: "https://ext/"`).
6. **Reading** – `epub.js` opens the book via `https://appassets/<name>.epub`
   and **unzips it by itself** with JSZip; the folder book is opened in
   **directory mode** (URL ends with `/`), same as `/ext/` in Flask.

### Unpacked EPUB folder (translator output)

Aligned with `app.py`'s `--book-dir` mode: `FOLDER_BOOK_DIR`
(`..\translator\target`) is served on
`https://ext/` and appears as the first book in the Library. Because files are
read from disk on every request (the frontend adds a `t=` cache-buster), the
translations saved by the translator are visible immediately, without
rebuilding the EPUB. The **⟳ Ricarica** button re-reads the current chapter
from disk; the **HTML editor** and the in-context popover save directly into
the folder file (`saveChapter` → `saveChapterIntoFolder`, case-insensitive
match + atomic `.tmp`/move, same as Flask). Chapters rendered from the folder
are rewritten client-side to a single CSS bundle (equivalent of
`css_bundle`/`rewrite_xhtml_css_links` in `app.py`).

### JS ↔ Nim bridge

`index.html` exposes `window.api.listBooks(arg)` which posts a message to Nim:

```json
{ "scope": "epub", "name": "listBooks", "args": "null", "callbackId": 1 }
```

Nim handles it in `handleBridge` and replies by invoking
`window._nimCallbacks[1](<json>)`. The message arrives via
`window.chrome.webview.postMessage` (injected by WebView2/miowv).

---

## Build

Required dependencies:

- **Nim** (tested with 2.0.8)
- **winim** (only external package for COM/Win32)
- **zippy** (unzip, for book titles)
- **webview2_nim** module (already present in `C:\Users\pr30565\Nim_code\webview2_nim`)
- **WebView2 Runtime** (included in Windows 11)

Build (double-click `compila.bat`, or):

```bat
nim --app:gui -d:release --opt:size c ^
  --passL:-static-libgcc ^
  --passL:-static-libstdc++ ^
  --passL:-Wl,-Bstatic ^
  --passL:-lwinpthread ^
  --passL:-Wl,-Bdynamic ^
  epub_app.nim
```

Or more simply:

```
nim c --app:gui -d:release --opt:size epub_app.nim
```

`nim.cfg` already contains the `path` to `webview2_nim`, so `import miowv`
is resolved automatically.

> Note: `webview2_nim` exists in two paths (`Nim_code/webview2_nim` and
> `Nim_code/nim/webview2_nim`) but they are **the same** content (junction), so
> a change applies to both.

---

## Adding a book

Simply copy the `.epub` file into the `html_code/` folder and restart the app.
The book will appear in the **Library** menu (📚). The shown title is the one
read from the OPF metadata; if it cannot be read, the file name is used.

---

## Code maintenance

### `epub_app.nim`
- **`listEpubBooks(dir, folderDir)`** – scans the folder and returns the books
  as JSON (first the unpacked folder book, then the `.epub` files). Edit here
  if you want to change the folder, sorting, or the fields returned to the
  frontend.
- **`epubTitle(path)`** – extracts the title from the OPF of a `.epub`.
- **`folderTitle(root)` / `folderSize(root)`** – title (from `container.xml`
  + OPF) and total size of an unpacked folder book (as in `app.py`).
- **`resolveInDir(root, href)`** – real path of `href` under `root` with
  case-insensitive match and path-traversal protection.
- **`saveChapterIntoEpub` / `saveChapterIntoFolder`** – persist a modified
  chapter into a `.epub` (zippy rewrite) or into the unpacked folder file.
- **`handleBridge`** – handles commands from JS (`listBooks`, `saveChapter`,
  `setZoom`). The `saveChapter` re-render is **client-side** (as in Flask), no
  MessageBox.

### `html_code/index.html`
- It is the **same** as the Flask app (`reader/static/index.html`), adapted to
  the Nim bridge (`api.listBooks`/`api.saveChapter`/`api.setZoom`) and with
  the browser **zoom** buttons (WebView2) added. All the Python features are
  reused: folder book (`isFolderBook`, `normalizeExtPath`, archive shim),
  client-side CSS bundle, ⟳ Ricarica, swipe navigation, draggable in-context
  editor, client-side re-render after save.
- If you modify the frontend, refer to `reader/static/` for the original.

### `webview2_nim` module
Two things were added/fixed (needed to serve files from disk):
- `platforms/win/webview2/com/icorewebview2.nim`: corrected COM signature of
  `SetVirtualHostNameToFolderMapping` (it was a placeholder without parameters).
- `platforms/win/miowebview2.nim`: new proc `mio_registerVirtualHost(w, host,
  folderPath, allow=true)`.

The method serves files from the local folder with `ALLOW` access (1). Possible
values of `COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND`: `0=DENY`,
`1=ALLOW`, `2=DENY_CORS`.

---

## Troubleshooting

| Problem | Cause / Solution |
|---------|------------------|
| No books in the Library menu | Make sure there are `.epub` files in `html_code/` and that the exe is launched from the same folder as `html_code/`. |
| "No books found" | `html_code/` folder not found next to the exe. The app looks for `getAppDir()/html_code`. |
| Empty window | WebView2 Runtime not installed (present in Win11). |
| Missing or wrong title | Check the book's `META-INF/container.xml` and `package.opf`; `epubTitle` ignores errors and falls back to the file name. |
| Frontend changes not visible | The frontend is read from disk on every launch: close and reopen the app (no need to recompile for `html_code/` changes only). |

### Useful constants in `epub_app.nim`
- `VHOST = "appassets"` – the virtual host name used to serve the folder.
- `HOST_ACCESS_ALLOW = 1` – the virtual host access level.

---

## Note on the unzip method

- **Nim side** (library titles): `zippy/ziparchives` (`openZipArchive`,
  `extractFile`), the same method as `fascicoli_app.nim` in `zipbrowser`.
- **Browser side** (actual reading): `epub.js` unzips the book by itself with
  JSZip. Nim doesn't need to extract the content for reading.
