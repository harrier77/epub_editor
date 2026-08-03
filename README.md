# Standalone EPUB reader (Nim + WebView2)

**Serverless** desktop application that displays `.epub` files in a WebView2
window, reusing the same `epub.js` library from the original Flask project
(`C:\Users\pr30565\Desktop\python\epub.js\reader`).

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
3. **Virtual host** – `mio_registerVirtualHost("appassets", html_code)` maps
   `https://appassets/...` to the files in the `html_code/` folder.
4. **Navigation** – the window loads `https://appassets/index.html`.
5. **Library** – `index.html` calls the bridge `api.listBooks()` → Nim replies
   with `[{name, title, url, size}, ...]`.
6. **Reading** – `epub.js` opens the book via `https://appassets/<name>.epub`
   and **unzips it by itself** with JSZip (the original JS code is unchanged).

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
- **`listEpubBooks(dir)`** – scans the folder and returns the books as JSON.
  Edit here if you want to change the folder, sorting, or the fields returned
  to the frontend.
- **`epubTitle(path)`** – extracts the title from the OPF. Change it here if
  some books don't show the correct title (e.g. EPUBs with a particular
  `container.xml` structure).
- **`handleBridge`** – handles commands from JS. Add new `of "command"` cases
  for new features (e.g. extracting a specific file from the ZIP via zippy).

### `html_code/index.html`
- It is the **same** as the Flask app, with the addition of the
  `window.api.listBooks` bridge instead of the `GET /api/books` fetch.
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
